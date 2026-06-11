import os

import pika

# A3 retry / dead-letter topology helper.
#
# Pattern: delayed-retry queue + terminal DLQ, with an EXPLICIT retry counter.
# For a pipeline whose MAIN queue is e.g. "video" we add two queues and one
# exchange (all additive — the main queue and the message payload are unchanged):
#
#   <main>.retry  durable, x-message-ttl=RETRY_TTL_MS, dead-letters (after the
#                 TTL expires with no consumer) via the DEFAULT exchange back to
#                 <main> — i.e. a failed message waits RETRY_TTL_MS, then returns
#                 to the main queue for another attempt.
#   <main>.dlq    durable terminal dead-letter queue, bound to the vidcast.dlx
#                 direct exchange. Messages land here after MAX_RETRIES and are
#                 NOT auto-retried (a human/operator drains or inspects them).
#
# Consumers do NOT consume <main>.retry — the TTL-expiry dead-letter does the
# delay + re-inject automatically. The retry count is tracked in an explicit
# `x-retry-count` header the consumer increments, rather than relying on the
# broker's x-death header (which varies by RabbitMQ version and counts per-queue).
# This is the topology declared from code so it is reproducible from scratch with
# no manual queue creation in the management UI.

DLX_EXCHANGE = "vidcast.dlx"

# Tunable via env (configmap). Defaults: 3 retries, 30s delay between attempts.
MAX_RETRIES = int(os.environ.get("MAX_RETRIES", "3"))
RETRY_TTL_MS = int(os.environ.get("RETRY_TTL_MS", "30000"))


def declare_topology(channel, main_queue):
    """Idempotently declare the full retry/DLQ topology for one pipeline. Safe to
    call on every consumer startup — re-declaring with identical arguments is a
    no-op in RabbitMQ."""
    channel.exchange_declare(
        exchange=DLX_EXCHANGE, exchange_type="direct", durable=True
    )

    # Main queue: plain durable, no arguments — matches how the gateway/outbox
    # relay publish to it and how it was created in Phase 8. Declared here so the
    # topology is self-contained.
    channel.queue_declare(queue=main_queue, durable=True)

    # Delayed retry queue: on TTL expiry the message dead-letters via the DEFAULT
    # exchange ("") with routing key = main_queue, landing it back on the main
    # queue for the next attempt.
    channel.queue_declare(
        queue=f"{main_queue}.retry",
        durable=True,
        arguments={
            "x-message-ttl": RETRY_TTL_MS,
            "x-dead-letter-exchange": "",
            "x-dead-letter-routing-key": main_queue,
        },
    )

    # Terminal DLQ, bound to vidcast.dlx with routing key "<main>.dlq".
    channel.queue_declare(queue=f"{main_queue}.dlq", durable=True)
    channel.queue_bind(
        queue=f"{main_queue}.dlq",
        exchange=DLX_EXCHANGE,
        routing_key=f"{main_queue}.dlq",
    )


def handle_failure(channel, properties, body, main_queue):
    """Route a failed message. Increment x-retry-count and either re-queue to
    <main>.retry (delayed retry) or, once MAX_RETRIES is reached, send it to the
    terminal <main>.dlq. The CALLER must ack the original delivery afterwards —
    the message has been re-published, so it must leave the main queue (this is
    what breaks the old infinite NACK-requeue poison loop, L-4).

    Returns "retry" if the message was re-queued for another attempt, or "dlq" if
    it was dead-lettered terminally. A2 uses this to decide whether to release the
    idempotency claim (release on "retry" so the next attempt can re-claim; keep it
    on "dlq" since a dead-lettered job is a permanent failure)."""
    headers = dict(getattr(properties, "headers", None) or {})
    retry_count = int(headers.get("x-retry-count", 0))

    if retry_count < MAX_RETRIES:
        headers["x-retry-count"] = retry_count + 1
        channel.basic_publish(
            exchange="",
            routing_key=f"{main_queue}.retry",
            body=body,
            properties=pika.BasicProperties(
                delivery_mode=pika.spec.PERSISTENT_DELIVERY_MODE,
                headers=headers,
            ),
        )
        print(
            f"[retry] {main_queue}: attempt {retry_count + 1}/{MAX_RETRIES} -> "
            f"{main_queue}.retry (delay {RETRY_TTL_MS}ms)",
            flush=True,
        )
        return "retry"

    channel.basic_publish(
        exchange=DLX_EXCHANGE,
        routing_key=f"{main_queue}.dlq",
        body=body,
        properties=pika.BasicProperties(
            delivery_mode=pika.spec.PERSISTENT_DELIVERY_MODE,
            headers=headers,
        ),
    )
    print(
        f"[dlq] {main_queue}: exhausted {MAX_RETRIES} retries -> "
        f"{main_queue}.dlq (terminal)",
        flush=True,
    )
    return "dlq"
