# VidCast — Video-to-Audio Microservices Platform

**Turn video recordings into podcast-ready audio.**

VidCast is a production-grade Python microservices platform running on AWS EKS. Upload an MP4, and the platform converts it to MP3 asynchronously — then emails you a download link. Built to demonstrate event-driven architecture, container security, CI/CD automation, and infrastructure as code.

---

## What's Inside

| Component | Technology | What it does |
|-----------|-----------|--------------|
| Frontend | React 18 + nginx | Web interface — login, upload, download, monitoring dashboard |
| Gateway API | Flask + GridFS + Pika | Entry point — handles uploads, downloads, JWT validation |
| Auth Service | Flask + PyJWT + psycopg2 | Issues and validates JWT tokens against PostgreSQL |
| Converter | Pika + MoviePy + ffmpeg | 4 worker pods consuming RabbitMQ, converting MP4 → MP3 |
| Notification | Pika + smtplib | 2 worker pods sending email with download link |
| MongoDB | mongo:4.0.8 StatefulSet | Stores video and MP3 files via GridFS |
| PostgreSQL | postgres Deployment | User credentials for auth |
| RabbitMQ | rabbitmq:3-management | Message broker — video queue and mp3 queue |

## Architecture

```
Browser
  │
  ▼
Frontend (React, NodePort :30006)
  │
  ▼
Gateway (Flask :8080, NodePort :30002)
  ├── /login ──► Auth Service (:5000) ──► PostgreSQL (:5432)
  ├── /upload ──► MongoDB GridFS ──► RabbitMQ "video" queue
  └── /download ◄── MongoDB GridFS
                          │
               RabbitMQ "video" queue
                          │
                    Converter ×4 (ffmpeg)
                    ├── fetch video from MongoDB
                    ├── convert to MP3
                    ├── store MP3 in MongoDB
                    └── publish to RabbitMQ "mp3" queue
                               │
                    Notification ×2 (smtplib)
                    └── email file ID to user
```

---

## Infrastructure

- **Platform:** AWS EKS eu-west-2 (London)
- **Node type:** m7i-flex.large — 2 vCPU / 8 GB RAM
- **IaC:** Terraform modules for VPC, IAM, EKS, security groups
- **Helm charts:** MongoDB, PostgreSQL, RabbitMQ
- **CI/CD:** GitHub Actions (lint → Trivy scan → build → push → EKS deploy)
- **Staging:** Docker Swarm on EC2 t2.micro (97% cheaper than a second EKS cluster)
- **Monitoring:** kube-prometheus-stack — Grafana :30007, Alertmanager :30008

---

## Quick Start — Deploy to AWS

> **New here?** For the full, narrated walkthrough from cloning the repo all the way to
> teardown — including configuration, seeding, CI/CD secrets, and troubleshooting — follow
> **[`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md)**. The steps below are the
> condensed version.

### Prerequisites

```bash
# Tools required
aws --version       # AWS CLI v2
kubectl version     # kubectl 1.31+
helm version        # Helm 3.x
terraform version   # Terraform 1.5+
```

### 1 — Provision infrastructure with Terraform

```bash
cd terraform/environments/dev

# Copy and fill in your values
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your state bucket name etc.

terraform init \
  -backend-config="bucket=YOUR_STATE_BUCKET" \
  -backend-config="key=vidcast/dev/terraform.tfstate" \
  -backend-config="region=eu-west-2" \
  -backend-config="dynamodb_table=vidcast-terraform-locks"

terraform plan
terraform apply
```

### 2 — Deploy infrastructure services

```bash
# Connect kubectl to the new cluster
aws eks update-kubeconfig --name vidcast-cluster --region eu-west-2

# Deploy MongoDB, PostgreSQL, RabbitMQ
cd Helm_charts/MongoDB && helm install mongodb . && cd ../..
kubectl wait --for=condition=ready pod/mongodb-0 --timeout=120s
cd Helm_charts/Postgres && helm install postgres . && cd ../..
cd Helm_charts/RabbitMQ && helm install rabbitmq . && cd ../..
```

### 3 — Initialise PostgreSQL

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
PGPASSWORD=YOUR_POSTGRES_PASSWORD psql -h $NODE_IP -p 30003 \
  -U YOUR_POSTGRES_USERNAME -d authdb -f Helm_charts/Postgres/init.sql
```

### 4 — Create RabbitMQ queues

```bash
curl -u guest:guest -X PUT http://$NODE_IP:30004/api/queues/%2F/video \
  -H "Content-Type: application/json" -d '{"durable":true}'
curl -u guest:guest -X PUT http://$NODE_IP:30004/api/queues/%2F/mp3 \
  -H "Content-Type: application/json" -d '{"durable":true}'
```

### 5 — Deploy microservices

Application manifests are managed with **Kustomize** (`k8s/base` + per-environment
overlays in `k8s/overlays/{dev,prod}`). Secrets are *not* in the Kustomize tree —
apply them first (from the gitignored `secret.yaml` files, or via External
Secrets Operator), then apply the overlay.

```bash
# 1. Create the per-service Secrets (gitignored; rabbitmq-secret comes from the
#    RabbitMQ Helm chart):
kubectl apply -f src/auth-service/manifest/secret.yaml
kubectl apply -f src/gateway-service/manifest/secret.yaml
kubectl apply -f src/converter-service/manifest/secret.yaml
kubectl apply -f src/notification-service/manifest/secret.yaml

# 2. Deploy all services via Kustomize (use overlays/dev for the lighter dev env):
kubectl apply -k k8s/overlays/prod
kubectl get pods  # all should reach Running
```

### 6 — Test end-to-end

```bash
# Login
TOKEN=$(curl -s -X POST http://$NODE_IP:30002/login -u "EMAIL:PASSWORD")

# Upload
curl -X POST http://$NODE_IP:30002/upload \
  -F "file=@assets/video.mp4" -H "Authorization: Bearer $TOKEN"

# Download (use file_id from notification email)
curl -X GET "http://$NODE_IP:30002/download?fid=FILE_ID" \
  -H "Authorization: Bearer $TOKEN" -o output.mp3
```

---

## CI/CD Pipeline

Push to `main` triggers the pipeline automatically:

```
push to main
  └── GitHub Actions ci.yml
        ├── ruff lint (Python)
        ├── Docker build × 4 services (matrix)
        ├── Trivy scan (CRITICAL + HIGH — fails build if found)
        └── Push to Docker Hub (tagged with short git SHA)
              └── GitHub Actions cd.yml
                    ├── aws eks update-kubeconfig
                    └── kubectl set image × 4 deployments
```

Jenkins pipeline (`Jenkinsfile`) mirrors the same stages for enterprise environments, adding a Docker Swarm staging deploy and a manual approval gate before production.

See [`docs/GETTING_STARTED.md` → CI/CD secrets](docs/GETTING_STARTED.md#10-cicd-secrets) for the secrets to configure (none are stored in this repo).

---

## Monitoring

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install monitoring prometheus-community/kube-prometheus-stack \
  -f monitoring/values.yaml -n monitoring --create-namespace

kubectl apply -f monitoring/alerts/vidcast-alerts.yaml
```

| Dashboard | URL | Credentials |
|-----------|-----|-------------|
| Grafana — VidCast Operations | `http://NODE_IP:30007` | admin / vidcast-demo |
| Grafana — SLO / Error Budget (B4) | `http://NODE_IP:30007` (uid `vidcast-slo`) | admin / vidcast-demo |
| Grafana — FinOps / Cost (B3) | `http://NODE_IP:30007` (uid `vidcast-finops`) | admin / vidcast-demo |
| Alertmanager | `http://NODE_IP:30008` | — |

---

## What does VidCast cost?

Cost visibility via **Kubecost** (OSS/OpenCost core, no license key) — see
`k8s/kubecost/` and `FINOPS_EXPLAINED.md`.

**Headline: cost per conversion.**

```
cost_per_conversion = cluster_$/hr ÷ conversions/hr
                    = sum(node_total_hourly_cost) ÷ (rate(vidcast_conversions_total{status="success"}[1h]) × 3600)
```

It joins Kubecost's `node_total_hourly_cost` with the B4 SLO counter
`vidcast_conversions_total`. _(Screenshot placeholder — fill from the live FinOps
dashboard.)_

**Accuracy caveat:** Kubecost **estimates** from instance list pricing —
m7i-flex.large ≈ **$0.106/hr** (eu-west-2 on-demand; verify current pricing), so the
node is ~$77/mo + ~$73/mo EKS control-plane ≈ the ~$150/mo figure. The **AWS Cost
Explorer bill is ground truth**; Kubecost is for *attribution and trends* (who/what,
relative change), not the absolute invoice.

**The node-sizing story:** on a 2-vCPU node, Kubecost is the **largest single
observability cost** — its default bundled Prometheus would eat ~1 of 2 CPUs. We
strip it to one ~175m pod pointed at the existing Prometheus; even so it tips the
prod footprint past the 90% idle budget gate, so it runs against the dev footprint
or scales to zero between analyses. _The cost of measuring cost must be smaller than
what it saves._

---

## Security

- All pods run as non-root (uid 1000), read-only root filesystem, capabilities dropped
- Resource limits on every container — converters can't starve gateway/auth
- HTTP health probes on auth + gateway; exec probes on converter + notification
- Secrets gitignored — never committed
- Images scanned with Trivy before push; tagged with git SHA (no `:latest` in production)

---

## Reliability

**Transactional outbox (no lost uploads).** When `OUTBOX_ENABLED=true`, the
gateway records each upload event as a row in a MongoDB `outbox` collection
(durable, in the same database as the video) instead of publishing straight to
RabbitMQ. A dedicated single-replica `outbox-relay` deployment polls the
collection and publishes pending rows to the `video` queue, marking each
`published_at` on success. If RabbitMQ is down at upload time the event is **not
lost** — it publishes once the broker recovers.

The relay is a separate `replicas: 1` deployment (not an in-process thread)
because the gateway runs multi-process under gunicorn — one publisher by
construction avoids duplicate sends. Roll out with the flag off (relay idle),
then flip to `true`. See `OUTBOX_EXPLAINED.md` for the full design and the
single-node consistency caveat.

**Retry / dead-letter topology.** Each pipeline (`video`, `mp3`) has a delayed
retry queue and a terminal dead-letter queue. A failed message is retried
`MAX_RETRIES` times (with a `RETRY_TTL_MS` delay between attempts) and then parked
in `<queue>.dlq` via the `vidcast.dlx` exchange — replacing the old infinite
NACK-requeue loop on poison messages. Declared from code at consumer startup.

**Idempotent consumers.** With `IDEMPOTENCY_ENABLED=true`, the converter and
notification consumers claim each job once (Redis `SET NX EX`, keyed on
`video_fid`/`mp3_fid`) so an at-least-once redelivery isn't converted/emailed
twice. Redis runs in-cluster; `claim_once` fails open if Redis is unavailable
(degrades to a possible duplicate, never a stuck pipeline).

| Flag | Where | Default | Effect |
|------|-------|---------|--------|
| `OUTBOX_ENABLED` | `gateway-configmap` | `false` | `false` = gateway publishes directly to RabbitMQ (legacy path, unchanged). `true` = uploads routed through the outbox + relay. |
| `IDEMPOTENCY_ENABLED` | `converter`/`notification` configmaps | `false` | `false` = consumers behave as before. `true` = claim-once dedup via Redis. |
| `MAX_RETRIES` / `RETRY_TTL_MS` | `converter`/`notification` configmaps | `3` / `30000` | Retry count and inter-attempt delay before a message is dead-lettered. |

See `OUTBOX_EXPLAINED.md`, `DLQ_TOPOLOGY_EXPLAINED.md`, `IDEMPOTENCY_EXPLAINED.md`
for the full designs.

---

## Teardown

```bash
# Microservices (Kustomize — match the overlay you deployed)
kubectl delete -k k8s/overlays/prod

# Helm
helm uninstall mongodb postgres rabbitmq
helm uninstall monitoring -n monitoring

# Infrastructure
cd terraform/environments/dev
terraform destroy
```

---

## Bugs Fixed

| # | Severity | Issue | Fix |
|---|----------|-------|-----|
| 1 | High | `unauth_count.inc()` NameError in gateway service crashes pod on any 401 response | Removed 2 stale Prometheus stub lines |
| 2 | High | JWT secret was `"sarcasm"` (base64) — trivially guessable | Replaced with 34-char random string |

---

## Repository Structure

```
├── README.md             # You are here — overview + condensed quick start
├── CLAUDE.md             # Operating instructions for AI assistants (build/deploy playbook)
├── VIDCAST_UPGRADE_PLAN.md   # The plan that took the base project to production-grade
├── Jenkinsfile           # Enterprise CI/CD pipeline with Swarm staging + approval gate
├── docker-compose.swarm.yml  # Docker Swarm staging environment
├── install_prerequisites.sh  # Installs kubectl, Helm, Terraform, Python, psql, mongosh
├── .github/workflows/    # CI (lint+scan+build+push) and CD (OIDC → EKS deploy)
├── Helm_charts/          # MongoDB, PostgreSQL, RabbitMQ Helm charts
├── monitoring/           # kube-prometheus-stack values, dashboard, alerts
├── assets/               # Sample video.mp4 for end-to-end testing
├── docs/                 # All project documentation — see docs/README.md
│   ├── README.md         #   Index: which doc to read for what
│   ├── GETTING_STARTED.md#   Full clone → run → teardown walkthrough
│   ├── PROJECT_GUIDE.md  #   Comprehensive guide (technical + plain English)
│   ├── architecture.md   #   Service inventory, ports, data flow reference
│   ├── deployment-guide.md   # Phase-by-phase operations reference
│   ├── presentation-notes.md # Timed demo script
│   ├── DECISIONS_MADE.md #   Architectural decision records
│   └── MERGE_RUNBOOK_RBAC.md # RBAC/bcrypt merge runbook
├── src/
│   ├── auth-service/
│   ├── converter-service/
│   ├── frontend/         # React web app + nginx + Kubernetes manifests
│   ├── gateway-service/
│   └── notification-service/
└── terraform/
    ├── environments/dev/ # Root module (main, variables, outputs, backend)
    └── modules/          # vpc, iam, eks, security-groups, github-oidc
```

## Documentation

Full documentation lives in **[`docs/`](docs/)** — start with
**[`docs/README.md`](docs/README.md)**, which points you to the right document:

- **Run it** → [`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md)
- **Understand it** → [`docs/PROJECT_GUIDE.md`](docs/PROJECT_GUIDE.md)
- **Look something up** → [`docs/architecture.md`](docs/architecture.md)
- **Present it** → [`docs/presentation-notes.md`](docs/presentation-notes.md)

> **Security note:** no real credentials are committed to this repo. Account-specific
> values appear as placeholders (`<AWS_ACCOUNT_ID>`, `YOUR_STATE_BUCKET`,
> `admin@example.com`, `<BCRYPT_HASH_HERE>`). Supply your own via the gitignored
> `terraform.tfvars` / `DEPLOYMENT_CONFIG.md` and your CI/CD secret store.
