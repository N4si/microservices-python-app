import os

import redis

# A2 idempotency / claim-once guard.
#
# A3 makes delivery at-least-once (a message can be redelivered: a retry after a
# transient failure, an outbox double-publish during a relay restart, or a broker
# re-delivery after a crash between publish and ack). Without a guard, a redelivery
# means a duplicate email for the same mp3. This module makes processing
# idempotent: the FIRST delivery of a job claims it; later duplicates are skipped.
#
# Mechanism: Redis SET key NX EX(ttl). SET-if-absent is atomic, so concurrent
# deliveries race safely — exactly one gets the claim. The TTL bounds the dedup
# window and means a crash can never wedge a claim forever.
#
# NOTE: identical to src/converter-service/idempotency.py — duplicated because
# the two services are separate Docker build contexts with no shared package.

IDEMPOTENCY_ENABLED = (
    os.environ.get("IDEMPOTENCY_ENABLED", "false").strip().lower() == "true"
)
CLAIM_TTL_SECONDS = int(os.environ.get("IDEMPOTENCY_TTL_SECONDS", "300"))
REDIS_HOST = os.environ.get("REDIS_HOST", "redis")
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))

_client = None


def _redis():
    global _client
    if _client is None:
        # Short timeouts: a Redis hiccup must degrade quickly to "process anyway",
        # never block the consumer for long.
        _client = redis.Redis(
            host=REDIS_HOST,
            port=REDIS_PORT,
            socket_connect_timeout=3,
            socket_timeout=3,
        )
    return _client


def claim_once(key):
    """Return True if this is the first claim for `key` (caller should process),
    False if it is already claimed (duplicate — caller should skip).

    Fails OPEN: if Redis is unreachable, return True and process the message
    anyway. A Redis outage then degrades us to "possible occasional duplicate",
    never "stuck pipeline" (PHASE_UP_PLAN risk 2.7) — a rare double-email is far
    better than halting all processing because the dedup store is down."""
    try:
        return bool(_redis().set(name=key, value="1", nx=True, ex=CLAIM_TTL_SECONDS))
    except Exception as e:
        print(
            f"[idempotency] degraded (Redis error), processing anyway: {e}",
            flush=True,
        )
        return True


def release(key):
    """Delete the claim so a legitimate A3 retry can re-claim the job on its next
    attempt. Call this ONLY on a retryable failure — never on success (keep the
    claim to suppress duplicates) and never on a terminal DLQ failure (keep the
    claim so an unfixable job is not reprocessed)."""
    try:
        _redis().delete(key)
    except Exception as e:
        print(f"[idempotency] release failed for {key}: {e}", flush=True)
