import datetime
import gridfs
import json
import os
import time
import uuid

import pika
import requests
from bson.objectid import ObjectId
from flask import Flask, g, jsonify, request, send_file
from flask_cors import CORS
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from flask_pymongo import PyMongo
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    generate_latest,
    multiprocess,
)

from auth import validate
from auth_svc import access
from storage import util
from metrics import IN_FLIGHT, REQUEST_COUNT, REQUEST_LATENCY, UPLOADS
from jsonlog import get_logger

server = Flask(__name__)
CORS(server)

log = get_logger("gateway")

# Rate limits backed by the in-cluster Redis so the counters are shared across
# gunicorn workers. Port is hardcoded: K8s service links inject REDIS_PORT as
# tcp://<ip>:6379, so reading that env var would corrupt the URI.
REDIS_HOST = os.environ.get("REDIS_HOST", "redis")


def _client_ip():
    # Behind nginx/ALB, request.remote_addr is the proxy. Key on the first
    # X-Forwarded-For hop so /login isn't one global bucket (a lockout DoS).
    # Caveat: XFF is client-spoofable since nginx appends rather than replaces it.
    xff = request.headers.get("X-Forwarded-For", "")
    if xff:
        return xff.split(",")[0].strip()
    return get_remote_address()


limiter = Limiter(
    _client_ip,
    app=server,
    storage_uri=f"redis://{REDIS_HOST}:6379",
    strategy="fixed-window",
    default_limits=[],  # only /login and /upload are limited
    # Degrade to in-memory if Redis is unreachable rather than failing the request.
    in_memory_fallback_enabled=True,
)

# Don't meter the scrape or liveness probe — they'd skew the availability SLI.
_UNMETERED = {"metrics", "healthz"}


@server.before_request
def _metrics_before():
    # Fresh correlation id per request, threaded into the logs and queue message.
    g.correlation_id = str(uuid.uuid4())
    if request.endpoint in _UNMETERED:
        return
    g._start = time.perf_counter()
    IN_FLIGHT.inc()


@server.after_request
def _metrics_after(response):
    if request.endpoint in _UNMETERED:
        return response
    # endpoint may be None for unmatched routes (404) — bucket those as "unknown".
    endpoint = request.endpoint or "unknown"
    REQUEST_COUNT.labels(request.method, endpoint, response.status_code).inc()
    start = g.pop("_start", None)
    if start is not None:
        REQUEST_LATENCY.labels(request.method, endpoint).observe(time.perf_counter() - start)
    IN_FLIGHT.dec()
    return response


@server.route("/metrics", methods=["GET"])
def metrics():
    # Aggregate the per-worker sample files into one exposition payload.
    registry = CollectorRegistry()
    multiprocess.MultiProcessCollector(registry)
    return generate_latest(registry), 200, {"Content-Type": CONTENT_TYPE_LATEST}

mongo_video = PyMongo(server, uri=os.environ.get('MONGODB_VIDEOS_URI'))

mongo_mp3 = PyMongo(server, uri=os.environ.get('MONGODB_MP3S_URI'))

fs_videos = gridfs.GridFS(mongo_video.db)
fs_mp3s = gridfs.GridFS(mongo_mp3.db)

# A1 transactional outbox. The `outbox` collection lives in the same database as
# the video GridFS (mongo_video.db), so the GridFS write and the outbox insert go
# through the same MongoDB client. OUTBOX_ENABLED defaults to false → the gateway
# publishes directly to RabbitMQ exactly as before; set it to "true" to route
# uploads through the outbox (the outbox-relay then publishes them). See
# storage/util.py and OUTBOX_EXPLAINED.md.
outbox = mongo_video.db.outbox
OUTBOX_ENABLED = os.environ.get("OUTBOX_ENABLED", "false").strip().lower() == "true"

# Per-upload status (queued → processing → ready/failed), keyed by video_fid in
# the videos DB. Gateway writes "queued"; the converter advances it. Additive —
# pre-Sprint-4 uploads have no doc, and /my-files defaults them to "ready".
job_status = mongo_video.db.job_status

# Cap on files per batch upload. Each file is an independent job; KEDA scales the
# converter on the resulting queue depth.
MAX_BATCH_SIZE = 20

rabbitmq_credentials = pika.PlainCredentials(
    os.environ.get("RABBITMQ_DEFAULT_USER", "guest"),
    os.environ.get("RABBITMQ_DEFAULT_PASS", "guest"),
)
connection = pika.BlockingConnection(
    pika.ConnectionParameters(host="rabbitmq", credentials=rabbitmq_credentials, heartbeat=0)
)
channel = connection.channel()

@server.route("/healthz", methods=["GET"])
def healthz():
    checks = {}
    status_code = 200
    try:
        mongo_video.db.command("ping")
        checks["mongodb"] = "ok"
    except Exception as e:
        checks["mongodb"] = str(e)
        status_code = 503
    try:
        conn = pika.BlockingConnection(
            pika.ConnectionParameters(
                host=os.environ.get("RABBITMQ_HOST", "rabbitmq"),
                credentials=rabbitmq_credentials,
                heartbeat=0,
            )
        )
        conn.close()
        checks["rabbitmq"] = "ok"
    except Exception as e:
        checks["rabbitmq"] = str(e)
        status_code = 503
    return jsonify({"status": "ok" if status_code == 200 else "degraded", "checks": checks}), status_code

@server.route("/login", methods=["POST"])
@limiter.limit("10 per minute")  # brute-force protection
def login():
    token, err = access.login(request)

    if not err:
        return token
    log.warning("Login rejected", correlation_id=g.correlation_id)
    return err

@server.route("/register", methods=["POST"])
def register():
    token, err = access.register(request)

    if not err:
        return token, 201
    else:
        return err

@server.route("/upload", methods=["POST"])
# Each FILE counts against the 20/hour quota — the cost callable returns the batch
# size, so a batch of 8 consumes 8 tokens.
@limiter.limit("20 per hour", cost=lambda: max(1, len(request.files.getlist("file"))))
def upload():
    access, err = validate.token(request)

    if err:
        return err

    access = json.loads(access)

    # Any authenticated user can upload (not just admins).
    if not access:
        return "not authorized", 401

    # 1..N files under "file"; a single upload is just the N=1 case.
    files = request.files.getlist("file")
    if not files:
        return jsonify({"error": "no files provided"}), 400
    if len(files) > MAX_BATCH_SIZE:
        return jsonify({"error": f"maximum {MAX_BATCH_SIZE} files per batch"}), 400

    batch_size = len(files)
    # A batch_id groups a multi-file request; single uploads stay ungrouped.
    batch_id = str(uuid.uuid4()) if batch_size > 1 else None

    results = []
    queued = 0
    failed = 0
    for f in files:
        # Each file is an independent job with its own correlation id and lifecycle.
        cid = str(uuid.uuid4())
        video_fid, file_err = util.upload(
            f, fs_videos, channel, access, outbox, OUTBOX_ENABLED,
            correlation_id=cid, job_status=job_status,
            batch_id=batch_id, batch_size=batch_size,
        )
        if file_err:
            # One bad file does not abort the batch — record it and continue.
            failed += 1
            results.append({"filename": getattr(f, "filename", None), "error": file_err})
        else:
            queued += 1
            UPLOADS.inc()  # one accepted video per queued file
            results.append({
                "filename": getattr(f, "filename", None),
                "video_fid": video_fid,
                "status": "queued",
            })

    log.info(
        "Upload accepted", correlation_id=g.correlation_id, user=access["username"],
        batch_id=batch_id, batch_size=batch_size, queued=queued, failed=failed,
    )
    # 202 Accepted — the work is queued, not finished.
    return jsonify({
        "batch_id": batch_id,
        "results": results,
        "queued": queued,
        "failed": failed,
    }), 202

@server.route("/download", methods=["GET"])
def download():
    access, err = validate.token(request)

    if err:
        return err

    access = json.loads(access)

    # Any authenticated user can download.
    if not access:
        return "not authorized", 401

    fid_string = request.args.get("fid")

    if not fid_string:
        return "fid is required", 400

    try:
        out = fs_mp3s.get(ObjectId(fid_string))
        # Audit: who downloaded which file, when, how big.
        log.info(
            "File downloaded",
            correlation_id=g.correlation_id,
            fid=fid_string,
            user=access.get("username", "unknown"),
            file_size_bytes=getattr(out, "length", None),
        )
        return send_file(out, download_name=f"{fid_string}.mp3")
    except Exception as err:
        log.error(
            "Download failed",
            correlation_id=g.correlation_id,
            fid=fid_string,
            error=str(err),
        )
        return "internal server error", 500


@server.route("/my-files", methods=["GET"])
def my_files():
    """List the user's conversions newest-first with a status. Merges job_status
    docs (so an upload appears before its mp3 exists) with legacy mp3s that predate
    status tracking (shown as "ready"). `fid` is the mp3 id, null until ready."""
    access, err = validate.token(request)
    if err:
        return err
    access = json.loads(access)
    if not access:
        return "not authorized", 401

    owner = access["username"]
    files = []
    seen = set()
    for j in job_status.find({"username": owner}).sort("created_at", -1):
        seen.add(j["video_fid"])
        files.append({
            "fid": j.get("mp3_fid"),
            "video_fid": j["video_fid"],
            "filename": j.get("original_filename") or j["video_fid"],
            "status": j.get("status", "ready"),
            "size": j.get("mp3_size"),
            "created": j["created_at"].isoformat() if j.get("created_at") else None,
            # batch grouping (None/1 for singles + pre-Sprint-5 docs)
            "batch_id": j.get("batch_id"),
            "batch_size": j.get("batch_size", 1),
        })

    # Legacy mp3s with no status doc → "ready". They're named "<video_fid>.mp3",
    # so dedupe against the job_status video_fids above.
    for f in fs_mp3s.find({"metadata.owner_email": owner}).sort("uploadDate", -1):
        vfid = f.filename[:-4] if f.filename and f.filename.endswith(".mp3") else None
        if vfid and vfid in seen:
            continue
        files.append({
            "fid": str(f._id),
            "video_fid": vfid,
            "filename": f.filename,
            "status": "ready",
            "size": f.length,
            "created": f.upload_date.isoformat() if f.upload_date else None,
            # Legacy single uploads were never batched.
            "batch_id": None,
            "batch_size": 1,
        })

    # Newest-first across both sources (ISO-8601 sorts lexically).
    files.sort(key=lambda x: x["created"] or "", reverse=True)
    return jsonify({"files": files}), 200


@server.route("/batch/<batch_id>", methods=["GET"])
def batch_status(batch_id):
    """Aggregate status of one batch, scoped to the user."""
    access, err = validate.token(request)
    if err:
        return err
    access = json.loads(access)
    if not access:
        return "not authorized", 401

    docs = list(job_status.find(
        {"batch_id": batch_id, "username": access["username"]},
        {"_id": 0, "video_fid": 1, "original_filename": 1, "status": 1, "mp3_fid": 1},
    ))
    if not docs:
        return jsonify({"error": "batch not found"}), 404

    total = len(docs)
    ready = sum(1 for d in docs if d.get("status") == "ready")
    failed = sum(1 for d in docs if d.get("status") == "failed")
    return jsonify({
        "batch_id": batch_id,
        "total": total,
        "ready": ready,
        "failed": failed,
        "in_progress": total - ready - failed,
        "complete": (ready + failed) == total,
        "files": docs,
    }), 200


@server.route("/status/<video_fid>", methods=["GET"])
def status(video_fid):
    """Status of one job, scoped to the user."""
    access, err = validate.token(request)
    if err:
        return err
    access = json.loads(access)
    if not access:
        return "not authorized", 401

    doc = job_status.find_one(
        {"video_fid": video_fid, "username": access["username"]},
        {"_id": 0},
    )
    if not doc:
        return jsonify({"error": "not found"}), 404
    return jsonify({
        "status": doc.get("status", "ready"),
        "original_filename": doc.get("original_filename", ""),
        "mp3_fid": doc.get("mp3_fid"),
        "updated_at": doc["updated_at"].isoformat() if doc.get("updated_at") else None,
    }), 200


@server.route("/notifications/unseen-count", methods=["GET"])
def unseen_count():
    """Count this user's completed mp3s created since `since` (ISO-8601).

    The frontend polls this for the Download bubble badge and passes the
    timestamp of the user's last visit to the Download page as `since`, so the
    badge reflects only conversions completed since they last looked.
    """
    access, err = validate.token(request)
    if err:
        return err
    access = json.loads(access)
    if not access:
        return "not authorized", 401

    since = request.args.get("since", "1970-01-01T00:00:00")
    try:
        since_dt = datetime.datetime.fromisoformat(since)
    except ValueError:
        since_dt = datetime.datetime(1970, 1, 1)

    # count_documents on the GridFS files collection — PyMongo 4 removed
    # Cursor.count(), and counting server-side avoids streaming file docs.
    count = mongo_mp3.db["fs.files"].count_documents({
        "metadata.owner_email": access["username"],
        "uploadDate": {"$gt": since_dt},
    })
    return jsonify({"count": count}), 200


def _require_admin(request):
    """Validate the JWT and require the admin role. Returns (claims, None) on
    success or (None, (body, status)) to return directly. This is where admin
    authorization is enforced — the auth-service /users endpoints trust it."""
    raw, err = validate.token(request)
    if err:
        return None, err
    claims = json.loads(raw)
    if not claims or not claims.get("admin"):
        return None, ("admin only", 403)
    return claims, None


def _conversion_counts():
    """Map of owner_email -> number of converted mp3s, from a Mongo aggregation."""
    pipeline = [{"$group": {"_id": "$metadata.owner_email", "count": {"$sum": 1}}}]
    return {
        doc["_id"]: doc["count"]
        for doc in mongo_mp3.db["fs.files"].aggregate(pipeline)
        if doc["_id"]
    }


@server.route("/admin/users", methods=["GET"])
def admin_users():
    claims, err = _require_admin(request)
    if err:
        return err

    auth_addr = os.environ.get("AUTH_SVC_ADDRESS")
    try:
        resp = requests.get(f"http://{auth_addr}/users", timeout=5)
    except Exception as e:
        return f"auth service unreachable: {e}", 502
    if resp.status_code != 200:
        return resp.text, resp.status_code

    users = resp.json()
    counts = _conversion_counts()
    for u in users:
        u["conversions"] = counts.get(u["email"], 0)
    return jsonify(users), 200


@server.route("/admin/users/<email>", methods=["PATCH"])
def admin_update_user(email):
    claims, err = _require_admin(request)
    if err:
        return err

    data = request.get_json(silent=True) or {}
    role = data.get("role")
    if role not in ("user", "admin"):
        return "role must be 'user' or 'admin'", 400

    caller = claims.get("username")
    auth_addr = os.environ.get("AUTH_SVC_ADDRESS")

    # Guardrail 1: an admin cannot change their own role (no accidental self-lockout).
    if email == caller:
        return "cannot change your own role", 403

    # Guardrail 2: refuse a demotion that would leave zero admins (cluster lockout).
    if role == "user":
        try:
            resp = requests.get(f"http://{auth_addr}/users", timeout=5)
            resp.raise_for_status()
            admin_emails = {u["email"] for u in resp.json() if u.get("role") == "admin"}
        except Exception as e:
            return f"auth service unreachable: {e}", 502
        if admin_emails == {email}:
            return "cannot demote the last remaining admin", 409

    try:
        resp = requests.patch(
            f"http://{auth_addr}/users/{email}", json={"role": role}, timeout=5
        )
    except Exception as e:
        return f"auth service unreachable: {e}", 502

    # Audit trail (captured in gateway pod logs): who changed whom, to what role.
    log.info(
        "Admin role change",
        correlation_id=g.correlation_id,
        admin=caller,
        target=email,
        new_role=role,
        result=resp.status_code,
    )
    return resp.text, resp.status_code


if __name__ == "__main__":
    server.run(host="0.0.0.0", port=8080)
