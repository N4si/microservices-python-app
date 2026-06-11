# VidCast — Observability & Abuse Protection (Sprint 3)

> Closes **I8 / P3** (structured logging + correlation IDs), **A12** (download
> audit log), and **A10** (rate limiting). Application code only — no manifests,
> Terraform, or Helm. Branch:
> `feature/improvement-sprint-3-observability-and-abuse-protection`.

---

## 1. Log format

Every service logs **one JSON object per line** to stdout (via `jsonlog.py`,
inlined per service). Fields present on every line:

| Field | Meaning |
|---|---|
| `timestamp` | ISO-8601 UTC |
| `level` | `INFO` / `WARNING` / `ERROR` |
| `service` | `gateway` / `auth` / `converter` / `notification` / `outbox-relay` |
| `correlation_id` | per-request trace id (`"none"` for process-level lines, `"legacy"` for pre-correlation messages) |
| `message` | human-readable text |
| *(extra)* | any call-site context, e.g. `fid`, `user`, `file_size_bytes`, `error` |

Example:
```json
{"timestamp":"2026-06-11T03:11:19Z","level":"INFO","service":"gateway","correlation_id":"abc-123","message":"File downloaded","fid":"6a1a","user":"x@y.com","file_size_bytes":295749}
```

## 2. Tracing one request end to end

The gateway mints a `correlation_id` (UUID4) per request and stamps it into the
RabbitMQ message body. The converter and notification services read it off the
message; the outbox relay republishes the stored payload verbatim, preserving it.
So a single id appears on every log line from upload to email:

```bash
CID=abc-123
# Across all services in the default namespace:
for app in gateway converter notification outbox-relay; do
  kubectl logs -l app=$app --tail=-1 2>/dev/null \
    | jq -c "select(.correlation_id == \"$CID\")"
done
# or, if shipping to one sink later, a single: jq 'select(.correlation_id=="abc-123")'
```

**Flow:** `gateway` (mint id, log "Upload published/queued") → `video` queue →
`converter` ("Conversion complete") → `mp3` queue → `notification` ("Mail sent").
With the outbox enabled, `outbox-relay` logs "Outbox event published" in between.

## 3. Download audit (A12)

Every successful `GET /download` emits one structured line from the gateway:
```json
{"level":"INFO","service":"gateway","message":"File downloaded","correlation_id":"…","fid":"…","user":"…","file_size_bytes":…}
```
Find all downloads: `kubectl logs -l app=gateway | jq 'select(.message=="File downloaded")'`.
Failed downloads log `"Download failed"` with the `error`. (Admin role changes are
also audited via the existing `"Admin role change"` line.)

## 4. Rate limiting (A10)

`flask-limiter` on the gateway, backed by the **existing in-cluster Redis**:

| Endpoint | Limit | Why |
|---|---|---|
| `POST /login` | **10 / minute** per client | brute-force protection |
| `POST /upload` | **20 / hour** per client | upload quota |

To adjust, edit the `@limiter.limit(...)` decorators in
`src/gateway-service/server.py`. The E2E pipeline (1 login + 1 upload) is well
under both, so it is unaffected.

**Three things to know for deployment:**

1. **A `gateway → redis:6379` NetworkPolicy egress rule is required** for the
   limit to be shared across gunicorn workers. The gateway's current egress policy
   (`app-policies.yaml`) allows auth/mongodb/rabbitmq but **not** redis, and editing
   existing NetworkPolicies is out of this code-only sprint's scope. Until that
   one-line rule is added (a small follow-on infra PR, like Sprint 1's
   `allow-backup-egress`), the limiter **degrades gracefully to a per-process
   in-memory limiter** (`in_memory_fallback_enabled=True`) — still functional, but
   each of the 2 gunicorn workers counts independently (≈2× the configured limit).
2. **Client IP comes from `X-Forwarded-For`.** The gateway sits behind nginx/ALB,
   so it keys on the first XFF hop, not the socket peer (which would make `/login`
   one global bucket — a lockout DoS). **Caveat:** XFF is client-spoofable because
   nginx appends rather than replaces it; a determined attacker can rotate fake XFF
   values to evade per-IP login limits. A robust fix (trust only the proxy hop, or
   also limit per target username) is a follow-up.
3. **Redis port is fixed at 6379 in code**, not read from `REDIS_PORT` env — the
   in-namespace `redis` Service injects `REDIS_PORT=tcp://<ip>:6379` via Docker
   service links into the gateway pod (which, unlike the consumers, does not set
   `enableServiceLinks:false`), and reading it would corrupt the storage URI.

## 5. Not yet implemented — log shipping

Logs are JSON on stdout; they are **not yet shipped to a central store**. The next
additive step (separate infra PR, per the code/infra split) is a **Fluent Bit
DaemonSet → CloudWatch Logs or Grafana Loki**, at which point the `jq` greps above
become a single indexed query (`correlation_id = "…"`) across all services. Until
then, query per-pod with `kubectl logs | jq` as shown above.
