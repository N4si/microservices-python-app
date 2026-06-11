import datetime
import json
import os
import pathlib
import sys
import time

import pika
from pymongo import MongoClient

from jsonlog import get_logger

log = get_logger("outbox-relay")

# A1 transactional-outbox relay.
#
# This is a SEPARATE, SINGLE-REPLICA Deployment — deliberately not an in-process
# thread in the gateway. The gateway runs under gunicorn with multiple worker
# processes (A4), so an in-process relay would run once per worker = N concurrent
# publishers, re-introducing the duplicate-publish bug the outbox exists to kill.
# One replica = one publisher = no double-send by construction (PHASE_UP_PLAN §3.3).
#
# Loop: every POLL_INTERVAL seconds, find outbox rows with published_at == null,
# publish each to RabbitMQ (persistent), then stamp published_at. A relay restart
# mid-publish re-picks any unstamped rows next cycle; idempotent consumers (A2)
# make a rare duplicate a no-op, not a double-email.

POLL_INTERVAL = int(os.environ.get("OUTBOX_POLL_INTERVAL", "30"))

# Reuse the gateway's own credential paths — do NOT invent new ones.
# MONGODB_VIDEOS_URI comes from the gateway-secret (the outbox lives in the same
# `videos` database the gateway writes the GridFS video into); the RabbitMQ
# credentials come from the rabbitmq-secret. Host defaults to the in-cluster
# Service name "rabbitmq", matching the converter/notification consumers.
MONGO_URI = os.environ.get("MONGODB_VIDEOS_URI")
RABBIT_HOST = os.environ.get("RABBITMQ_HOST", "rabbitmq")
RABBIT_USER = os.environ.get("RABBITMQ_DEFAULT_USER", "guest")
RABBIT_PASS = os.environ.get("RABBITMQ_DEFAULT_PASS", "guest")

HEALTH_FILE = "/tmp/healthy"


def heartbeat():
    # The liveness probe is `test -f /tmp/healthy` (same pattern as the other
    # consumers). We touch it every cycle — including cycles where a dependency
    # is down — because the relay PROCESS is healthy as long as the loop turns;
    # a broker/Mongo outage is a transient condition the loop retries through,
    # not a reason to kill and reschedule the pod.
    pathlib.Path(HEALTH_FILE).touch()


def publish_pending(outbox):
    """Open a short-lived RabbitMQ connection, publish all unpublished rows,
    stamp each as published, and return the count. Raises on connection failure
    so the caller can log-and-retry next cycle (the pod stays up)."""
    credentials = pika.PlainCredentials(RABBIT_USER, RABBIT_PASS)
    connection = pika.BlockingConnection(
        pika.ConnectionParameters(host=RABBIT_HOST, credentials=credentials, heartbeat=0)
    )
    channel = connection.channel()
    published = 0
    try:
        # Oldest first, so events publish in the order they were produced.
        for doc in outbox.find({"published_at": None}).sort("created_at", 1):
            channel.basic_publish(
                exchange="",
                routing_key=doc.get("routing_key", "video"),
                body=json.dumps(doc["payload"]),
                properties=pika.BasicProperties(
                    delivery_mode=pika.spec.PERSISTENT_DELIVERY_MODE,
                    # B4 SLO 2 clock start: same publish timestamp the gateway's
                    # direct path sets, so converter latency is measured from the
                    # actual RabbitMQ publish regardless of which path produced it.
                    timestamp=int(time.time()),
                ),
            )
            # Stamp immediately after each publish (not in a batch at the end) so a
            # crash mid-loop only ever leaves *unpublished* rows to retry — never
            # loses the record that a publish already happened.
            outbox.update_one(
                {"_id": doc["_id"]},
                {"$set": {"published_at": datetime.datetime.utcnow()}},
            )
            # I8/P3: the gateway's correlation_id is inside the stored payload and is
            # republished verbatim above — log it so the outbox hop is traceable too.
            log.info(
                "Outbox event published",
                correlation_id=doc.get("payload", {}).get("correlation_id", "none"),
                routing_key=doc.get("routing_key", "video"),
            )
            published += 1
        return published
    finally:
        connection.close()


def main():
    if not MONGO_URI:
        log.error("FATAL: MONGODB_VIDEOS_URI is not set")
        sys.exit(1)

    log.info("Outbox relay starting", poll_interval_seconds=POLL_INTERVAL, rabbit_host=RABBIT_HOST)
    # One Mongo client for the process lifetime; pymongo reconnects internally if
    # Mongo blips. get_default_database() resolves the db embedded in the URI
    # (the `videos` db), matching where the gateway wrote the outbox row.
    client = MongoClient(MONGO_URI)
    outbox = client.get_default_database().outbox

    heartbeat()  # ready as soon as the loop is about to run
    while True:
        try:
            n = publish_pending(outbox)
            if n:
                log.info("Outbox cycle published events", count=n)
        except Exception as e:
            # Mongo or RabbitMQ unreachable, or a publish error: log, skip this
            # cycle, retry on the next poll. Never crash the pod.
            log.error("Outbox cycle error, retrying next poll",
                      retry_in_seconds=POLL_INTERVAL, error=str(e))
        heartbeat()
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log.info("Interrupted")
        try:
            sys.exit(0)
        except SystemExit:
            os._exit(0)
