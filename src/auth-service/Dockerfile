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

EXPOSE 5000

# Run as a non-root uid (matches the Kubernetes securityContext runAsUser: 1000).
# Port 5000 is >1024 so no privileged binding is required; /app is world-readable.
USER 1000

CMD ["python", "server.py"]