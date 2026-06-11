"""Prometheus metrics for the gateway (B4 / SLO instrumentation).

These power two of the three VidCast SLOs:
  - Availability SLO  → vidcast_gateway_requests_total{status} (5xx ratio)
  - End-to-end SLO    → vidcast_uploads_total (the denominator: accepted uploads,
                        compared against notification-service sends)

MULTIPROCESS NOTE: gunicorn runs 2 worker processes. With the default in-memory
registry each worker would keep its own counters and a single scrape would see
only one worker — halving (and randomising) every rate. prometheus-client's
multiprocess mode makes every worker write samples to PROMETHEUS_MULTIPROC_DIR,
which the /metrics handler aggregates via a MultiProcessCollector. The dir lives
on the pod's writable /tmp emptyDir (readOnlyRootFilesystem is true elsewhere);
we create it here so it exists before the first metric is touched.
"""
import os

from prometheus_client import Counter, Gauge, Histogram

# Ensure the multiprocess sample dir exists (emptyDir → empty on each pod start,
# so no stale files survive a restart). No-op if multiprocess mode is disabled.
_multiproc_dir = os.environ.get("PROMETHEUS_MULTIPROC_DIR")
if _multiproc_dir:
    os.makedirs(_multiproc_dir, exist_ok=True)

# endpoint = the Flask view name (request.endpoint), NOT the raw path, to keep
# label cardinality bounded (e.g. /admin/users/<email> collapses to one series).
REQUEST_COUNT = Counter(
    "vidcast_gateway_requests_total",
    "Total HTTP requests handled by the gateway.",
    ["method", "endpoint", "status"],
)

REQUEST_LATENCY = Histogram(
    "vidcast_gateway_request_duration_seconds",
    "Gateway HTTP request latency in seconds.",
    ["method", "endpoint"],
)

# livesum: sum the gauge across the live worker processes at scrape time.
IN_FLIGHT = Gauge(
    "vidcast_gateway_in_flight_requests",
    "In-flight HTTP requests currently being handled by the gateway.",
    multiprocess_mode="livesum",
)

# SLO 3 numerator source: one increment per video the gateway accepts for
# processing (direct-publish OR outbox write). Compared against
# vidcast_notifications_total{status="success"} to measure end-to-end success.
UPLOADS = Counter(
    "vidcast_uploads_total",
    "Videos successfully accepted by the gateway for conversion.",
)
