import datetime
import json
import os
import smtplib
from email.message import EmailMessage

from pymongo import MongoClient, ReturnDocument

from jsonlog import get_logger

log = get_logger("notification")

_TERMINAL = {"ready", "failed"}
_mongo_client = None


def _job_status_collection():
    """Lazy handle to videos.job_status, used to tell when a batch is complete.
    Returns None if MONGODB_URI is unset or Mongo is unreachable — the caller then
    degrades to one email per file.

    Needs two infra additions to actually fire (both blocked today): a credentialed
    MONGODB_URI in notification-secret (the configmap default has no auth), and a
    notification→mongodb:27017 NetworkPolicy egress rule (default-deny blocks it)."""
    global _mongo_client
    uri = os.environ.get("MONGODB_URI")
    if not uri:
        return None
    try:
        if _mongo_client is None:
            _mongo_client = MongoClient(
                uri, serverSelectionTimeoutMS=3000, connectTimeoutMS=3000
            )
        return _mongo_client.videos.job_status
    except Exception as e:
        log.error("mongo connect failed; per-file email fallback", correlation_id="none", error=str(e))
        return None


def notification(message):
    """Send the "your audio is ready" notification for one converted file.

    Returns None on success OR on a deliberate skip (the caller ACKs); returns a
    truthy error string only for a *retryable* failure (the caller NACKs). Never
    raises — an unhandled exception crashes the consumer pod.

    Batch (B3): when a message is part of a multi-file batch, we send ONE summary
    email once every file in the batch is terminal, instead of one email per file.
    """
    try:
        message = json.loads(message)
    except (ValueError, TypeError) as err:
        # Unparseable body — it will never succeed on retry, so drop it (ACK).
        log.warning("Dropping unparseable message", correlation_id="legacy", error=str(err))
        return None

    receiver_address = message.get("username")
    correlation_id = message.get("correlation_id", "legacy")

    # Pre-routing messages have no username — skip (ACK) rather than loop forever.
    if not receiver_address:
        log.info("No username on message, skipping email", correlation_id=correlation_id, mp3_fid=message.get("mp3_fid"))
        return None

    batch_id = message.get("batch_id")
    batch_size = message.get("batch_size", 1)

    # _handle_batch returns False (Mongo down → individual email), None (handled,
    # or waiting for other files), or an error string (retry).
    if batch_id and batch_size and batch_size > 1:
        result = _handle_batch(message, batch_id, receiver_address, correlation_id)
        if result is not False:
            return result

    return _send_individual(message, receiver_address, correlation_id)


def _handle_batch(message, batch_id, receiver_address, correlation_id):
    col = _job_status_collection()
    if col is None:
        return False  # Mongo unavailable → caller sends an individual email instead.
    try:
        current_vfid = message.get("video_fid")
        docs = list(col.find(
            {"batch_id": batch_id},
            {"_id": 0, "status": 1, "original_filename": 1, "video_fid": 1},
        ))
        if not docs:
            return False  # no batch docs (shouldn't happen) → individual email.

        # The file this message is for IS done (we have its mp3), even if the
        # converter hasn't flipped its job_status to "ready" yet (it marks status
        # just after publishing the mp3 — a small cross-service race).
        def terminal(d):
            return d.get("video_fid") == current_vfid or d.get("status") in _TERMINAL

        if not all(terminal(d) for d in docs):
            log.info("Batch still processing, deferring summary", correlation_id=correlation_id, batch_id=batch_id)
            return None  # wait for the remaining files; no individual email.

        # All terminal → claim the summary so exactly one is sent even if two
        # workers finish concurrently (atomic upsert; first caller sees no prior doc).
        marker = col.find_one_and_update(
            {"_id": f"batchsummary:{batch_id}"},
            {"$setOnInsert": {"sent_at": datetime.datetime.utcnow()}},
            upsert=True,
            return_document=ReturnDocument.BEFORE,
        )
        if marker is not None:
            return None  # another worker already sent the summary.

        err = _send_batch_summary(message, docs, receiver_address, correlation_id, batch_id)
        if err:
            # Release the claim so a NACK/retry can re-send the summary.
            col.delete_one({"_id": f"batchsummary:{batch_id}"})
        return err
    except Exception as e:
        log.error("batch summary handling failed; per-file email fallback", correlation_id=correlation_id, error=str(e))
        return False


def _send_batch_summary(message, docs, receiver_address, correlation_id, batch_id):
    display_name = receiver_address.split("@")[0]
    vidcast_url = os.environ.get("VIDCAST_URL", "http://localhost:30006").rstrip("/")

    files = sorted(docs, key=lambda d: (d.get("original_filename") or ""))
    total = len(files)
    ready = sum(1 for d in files if d.get("status") == "ready")
    failed = total - ready

    lines = []
    for d in files:
        name = d.get("original_filename") or d.get("video_fid")
        if d.get("status") == "ready":
            lines.append(f"  ✓ {name}")
        else:
            lines.append(f"  ✗ {name} — conversion failed (re-upload to try again)")

    if ready == total:
        summary_line = f"All {total} files converted successfully."
    elif ready == 0:
        summary_line = "Unfortunately none of your files could be converted."
    else:
        summary_line = f"{ready} of {total} files converted. {failed} failed — see above."

    body = (
        f"Hi {display_name},\n\n"
        "Your batch upload has finished processing.\n\n"
        "Results:\n" + "\n".join(lines) + "\n\n"
        f"{summary_line}\n\n"
        "Download your audio by logging in to VidCast and visiting your\n"
        f"conversions page:\n{vidcast_url}/my-files\n\n"
        f"Reference: {batch_id}\n\n"
        "— The VidCast Platform"
    )
    subject = f"Your batch is ready: {ready} of {total} files converted"
    log.info("Sending batch summary", correlation_id=correlation_id, batch_id=batch_id, ready=ready, total=total)
    return _send_email(receiver_address, subject, body, correlation_id)


def _send_individual(message, receiver_address, correlation_id):
    mp3_fid = message.get("mp3_fid")
    # .get default for messages without a filename (pre-Sprint-4).
    original_filename = message.get("original_filename") or "your file"
    vidcast_url = os.environ.get("VIDCAST_URL", "http://localhost:30006").rstrip("/")
    display_name = receiver_address.split("@")[0]

    # UX2: subject names the file; body adds a reference (correlation_id) for
    # support and links to the authenticated conversions page — note it no longer
    # prints the mp3 file id (the download key), tightening A8.
    body = (
        f"Hi {display_name},\n\n"
        "Your video has been converted to audio and is ready for download.\n\n"
        f"File: {original_filename}\n"
        f"Reference: {correlation_id}\n\n"
        "Download your audio by logging in to VidCast and visiting your\n"
        f"conversions page:\n{vidcast_url}/my-files\n\n"
        "Keep this reference number if you need to contact support about this\n"
        f"conversion: {correlation_id}\n\n"
        "— The VidCast Platform"
    )
    subject = f"Your audio is ready: {original_filename}"
    err = _send_email(receiver_address, subject, body, correlation_id)
    if not err:
        log.info("Mail sent", correlation_id=correlation_id, mp3_fid=mp3_fid, recipient=receiver_address)
    return err


def _send_email(receiver_address, subject, body, correlation_id):
    """Shared SMTP send (Gmail). Returns None on success, a retryable error string
    on failure (the caller NACKs so the broker requeues)."""
    sender_address = os.environ.get("GMAIL_ADDRESS")
    sender_password = os.environ.get("GMAIL_PASSWORD")

    msg = EmailMessage()
    msg.set_content(body)
    msg["Subject"] = subject
    msg["From"] = sender_address
    msg["To"] = receiver_address

    try:
        session = smtplib.SMTP("smtp.gmail.com", 587)
        session.starttls()
        session.login(sender_address, sender_password)
        session.send_message(msg, sender_address, receiver_address)
        session.quit()
    except Exception as err:
        # Retryable (transient network, or a credential that may be fixed by
        # rotating the secret). Returning an error makes the consumer NACK so the
        # message is requeued. A permanently bad credential loops — bounded by the
        # A3 retry/DLQ topology + MAX_RETRIES.
        log.error("Email send failed", correlation_id=correlation_id, error=str(err))
        return f"email send failed: {err}"
    return None
