# Project Summary — Video-to-MP3 Microservices on AWS EKS

**Date:** 2026-05-30  
**Cluster:** `cba-microservices` (AWS EKS, `eu-west-2`)  
**Node IP:** `13.42.28.15`  
**Status:** Deployed and operational — end-to-end test passed

---

## Table of Contents

1. [What This Project Does](#1-what-this-project-does)
2. [High-Level Architecture](#2-high-level-architecture)
3. [Directory Structure](#3-directory-structure)
4. [Microservices — Detailed Breakdown](#4-microservices--detailed-breakdown)
   - [Auth Service](#41-auth-service)
   - [Gateway Service](#42-gateway-service)
   - [Converter Service](#43-converter-service)
   - [Notification Service](#44-notification-service)
5. [Infrastructure Services (Helm Charts)](#5-infrastructure-services-helm-charts)
   - [MongoDB](#51-mongodb)
   - [PostgreSQL](#52-postgresql)
   - [RabbitMQ](#53-rabbitmq)
6. [Data Flow — Step by Step](#6-data-flow--step-by-step)
7. [Kubernetes Configuration](#7-kubernetes-configuration)
8. [Port Map](#8-port-map)
9. [Configuration and Credentials](#9-configuration-and-credentials)
10. [Known Issues and Applied Fixes](#10-known-issues-and-applied-fixes)
11. [Deployment Summary](#11-deployment-summary)
12. [Technology Stack](#12-technology-stack)

---

## 1. What This Project Does

This is a cloud-native microservices application that converts uploaded MP4 video files into MP3 audio files. It runs on AWS EKS (Elastic Kubernetes Service) and is fully event-driven: a video upload triggers an async conversion pipeline, and the user receives an email notification when the MP3 is ready to download.

The project is primarily a learning exercise demonstrating:
- Python Flask microservices
- Kubernetes orchestration on AWS EKS
- Event-driven architecture with RabbitMQ
- GridFS binary storage in MongoDB
- JWT-based authentication
- Helm chart packaging

---

## 2. High-Level Architecture

```
Client (HTTP)
     │
     ▼
┌─────────────────────────────────────────────────────┐
│  Gateway Service  (Flask :8080 → NodePort :30002)   │
│                                                     │
│  POST /login   ──► Auth Service (:5000)             │
│                        │                            │
│                        ▼                            │
│               PostgreSQL (authdb.auth_user)         │
│                                                     │
│  POST /upload  ──► MongoDB GridFS (videos DB)       │
│                ──► RabbitMQ "video" queue           │
│                                                     │
│  GET  /download ─► MongoDB GridFS (mp3s DB)         │
│                ──► MP3 stream back to client        │
└─────────────────────────────────────────────────────┘
                         │
                    RabbitMQ "video" queue
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│  Converter Service  (4 replicas)                    │
│  MoviePy + ffmpeg                                   │
│                                                     │
│  1. Read video from MongoDB GridFS                  │
│  2. Write to temp file                              │
│  3. Extract audio → MP3                             │
│  4. Store MP3 in MongoDB GridFS (mp3s DB)           │
│  5. Publish to RabbitMQ "mp3" queue                 │
└─────────────────────────────────────────────────────┘
                         │
                    RabbitMQ "mp3" queue
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│  Notification Service  (2 replicas)                 │
│  smtplib + Gmail SMTP                               │
│                                                     │
│  Sends email: "mp3 file_id: <fid> is now ready!"   │
└─────────────────────────────────────────────────────┘
```

---

## 3. Directory Structure

```
microservices-python-app/
│
├── CLAUDE.md                          # Deployment orchestration master guide
├── DEPLOYMENT_CONFIG.md               # All deployment-specific values
├── DEPLOYMENT_HANDOVER.md             # Session state / resume document
├── DEPLOYMENT_REPORT.md               # Post-deployment report
├── DEPLOYMENT_PROBLEMS.md             # Problems log
├── PROJECT_SUMMARY.md                 # This file
├── README.md                          # Public-facing documentation
├── SESSION_SUMMARY.md                 # Narrative of the deployment session
├── Claude_Code_Deployment_Prompt.md   # Prompt used to drive deployment
│
├── customise.sh                       # Sed script that stamps credentials into all files
├── install_prerequisites.sh           # WSL2 tool installer (kubectl, helm, aws cli, etc.)
├── deployment-ids.txt                 # AWS resource IDs recorded during deployment
│
├── assets/
│   ├── video.mp4                      # Test input video
│   └── output.mp3                     # Test output (downloaded during E2E test)
│
├── Helm_charts/
│   ├── MongoDB/
│   │   ├── Chart.yaml
│   │   ├── values.yaml                # MongoDB root & app credentials
│   │   └── templates/
│   │       ├── statefulset.yaml       # MongoDB StatefulSet (1 replica)
│   │       ├── service.yaml           # NodePort :27017 → :30005
│   │       ├── configmap.yaml         # mongo.conf + ensure-users.js init script
│   │       ├── secret.yaml            # Credentials injected as files
│   │       ├── pv.yaml                # hostPath PV at /mnt/data (10Gi)
│   │       ├── pvc.yaml               # PVC requesting 1Gi
│   │       └── storageclass.yaml      # manual StorageClass
│   │
│   ├── Postgres/
│   │   ├── Chart.yaml
│   │   ├── values.yaml                # DB user, password, db name
│   │   ├── init.sql                   # CREATE TABLE + INSERT auth_user row
│   │   └── templates/
│   │       ├── postgres-deploy.yaml   # Deployment (1 replica, no PV)
│   │       └── postgres-service.yaml  # NodePort :5432 → :30003
│   │
│   └── RabbitMQ/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── statefulset.yaml       # rabbitmq:3-management image
│           ├── service.yaml           # NodePort :15672→:30004, ClusterIP :5672
│           ├── configmap.yaml         # Placeholder only
│           ├── secret.yaml            # Placeholder only
│           ├── pv.yaml                # hostPath PV at /mnt/data (10Gi)
│           ├── pvc.yaml               # PVC requesting 1Gi
│           └── storageclasses.yaml    # local-storage StorageClass
│
└── src/
    ├── auth-service/
    │   ├── Dockerfile                 # python:3.10-slim, exposes :5000
    │   ├── requirements.txt           # Flask, psycopg2, PyJWT
    │   ├── server.py                  # /login and /validate endpoints
    │   └── manifest/
    │       ├── deployment.yaml        # 2 replicas, nasi101/auth image
    │       ├── service.yaml           # ClusterIP :5000
    │       ├── configmap.yaml         # DB host, name, user, table
    │       └── secret.yaml            # PSQL_PASSWORD, JWT_SECRET (plaintext in stringData)
    │
    ├── gateway-service/
    │   ├── Dockerfile                 # python:3.10-slim, exposes :8080
    │   ├── requirements.txt           # Flask, PyMongo, Pika, Requests, prometheus-client
    │   ├── server.py                  # /login, /upload, /download routes
    │   ├── auth/validate.py           # Calls auth-service /validate endpoint
    │   ├── auth_svc/access.py         # Calls auth-service /login endpoint
    │   ├── storage/util.py            # GridFS upload + RabbitMQ publish
    │   └── manifest/
    │       ├── gateway-deploy.yaml    # 2 replicas, nasi101/gateway image
    │       ├── service.yaml           # NodePort :8080 → :30002
    │       ├── configmap.yaml         # AUTH_SVC_ADDRESS, MongoDB URIs
    │       └── secret.yaml            # Placeholder only
    │
    ├── converter-service/
    │   ├── Dockerfile                 # python:3.10-slim + ffmpeg system package
    │   ├── requirements.txt           # Pika, PyMongo, MoviePy
    │   ├── consumer.py                # RabbitMQ consumer main loop
    │   ├── convert/to_mp3.py          # Core video→audio logic via MoviePy
    │   └── manifest/
    │       ├── converter-deploy.yaml  # 4 replicas, nasi101/converter image
    │       ├── configmap.yaml         # VIDEO_QUEUE, MP3_QUEUE, MONGODB_URI
    │       └── secret.yaml            # Placeholder only
    │
    └── notification-service/
        ├── Dockerfile                 # python:3.10-slim (+ unnecessary ffmpeg)
        ├── requirements.txt           # Pika only
        ├── consumer.py                # RabbitMQ consumer main loop
        ├── send/email.py              # Gmail SMTP sender
        └── manifest/
            ├── notification-deploy.yaml  # 2 replicas, nasi101/notification image
            ├── configmap.yaml            # MP3_QUEUE, VIDEO_QUEUE
            └── secret.yaml              # GMAIL_ADDRESS, GMAIL_PASSWORD
```

---

## 4. Microservices — Detailed Breakdown

### 4.1 Auth Service

**Image:** `nasi101/auth` | **Replicas:** 2 | **Port:** ClusterIP :5000

**Purpose:** Validates user credentials against PostgreSQL and issues JWT tokens. Never exposed externally — only the Gateway calls it.

**Endpoints:**

| Method | Path | Input | Output |
|--------|------|-------|--------|
| POST | `/login` | HTTP Basic Auth (username:password) | JWT token string (HS256) |
| POST | `/validate` | `Authorization: Bearer <jwt>` header | Decoded JWT payload (JSON) |

**Logic (`server.py`):**

- `/login`: Reads `auth.username` and `auth.password` from the Basic Auth header. Queries `authdb.auth_user` via psycopg2 for a matching email row. If the email and password match exactly (plaintext comparison — no hashing), calls `CreateJWT()`.
- `CreateJWT()`: Issues an HS256 JWT with payload `{username, exp (+1 day), iat, admin: True}`.
- `/validate`: Splits `Authorization: Bearer <token>`, decodes using `JWT_SECRET`, returns the decoded dict as JSON with HTTP 200.

**Environment Variables (from ConfigMap + Secret):**

| Variable | Source | Value |
|----------|--------|-------|
| `DATABASE_HOST` | ConfigMap | `db` (PostgreSQL service name) |
| `DATABASE_NAME` | ConfigMap | `authdb` |
| `DATABASE_USER` | ConfigMap | `pguser` |
| `AUTH_TABLE` | ConfigMap | `auth_user` |
| `DATABASE_PASSWORD` | Secret | `PgSecure2024` |
| `JWT_SECRET` | Secret | `nt0l9Lr3D794SR1IS6Q6vPUu9A91x3AqL0` |

**Dependencies:** PostgreSQL (`db:5432`)

---

### 4.2 Gateway Service

**Image:** `nasi101/gateway` | **Replicas:** 2 | **Port:** NodePort :30002

**Purpose:** Single entry point for all external clients. Handles authentication delegation, file upload to GridFS, and MP3 download from GridFS.

**Endpoints:**

| Method | Path | Auth Required | Description |
|--------|------|---------------|-------------|
| POST | `/login` | No | Proxies credentials to auth-service, returns JWT |
| POST | `/upload` | Yes (JWT) | Accepts one file, stores in MongoDB GridFS, publishes to RabbitMQ |
| GET | `/download?fid=<id>` | Yes (JWT) | Streams MP3 from MongoDB GridFS |

**Logic (`server.py`):**

- **Startup:** Creates two PyMongo connections (`mongo_video`, `mongo_mp3`), two GridFS instances (`fs_videos`, `fs_mp3s`), and one persistent RabbitMQ `BlockingConnection` with `heartbeat=0`.
- `/login`: Delegates to `auth_svc/access.py` which POSTs to `http://auth:5000/login` with the same Basic Auth credentials.
- `/upload`: Calls `auth/validate.py` to POST the JWT to `http://auth:5000/validate`. If valid and `access["admin"]` is True, calls `storage/util.py:upload()` which puts the file in `fs_videos` (GridFS), then publishes a durable JSON message `{video_fid, mp3_fid: null, username}` to the `video` RabbitMQ queue.
- `/download`: Same JWT validation. Retrieves the MP3 by `ObjectId(fid)` from `fs_mp3s` and streams it as a file attachment.

**Sub-modules:**

- `auth/validate.py` — Forwards Authorization header to auth service `/validate`
- `auth_svc/access.py` — Forwards Basic Auth to auth service `/login`
- `storage/util.py` — GridFS `put()` + `channel.basic_publish()` to `video` queue

**Environment Variables:**

| Variable | Source | Value |
|----------|--------|-------|
| `AUTH_SVC_ADDRESS` | ConfigMap | `auth:5000` |
| `MONGODB_VIDEOS_URI` | ConfigMap | `mongodb://mongouser:MongoSecure2024@mongodb:27017/videos?authSource=admin` |
| `MONGODB_MP3S_URI` | ConfigMap | `mongodb://mongouser:MongoSecure2024@mongodb:27017/mp3s?authSource=admin` |

**Dependencies:** Auth Service (`auth:5000`), MongoDB (`mongodb:27017`), RabbitMQ (`rabbitmq:5672`)

---

### 4.3 Converter Service

**Image:** `nasi101/converter` | **Replicas:** 4 | **No external port**

**Purpose:** Consumes video processing jobs from the RabbitMQ `video` queue, converts each MP4 to MP3 using MoviePy and ffmpeg, stores the result in MongoDB GridFS, then publishes a completion message to the `mp3` queue.

**Logic (`consumer.py` + `convert/to_mp3.py`):**

- `consumer.py`:
  - Connects to MongoDB and creates two GridFS instances (`db_videos`, `db_mp3s`).
  - Connects to RabbitMQ and calls `channel.basic_consume(queue="video", callback)`.
  - On each message: calls `to_mp3.start()`. If it returns an error, calls `basic_nack()` (message goes back to queue). On success, calls `basic_ack()`.

- `convert/to_mp3.py`:
  1. Deserializes the JSON message to get `video_fid`.
  2. Fetches the video binary from GridFS using `ObjectId(video_fid)`.
  3. Writes video bytes to a `NamedTemporaryFile`.
  4. Uses `moviepy.editor.VideoFileClip(tf.name).audio` to extract audio.
  5. Writes the audio to `{tmpdir}/{video_fid}.mp3`.
  6. Reads the MP3 file and stores it in `fs_mp3s` via `fs_mp3s.put(data)`.
  7. Publishes updated message `{video_fid, mp3_fid, username}` to the `mp3` queue as a durable message.
  8. Cleans up the temp file.

**Environment Variables:**

| Variable | Source | Value |
|----------|--------|-------|
| `VIDEO_QUEUE` | ConfigMap | `video` |
| `MP3_QUEUE` | ConfigMap | `mp3` |
| `MONGODB_URI` | ConfigMap | `mongodb://mongouser:MongoSecure2024@mongodb:27017/mp3s?authSource=admin` |

**Dependencies:** MongoDB (`mongodb:27017`), RabbitMQ (`rabbitmq:5672`), `ffmpeg` (system package in container)

---

### 4.4 Notification Service

**Image:** `nasi101/notification` | **Replicas:** 2 | **No external port**

**Purpose:** Consumes messages from the `mp3` RabbitMQ queue and sends an email to the user with the MP3 file ID so they can download it.

**Logic (`consumer.py` + `send/email.py`):**

- `consumer.py`:
  - Connects to RabbitMQ and consumes from the `mp3` queue.
  - On each message: calls `email.notification(body)`. Acks or nacks based on return value.

- `send/email.py`:
  1. Deserializes message to get `mp3_fid` and `username` (the user's email address).
  2. Composes an `EmailMessage` with subject "MP3 Download" and body `"mp3 file_id: {mp3_fid} is now ready!"`.
  3. Opens an SMTP connection to `smtp.gmail.com:587`, calls `starttls()`, logs in with the Gmail App Password, and sends the message.

**Environment Variables:**

| Variable | Source | Value |
|----------|--------|-------|
| `MP3_QUEUE` | ConfigMap | `mp3` |
| `GMAIL_ADDRESS` | Secret | `baabalola@gmail.com` |
| `GMAIL_PASSWORD` | Secret | Gmail App Password (16 chars) |

**Dependencies:** RabbitMQ (`rabbitmq:5672`), Gmail SMTP (`smtp.gmail.com:587`)

---

## 5. Infrastructure Services (Helm Charts)

### 5.1 MongoDB

- **Image:** `mongo:4.0.8`
- **Type:** StatefulSet (1 replica)
- **Ports:** ClusterIP :27017, NodePort :30005
- **Storage:** hostPath PV at `/mnt/data`, 10Gi capacity, 1Gi claimed
- **Databases:** `videos` (stores raw video GridFS), `mp3s` (stores converted MP3 GridFS)
- **Initialization:** `ensure-users.js` runs in `docker-entrypoint-initdb.d/` at first start. It authenticates as root, then iterates over `videos` and `mp3s` databases and creates the app user (`mongouser`) with `readWrite` role on each.
- **Credentials:** Injected via Kubernetes Secret as file mounts (root and app credentials stored separately).

### 5.2 PostgreSQL

- **Image:** `postgres` (latest)
- **Type:** Deployment (1 replica, **no PersistentVolume** — data lost on pod restart)
- **Ports:** ClusterIP :5432 (service name `db`), NodePort :30003
- **Database:** `authdb`
- **Schema (init.sql):**
  ```sql
  CREATE TABLE auth_user (
      id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      email VARCHAR(255) NOT NULL,
      password VARCHAR(255) NOT NULL
  );
  INSERT INTO auth_user (email, password) VALUES ('johnbsignups@gmail.com', 'YourPassword123');
  ```
- **Note:** `init.sql` is NOT automatically applied by the Helm chart. It must be run manually via `psql` after the pod starts (Phase 7 of deployment).
- **Credentials:** Passed as environment variables (`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`) from `values.yaml`.

### 5.3 RabbitMQ

- **Image:** `rabbitmq:3-management` (includes HTTP Management API)
- **Type:** StatefulSet (1 replica)
- **Ports:**
  - ClusterIP :5672 (AMQP — used by all microservices)
  - NodePort :30004 → :15672 (Management UI / HTTP API)
- **Storage:** hostPath PV at `/mnt/data`, 10Gi capacity, 1Gi claimed
- **Queues:** `video` and `mp3` (durable) — created manually via HTTP API in Phase 8
- **Default credentials:** `guest:guest`

---

## 6. Data Flow — Step by Step

```
Step 1: User POSTs /login with Basic Auth
  → Gateway → Auth Service → PostgreSQL query
  ← JWT token returned to client

Step 2: User POSTs /upload with video file + Bearer JWT
  → Gateway validates JWT (calls Auth Service /validate)
  → File stored in MongoDB GridFS (videos DB) → returns video_fid
  → Message published to RabbitMQ "video" queue:
    { "video_fid": "<oid>", "mp3_fid": null, "username": "user@email.com" }

Step 3: Converter Service (one of 4 replicas) picks up the message
  → Reads video binary from MongoDB GridFS by video_fid
  → Writes to temp file → MoviePy extracts audio → writes MP3
  → Stores MP3 in MongoDB GridFS (mp3s DB) → returns mp3_fid
  → Publishes to RabbitMQ "mp3" queue:
    { "video_fid": "<oid>", "mp3_fid": "<oid>", "username": "user@email.com" }
  → Acks "video" message

Step 4: Notification Service (one of 2 replicas) picks up the "mp3" message
  → Sends email to username (user's email) via Gmail SMTP:
    Subject: "MP3 Download"
    Body: "mp3 file_id: <mp3_fid> is now ready!"
  → Acks "mp3" message

Step 5: User GETs /download?fid=<mp3_fid> with Bearer JWT
  → Gateway validates JWT
  → Retrieves MP3 binary from MongoDB GridFS by mp3_fid
  → Streams file as attachment (saved as <fid>.mp3)
```

---

## 7. Kubernetes Configuration

### Deployments Summary

| Resource | Kind | Replicas | Image | Config Sources |
|----------|------|----------|-------|----------------|
| `auth` | Deployment | 2 | `nasi101/auth` | auth-configmap, auth-secret |
| `gateway` | Deployment | 2 | `nasi101/gateway` | gateway-configmap, gateway-secret |
| `converter` | Deployment | 4 | `nasi101/converter` | converter-configmap, converter-secret |
| `notification` | Deployment | 2 | `nasi101/notification` | notification-configmap, notification-secret |
| `mongodb` | StatefulSet | 1 | `mongo:4.0.8` | mongodb-configmap, mongodb-secret |
| `rabbitmq` | StatefulSet | 1 | `rabbitmq:3-management` | rabbitmq-configmap, rabbitmq-secret |
| `postgres-deploy` | Deployment | 1 | `postgres` | values.yaml inline env vars |

### Rolling Update Strategy

All deployments use `RollingUpdate` with `maxSurge` set generously (3–8) to allow quick rollouts. No `maxUnavailable` is set (defaults to 25%). No liveness or readiness probes are configured.

### Persistent Storage

| Service | PV Type | Capacity | Claim | Path |
|---------|---------|----------|-------|------|
| MongoDB | hostPath | 10Gi | 1Gi | `/mnt/data` |
| RabbitMQ | hostPath | 10Gi | 1Gi | `/mnt/data` |
| PostgreSQL | None | — | — | ephemeral |

**Note:** Both MongoDB and RabbitMQ PVs use `/mnt/data` as the hostPath. This works with a single-node cluster but would conflict in a multi-node setup.

---

## 8. Port Map

| Port | Protocol | Service | Exposure | Purpose |
|------|----------|---------|----------|---------|
| 30002 | TCP | Gateway | NodePort (external) | Client API — login, upload, download |
| 30003 | TCP | PostgreSQL | NodePort (external) | Admin DB access, init.sql injection |
| 30004 | TCP | RabbitMQ | NodePort (external) | Management UI + HTTP API |
| 30005 | TCP | MongoDB | NodePort (external) | Admin DB access |
| 5000 | TCP | Auth Service | ClusterIP (internal) | JWT login + validation |
| 8080 | TCP | Gateway | ClusterIP (internal) | NodePort target |
| 5432 | TCP | PostgreSQL | ClusterIP (service: `db`) | Auth Service queries |
| 27017 | TCP | MongoDB | ClusterIP (service: `mongodb`) | Gateway + Converter GridFS |
| 5672 | TCP | RabbitMQ | ClusterIP | AMQP — Gateway, Converter, Notification |
| 15672 | TCP | RabbitMQ | ClusterIP (→ NodePort 30004) | Management UI |

---

## 9. Configuration and Credentials

All credentials are stamped into files by `customise.sh` using `sed`. The script reads from `DEPLOYMENT_CONFIG.md` and updates 8 files atomically, then validates no defaults remain.

### Files Modified by `customise.sh`

| File | What Changes |
|------|-------------|
| `Helm_charts/MongoDB/values.yaml` | MongoDB username + password |
| `Helm_charts/Postgres/values.yaml` | PostgreSQL user + password |
| `Helm_charts/Postgres/init.sql` | Login email + password inserted into auth_user |
| `src/auth-service/manifest/secret.yaml` | PSQL_PASSWORD + JWT_SECRET |
| `src/auth-service/manifest/configmap.yaml` | DATABASE_USER |
| `src/gateway-service/manifest/configmap.yaml` | MongoDB URIs (both databases) |
| `src/converter-service/manifest/configmap.yaml` | MONGODB_URI |
| `src/notification-service/manifest/secret.yaml` | GMAIL_ADDRESS + GMAIL_PASSWORD |

### Secret Storage

Secrets are stored in Kubernetes `Secret` objects using `stringData` (unencoded plaintext in YAML, base64 at rest in etcd). This is acceptable for a learning project but not production-ready — in production, use AWS Secrets Manager or Sealed Secrets.

---

## 10. Known Issues and Applied Fixes

| # | Severity | Issue | Location | Fix Applied |
|---|----------|-------|----------|-------------|
| 1 | **High** | `NameError: unauth_count` crashes Gateway pod on first unauthorized request | `gateway-service/server.py` lines 36, 60 | Removed `unauth_count.inc()` calls (Prometheus counter never defined) |
| 2 | **High** | JWT secret was "sarcasm" (default, trivially guessable) | `auth-service/manifest/secret.yaml` | Replaced with 34-char random string |
| 3 | **High** | Plaintext passwords in PostgreSQL (no hashing) | `init.sql`, `auth-service/server.py` | Not fixed — acceptable for learning; document only |
| 4 | **High** | Credentials in source YAML files | All `secret.yaml`, `values.yaml` | Not fixed — never push to a public repo |
| 5 | **Low** | `ffmpeg` installed in notification Dockerfile unnecessarily (+100MB) | `notification-service/Dockerfile` | Not fixed — acceptable; notification service doesn't use ffmpeg |
| 6 | **Medium** | No liveness/readiness probes on any deployment | All deployment manifests | Out of scope for this deployment |
| 7 | **Medium** | No resource limits/requests on any deployment | All deployment manifests | Out of scope for this deployment |
| 8 | **Medium** | PostgreSQL has no PersistentVolume (data lost on restart) | `Helm_charts/Postgres/` | Acceptable for learning; use RDS in production |
| 9 | **Low** | `prometheus-client` in gateway requirements.txt but unused | `gateway-service/requirements.txt` | Not fixed — dead dependency only |

---

## 11. Deployment Summary

### AWS Resources Created

| Resource | ID / Value |
|----------|-----------|
| Region | `eu-west-2` |
| EKS Cluster | `cba-microservices` |
| Node Instance | `m7i-flex.large` (2 vCPU / 8 GB RAM) |
| Node Instance ID | `i-0d93e8c9a1ce8cfc8` |
| Node External IP | `13.42.28.15` |
| EKS Cluster Role | `eks-cluster-role` |
| EKS Node Role | `eks-node-role` |

### Deployment Phases

| Phase | Name | Status |
|-------|------|--------|
| 0 | Prerequisites | Complete |
| 1 | IAM Roles | Complete |
| 2 | VPC / Networking | Complete |
| 3 | EKS Cluster + Node Group | Complete |
| 4 | Security Group Rules | Complete |
| 5 | File Customisation + Bug Fixes | Complete |
| 6 | Helm Deployments (MongoDB, Postgres, RabbitMQ) | Complete |
| 7 | PostgreSQL Init (init.sql) | Complete |
| 8 | RabbitMQ Queue Creation | Complete |
| 9 | Docker Images (prebuilt nasi101/*) | Complete |
| 10 | Microservice Deployments | Complete |
| 11 | End-to-End Test | Complete — output.mp3 downloaded |
| 12 | Final Report | Complete |

### Notable Deployment Challenge

**T-type instance failure (~39 min lost):**  
The initial t3.medium node group reached `CREATE_FAILED` with error `AsgInstanceLaunchFailures: InvalidParameterCombination`. Root cause: EKS auto-generates `CreditSpecification: unlimited` for T-type instances, which this AWS account's SCPs reject. Resolution: switched to `m7i-flex.large`.

**Rule for this account:** Always use M/C/R-series instances. Never use T-type instances.

### Live API Endpoints

```bash
# Login
curl -X POST http://13.42.28.15:30002/login -u "johnbsignups@gmail.com:YourPassword123"

# Upload (replace $JWT with token from login)
curl -X POST http://13.42.28.15:30002/upload \
  -F "file=@assets/video.mp4" \
  -H "Authorization: Bearer $JWT"

# Download (replace FILE_ID from email notification)
curl -X GET "http://13.42.28.15:30002/download?fid=FILE_ID" \
  -H "Authorization: Bearer $JWT" -o output.mp3

# RabbitMQ Management UI
open http://13.42.28.15:30004   # guest:guest
```

---

## 12. Technology Stack

| Layer | Technology | Version | Notes |
|-------|-----------|---------|-------|
| HTTP framework | Flask | 2.2.2 | All 4 microservices |
| JWT | PyJWT | 2.6.0 | HS256 signing |
| PostgreSQL driver | psycopg2 | 2.9.5 | Auth service only |
| MongoDB driver | PyMongo + Flask-PyMongo | 4.3.3 | Gateway + Converter |
| RabbitMQ client | Pika | 1.3.1 | Gateway, Converter, Notification |
| Video conversion | MoviePy | 1.0.3 | Converter service |
| Audio extraction | ffmpeg | system pkg | Converter container |
| Container runtime | Docker | — | python:3.10-slim-bullseye base |
| Orchestration | Kubernetes (AWS EKS) | 1.31 | Single node group |
| Helm | Helm | — | MongoDB, Postgres, RabbitMQ charts |
| Cloud | AWS | — | EKS, EC2 (m7i-flex.large) |
| Storage | AWS EBS / hostPath PV | — | MongoDB + RabbitMQ |
| Email | Gmail SMTP | TLS 587 | App Password auth |
