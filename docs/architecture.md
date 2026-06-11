# VidCast — Architecture Reference

## System Overview

VidCast is an event-driven microservices platform. When a user uploads a video, it is stored immediately and a message is published to a queue. Worker pods pick up the message asynchronously, convert the video to MP3, and trigger an email notification. The user never waits for conversion — they get a notification when it's ready.

This pattern (store-and-queue instead of store-and-block) is the same one used by YouTube, TikTok, Spotify, and every media processing platform at scale.

---

## Service Inventory

### Frontend Service

- **Technology:** React 18 + Vite + Tailwind CSS, served by nginx
- **Image:** `<YOUR_DOCKERHUB_USER>/frontend`
- **Port:** NodePort 30006
- **Replicas:** 1
- **Purpose:** Web interface — login, upload, download, monitoring dashboard, architecture diagram
- **Build:** Multi-stage Dockerfile (Node.js build → nginx serve)
- **Security:** Runs as non-root uid 1001, HTTP liveness/readiness probes

### Gateway Service

- **Technology:** Flask 2.2, PyMongo, Pika
- **Image:** `nasi101/gateway`
- **Port:** NodePort 30002 (8080 in-cluster)
- **Replicas:** 2
- **Purpose:** The single external entry point. Handles authentication delegation, file storage, and queue publishing.
- **Routes:**
  - `POST /login` → delegates to Auth Service → returns JWT
  - `POST /upload` → validates JWT → stores video in MongoDB GridFS → publishes file ID to RabbitMQ video queue
  - `GET /download?fid=` → validates JWT → retrieves MP3 from MongoDB GridFS → streams to client
  - `GET /healthz` → checks MongoDB + RabbitMQ → 200 ok / 503 degraded
- **Security:** CORS enabled, readOnlyRootFilesystem, resource limits 100m-300m CPU / 128Mi-256Mi RAM

### Auth Service

- **Technology:** Flask 2.2, PyJWT, psycopg2
- **Image:** `nasi101/auth`
- **Port:** ClusterIP 5000 (internal only — not accessible outside the cluster)
- **Replicas:** 2
- **Purpose:** Issues and validates JWT tokens. Reads user credentials from PostgreSQL.
- **Routes:**
  - `POST /login` → queries PostgreSQL for email/password → returns JWT (1-day expiry)
  - `POST /validate` → decodes and verifies JWT → returns claims
  - `GET /healthz` → checks PostgreSQL connectivity → 200 ok / 503 error
- **Security:** ClusterIP only, readOnlyRootFilesystem, resource limits 50m-200m CPU / 64Mi-128Mi RAM

### Converter Service

- **Technology:** Python, Pika, PyMongo, MoviePy, ffmpeg
- **Image:** `nasi101/converter`
- **Port:** None (queue consumer only — no HTTP interface)
- **Replicas:** 4
- **Purpose:** Processes the video queue. For each message, fetches the video from MongoDB, runs ffmpeg to extract audio, stores the MP3 back in MongoDB, acknowledges the message, publishes the MP3 file ID to the mp3 queue, and touches `/tmp/healthy`.
- **Security:** emptyDir volume at /tmp (needed for temp files during conversion), readOnlyRootFilesystem, resource limits 250m-500m CPU / 256Mi-512Mi RAM

### Notification Service

- **Technology:** Python, Pika, smtplib
- **Image:** `nasi101/notification`
- **Port:** None (queue consumer only — no HTTP interface)
- **Replicas:** 2
- **Purpose:** Processes the mp3 queue. For each message, sends an email via Gmail SMTP containing the file ID for download.
- **Security:** emptyDir volume at /tmp, readOnlyRootFilesystem, resource limits 50m-100m CPU / 64Mi-128Mi RAM

---

## Infrastructure Services

### MongoDB (StatefulSet)

- **Image:** mongo:4.0.8
- **Port:** NodePort 30005 (27017 in-cluster)
- **Storage:** GridFS — stores binary files (video and MP3) chunked into 255KB pieces
- **Databases:** `videos` (uploaded MP4s), `mp3s` (converted MP3s)
- **Note:** No PersistentVolume — data is lost if the pod is deleted. Acceptable for demo; use Atlas or DocumentDB in production.

### PostgreSQL (Deployment)

- **Port:** NodePort 30003 (5432 in-cluster)
- **Database:** `authdb`
- **Table:** `auth_user` (email, password)
- **Note:** No PersistentVolume. Use RDS for production.

### RabbitMQ (StatefulSet)

- **Image:** rabbitmq:3-management
- **Ports:** NodePort 30004 (management UI), 5672 (AMQP in-cluster)
- **Queues:** `video` (durable), `mp3` (durable)
- **Durability:** Messages survive RabbitMQ restarts

---

## Data Flow — Upload

```
1. User POSTs MP4 to Gateway :30002/upload with JWT
2. Gateway validates JWT with Auth Service
3. Gateway stores MP4 binary in MongoDB GridFS → receives file_id
4. Gateway publishes file_id to RabbitMQ "video" queue
5. Gateway returns "success!" to user immediately
6. (Asynchronously) Converter pod picks up file_id from "video" queue
7. Converter fetches MP4 bytes from MongoDB by file_id
8. Converter runs ffmpeg to extract audio as MP3
9. Converter stores MP3 binary in MongoDB GridFS → receives mp3_id
10. Converter publishes mp3_id to RabbitMQ "mp3" queue
11. (Asynchronously) Notification pod picks up mp3_id from "mp3" queue
12. Notification sends email with mp3_id to user
13. User GETs /download?fid=mp3_id → Gateway streams MP3 from MongoDB
```

---

## Port Map

| Port | Service | Access |
|------|---------|--------|
| 30002 | Gateway API | Public — client entry point |
| 30003 | PostgreSQL | Admin only |
| 30004 | RabbitMQ Management | Admin only |
| 30005 | MongoDB | Admin only |
| 30006 | Frontend | Public — web interface |
| 30007 | Grafana | Admin only |
| 30008 | Alertmanager | Admin only |

---

## Security Architecture

### What's implemented

- **Non-root containers:** All pods run as uid 1000 (or 1001 for frontend nginx)
- **Read-only root filesystem:** Containers cannot modify their own binaries or config files at runtime. Converter and notification mount an `emptyDir` at `/tmp` for temporary files.
- **Capability dropping:** All Linux capabilities dropped (`capabilities.drop: ["ALL"]`)
- **No privilege escalation:** `allowPrivilegeEscalation: false` on all containers
- **Resource limits:** Prevents one service from starving others on the shared node
- **Health probes:** Kubernetes detects and restarts unhealthy pods automatically
- **Secrets not in Git:** `**/secret.yaml` is gitignored; secrets are applied via `kubectl apply` outside of version control
- **Image scanning:** Trivy scans every image build for CRITICAL and HIGH CVEs before push

### What's discussed but not implemented

- **mTLS between services:** Requires a service mesh (Istio, Linkerd). Docker Swarm provides mTLS built-in; Kubernetes requires explicit setup.
- **Network Policies:** Currently all pods can talk to all other pods. Network Policies would restrict Auth to only accept traffic from Gateway, etc.
- **External Secrets Operator:** Secrets currently stored in Kubernetes Secret objects (base64, not encrypted). External Secrets + AWS Secrets Manager would fetch secrets at runtime via IRSA.
- **Image signing:** Trivy scans for known CVEs; Cosign/Sigstore would add cryptographic signing so only verified images can run.

---

## Environments

| Environment | Platform | Purpose | Cost |
|-------------|----------|---------|------|
| Production | AWS EKS eu-west-2 (m7i-flex.large) | Live traffic | ~$150/month |
| Staging | Docker Swarm (t2.micro EC2) | Pre-production via Jenkins | ~$10/month |
| Local | Docker Compose | Developer testing | Free |

Staging uses Docker Swarm rather than a second EKS cluster — a 97% cost reduction with equivalent functionality for integration testing.
