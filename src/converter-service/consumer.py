import datetime
import json
import os
import pathlib
import sys
import time

import pika
from prometheus_client import Counter, Histogram, start_http_server
from pymongo import MongoClient
import gridfs
from convert import to_mp3
import rabbitmq_retry
import idempotency
from jsonlog import get_logger

log = get_logger("converter")

# B4 SLO 2 (conversion latency). This consumer has no HTTP server, so we expose a
# tiny prometheus endpoint on its own thread (start_http_server) which a PodMonitor
# scrapes. The histogram measures publish→mp3-write latency using the AMQP message
# timestamp the gateway/outbox-relay stamp at publish; buckets bracket the 5-minute
# SLO target so histogram_quantile(0.95, …) and the le="300" good-events ratio both
# work without re-bucketing.
METRICS_PORT = int(os.environ.get("METRICS_PORT", "9000"))
CONVERSIONS = Counter(
    "vidcast_conversions_total",
    "Conversion attempts by outcome.",
    ["status"],
)
CONVERSION_DURATION = Histogram(
    "vidcast_conversion_duration_seconds",
    "Latency from RabbitMQ publish to mp3 write completion (successful jobs).",
    buckets=(1, 5, 10, 30, 60, 120, 180, 240, 300, 420, 600, float("inf")),
)

def main():
    client = MongoClient(os.environ.get('MONGODB_URI'))
    db_videos = client.videos
    db_mp3s = client.mp3s
    fs_videos = gridfs.GridFS(db_videos)
    fs_mp3s = gridfs.GridFS(db_mp3s)

    # job_status the gateway seeded as "queued" (same videos DB); the converter
    # advances it. Best-effort — never break or delay a conversion over status.
    job_status_col = db_videos.job_status

    def _set_status(video_fid, **fields):
        if not video_fid:
            return
        try:
            fields["updated_at"] = datetime.datetime.utcnow()
            job_status_col.update_one({"video_fid": video_fid}, {"$set": fields})
        except Exception as e:
            log.error("job_status update failed", correlation_id="none", error=str(e))

    credentials = pika.PlainCredentials(
        os.environ.get("RABBITMQ_DEFAULT_USER", "guest"),
        os.environ.get("RABBITMQ_DEFAULT_PASS", "guest"),
    )
    connection = pika.BlockingConnection(
        pika.ConnectionParameters(host='rabbitmq', credentials=credentials, heartbeat=0)
    )
    channel = connection.channel()

    video_queue = os.environ.get("VIDEO_QUEUE")
    mp3_queue = os.environ.get("MP3_QUEUE")

    # A3: declare the full retry/DLQ topology for the video pipeline we consume
    # (video, video.retry, video.dlq + the vidcast.dlx exchange), and also ensure
    # the mp3 main queue exists since this service PRODUCES to it via to_mp3.
    rabbitmq_retry.declare_topology(channel, video_queue)
    channel.queue_declare(queue=mp3_queue, durable=True)

    # B4: start the metrics HTTP server (background thread) so Prometheus can scrape
    # this consumer's SLO metrics on :METRICS_PORT/metrics.
    start_http_server(METRICS_PORT)

    # Signal readiness as soon as we are connected and ready to consume. The
    # liveness probe checks for this file; without an initial touch an idle
    # consumer (no messages yet) would never create it and crash-loop on the
    # probe. Each successfully processed message refreshes it below.
    pathlib.Path("/tmp/healthy").touch()

    def callback(ch, method, properties, body):
        # correlation id from the gateway; "legacy" for old/unparseable bodies.
        try:
            parsed = json.loads(body)
        except Exception:
            parsed = {}
        correlation_id = parsed.get("correlation_id", "legacy")
        video_fid = parsed.get("video_fid")

        # A2: claim-once on the video_fid so a redelivered/duplicate message is
        # not converted twice (which would produce a duplicate mp3 + email). The
        # claim is keyed per service to avoid colliding with the mp3 pipeline.
        job_id = None
        if idempotency.IDEMPOTENCY_ENABLED:
            if video_fid:
                job_id = f"converter:{video_fid}"
            if job_id and not idempotency.claim_once(job_id):
                log.info("Duplicate message skipped", correlation_id=correlation_id, job_id=job_id)
                ch.basic_ack(delivery_tag=method.delivery_tag)
                return

        # UX4: mark the job "processing" before FFmpeg runs.
        _set_status(video_fid, status="processing")

        # A3: catch conversion errors too (moviepy/ffmpeg on a corrupt video can
        # raise out of to_mp3.start, which previously crashed the consumer). A
        # caught failure is routed through the retry/DLQ topology instead.
        result = None
        try:
            result, err = to_mp3.start(body, fs_videos, fs_mp3s, ch)
        except Exception as e:
            log.error("Conversion error", correlation_id=correlation_id, error=str(e))
            err = str(e)

        if err:
            CONVERSIONS.labels("failure").inc()
            # Route to retry (or terminal DLQ after MAX_RETRIES), then ACK the
            # original so it leaves the main queue — no more infinite requeue.
            outcome = rabbitmq_retry.handle_failure(ch, properties, body, video_queue)
            log.warning("Conversion failed", correlation_id=correlation_id, outcome=outcome)
            # UX4: a terminal (DLQ) failure is "failed"; a pending retry stays "processing".
            if outcome != "retry":
                _set_status(video_fid, status="failed")
            # A2: release the claim ONLY on a retry, so the next attempt can
            # re-claim. On a terminal DLQ outcome keep the claim (permanent fail).
            if job_id and outcome == "retry":
                idempotency.release(job_id)
            ch.basic_ack(delivery_tag=method.delivery_tag)
        else:
            CONVERSIONS.labels("success").inc()
            log.info("Conversion complete", correlation_id=correlation_id)
            # UX4: mark ready and persist the mp3 id + size for the download button.
            _set_status(
                video_fid,
                status="ready",
                mp3_fid=(result or {}).get("mp3_fid"),
                mp3_size=(result or {}).get("mp3_size"),
            )
            # SLO 2: observe publish→write latency when the publisher stamped a
            # timestamp (older messages without one are simply not measured).
            if properties is not None and properties.timestamp:
                CONVERSION_DURATION.observe(max(0.0, time.time() - properties.timestamp))
            ch.basic_ack(delivery_tag=method.delivery_tag)
            pathlib.Path("/tmp/healthy").touch()

    channel.basic_consume(
        queue=video_queue, on_message_callback=callback
    )

    log.info("Converter ready, waiting for messages")

    channel.start_consuming()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log.info("Interrupted")
        try:
            sys.exit(0)
        except SystemExit:
            os._exit(0)
