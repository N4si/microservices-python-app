FROM python:3.10-slim-bookworm

# ffmpeg removed: the notification service only consumes the mp3 queue and sends
# email via SMTP. It never invokes ffmpeg/moviepy, so the ~100MB media toolchain
# was dead weight inherited by copy-paste from the converter Dockerfile.
# build-essential/libpq-dev/python3-dev also dropped: the only deps (pika,
# certifi, urllib3) are pure-Python wheels needing no compilation.
# apt-get upgrade pulls patched OS packages (libgnutls30, libkrb5*); the pip
# upgrade of setuptools/wheel clears toolchain CVEs (CVE-2026-24049 wheel,
# CVE-2026-23949 jaraco.context vendored in setuptools).
RUN apt-get update && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir --upgrade pip setuptools wheel

WORKDIR /app
COPY ./requirements.txt /app

RUN pip install --no-cache-dir --requirement /app/requirements.txt
COPY . /app

# Run as a non-root uid (matches the Kubernetes securityContext runAsUser: 1000).
# The consumer writes the /tmp/healthy heartbeat to /tmp, which is world-writable
# (mode 1777) and backed by a writable emptyDir in k8s.
USER 1000

CMD ["python", "consumer.py"]