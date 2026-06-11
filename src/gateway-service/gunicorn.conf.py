"""Gunicorn config — exists solely to wire prometheus-client multiprocess mode.

The runtime flags (bind/workers/timeout/access-logfile/no-control-socket) stay on
the Dockerfile CMD line; this file only adds the one hook gunicorn needs for
correct multiprocess metrics: reclaiming a worker's sample files when it exits, so
a respawned worker's counters don't double-count the dead one's.
"""
from prometheus_client import multiprocess


def child_exit(server, worker):  # noqa: ARG001 (gunicorn calls with both args)
    multiprocess.mark_process_dead(worker.pid)
