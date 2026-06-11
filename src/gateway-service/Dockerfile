FROM python:3.10-slim-bookworm

# apt-get upgrade pulls patched OS packages (libgnutls30, libkrb5*) that the base
# image predates. pip upgrade of setuptools/wheel clears toolchain CVEs
# (CVE-2026-24049 wheel, CVE-2026-23949 jaraco.context vendored in setuptools).
RUN apt-get update && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends --no-install-suggests build-essential libpq-dev python3-dev \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir --upgrade pip setuptools wheel

WORKDIR /app
COPY ./requirements.txt /app

RUN pip install --no-cache-dir --requirement /app/requirements.txt
COPY . /app

EXPOSE 8080

# Run as a non-root uid (matches the Kubernetes securityContext runAsUser: 1000).
# Port 8080 is >1024 so no privileged binding is required; /app is world-readable.
USER 1000

# Production WSGI server (A4). gunicorn imports the Flask app object `server` from
# server.py (server:server) and serves it with 2 sync workers — conservative for a
# 2-vCPU node already running 12+ pods. Binds 0.0.0.0:8080 to match the container
# port / Service targetPort / liveness probe. Access logs to stdout (-) so they
# land in `kubectl logs`. --timeout 120 (vs the 30s default): the /upload path
# streams the whole video into MongoDB GridFS before responding, which a large
# file can exceed under the default sync-worker timeout. --no-control-socket
# disables gunicorn 26.x's control socket (defaults to $HOME/.gunicorn/gunicorn.ctl),
# which we don't use and which can't be created under our non-root UID +
# readOnlyRootFilesystem. The Werkzeug `if __name__ == "__main__"` block in
# server.py is now dead code (local dev only).
# -c gunicorn.conf.py adds the child_exit hook that reclaims a dead worker's
# prometheus multiprocess sample files (B4). Runtime flags stay inline.
CMD ["gunicorn", "-c", "/app/gunicorn.conf.py", "--bind", "0.0.0.0:8080", "--workers", "2", "--timeout", "120", "--no-control-socket", "--access-logfile", "-", "server:server"]