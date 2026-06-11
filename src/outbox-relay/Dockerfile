FROM python:3.10-slim-bookworm

# apt-get upgrade pulls patched OS packages (libgnutls30, libkrb5*) that the base
# image predates. pip upgrade of setuptools/wheel clears toolchain CVEs
# (CVE-2026-24049 wheel, CVE-2026-23949 jaraco.context vendored in setuptools).
# No build toolchain is needed: pika and pymongo ship manylinux wheels.
RUN apt-get update && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir --upgrade pip setuptools wheel

WORKDIR /app
COPY ./requirements.txt /app

RUN pip install --no-cache-dir --requirement /app/requirements.txt
COPY . /app

# Run as a non-root uid (matches the Kubernetes securityContext runAsUser: 1000).
# The relay only writes the /tmp/healthy heartbeat, which is backed by a writable
# emptyDir at /tmp in k8s (the rest of the rootfs is read-only).
USER 1000

CMD ["python", "relay.py"]
