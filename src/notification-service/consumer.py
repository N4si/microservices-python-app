import json
import os
import pathlib
import sys

import pika
from prometheus_client import Counter, start_http_server
from send import email
import rabbitmq_retry
import idempotency
from jsonlog import get_logger

log = get_logger("notification")

# B4 SLO 3 (end-to-end success). This consumer exposes a prometheus endpoint on its
# own thread (scraped by a PodMonitor); vidcast_notifications_total{status="success"}
# is the SLO numerator, compared against the gateway's vidcast_uploads_total.
METRICS_PORT = int(os.environ.get("METRICS_PORT", "9000"))
NOTIFICATIONS = Counter(
    "vidcast_notifications_total",
    "Notification emails attempted by outcome.",
    ["status"],
)

def main():
    credentials = pika.PlainCredentials(
        os.environ.get("RABBITMQ_DEFAULT_USER", "guest"),
        os.environ.get("RABBITMQ_DEFAULT_PASS", "guest"),
    )
    connection = pika.BlockingConnection(
        pika.ConnectionParameters(host="rabbitmq", credentials=credentials, heartbeat=0)
    )
    channel = connection.channel()

    mp3_queue = os.environ.get("MP3_QUEUE")

    # A3: declare the full retry/DLQ topology for the mp3 pipeline we consume
    # (mp3, mp3.retry, mp3.dlq + the vidcast.dlx exchange).
    rabbitmq_retry.declare_topology(channel, mp3_queue)

    # B4: start the metrics HTTP server (background thread) so Prometheus can scrape
    # this consumer's SLO metrics on :METRICS_PORT/metrics.
    start_http_server(METRICS_PORT)

    # Signal readiness as soon as we are connected and ready to consume. The
    # liveness probe checks for this file; without an initial touch an idle
    # consumer would never create it and crash-loop on the probe. This matters
    # especially here: if email delivery fails (e.g. placeholder Gmail
    # password), the per-message touch below never runs, so the startup touch
    # is the only thing keeping the pod alive.
    pathlib.Path("/tmp/healthy").touch()

    def callback(ch, method, properties, body):
        # correlation id forwarded from the gateway via the converter; "legacy"
        # for old/unparseable bodies.
        try:
            correlation_id = json.loads(body).get("correlation_id", "legacy")
        except Exception:
            correlation_id = "legacy"

        # A2: claim-once on the mp3_fid so a redelivered/duplicate message does
        # not send a second email for the same mp3.
        job_id = None
        if idempotency.IDEMPOTENCY_ENABLED:
            try:
                job_id = f"notification:{json.loads(body)['mp3_fid']}"
            except Exception:
                job_id = None  # unparseable body — fall through and let A3 handle it
            if job_id and not idempotency.claim_once(job_id):
                log.info("Duplicate message skipped", correlation_id=correlation_id, job_id=job_id)
                ch.basic_ack(delivery_tag=method.delivery_tag)
                return

        # A3: catch unexpected errors so a single bad message is retried/dead-
        # lettered rather than crashing the consumer.
        try:
            err = email.notification(body)
        except Exception as e:
            log.error("Notification error", correlation_id=correlation_id, error=str(e))
            err = str(e)

        if err:
            NOTIFICATIONS.labels("failure").inc()
            log.warning("Notification failed", correlation_id=correlation_id)
            # Route to retry (or terminal DLQ after MAX_RETRIES), then ACK the
            # original so it leaves the main queue — no more infinite requeue.
            outcome = rabbitmq_retry.handle_failure(ch, properties, body, mp3_queue)
            # A2: release the claim ONLY on a retry, so the next attempt can
            # re-claim. On a terminal DLQ outcome keep the claim (permanent fail).
            if job_id and outcome == "retry":
                idempotency.release(job_id)
            ch.basic_ack(delivery_tag=method.delivery_tag)
        else:
            NOTIFICATIONS.labels("success").inc()
            ch.basic_ack(delivery_tag=method.delivery_tag)
            pathlib.Path("/tmp/healthy").touch()

    channel.basic_consume(
        queue=mp3_queue, on_message_callback=callback
    )

    log.info("Notification consumer ready, waiting for messages")

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