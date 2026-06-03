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

> **Note:** Never use T-type instances on this account. The Terraform EKS module includes a validation block that rejects them. Use `m7i-flex.large` or any M/C/R-series type.

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

```bash
kubectl apply -f src/auth-service/manifest/
kubectl apply -f src/gateway-service/manifest/
kubectl apply -f src/converter-service/manifest/
kubectl apply -f src/notification-service/manifest/
kubectl apply -f src/frontend/manifest/
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

See `GITHUB_SECRETS_REQUIRED.md` for the secrets to configure.

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
| Alertmanager | `http://NODE_IP:30008` | — |

---

## Security

- All pods run as non-root (uid 1000), read-only root filesystem, capabilities dropped
- Resource limits on every container — converters can't starve gateway/auth
- HTTP health probes on auth + gateway; exec probes on converter + notification
- Secrets gitignored — never committed
- Images scanned with Trivy before push; tagged with git SHA (no `:latest` in production)

---

## Teardown

```bash
# Microservices
kubectl delete -f src/auth-service/manifest/
kubectl delete -f src/gateway-service/manifest/
kubectl delete -f src/converter-service/manifest/
kubectl delete -f src/notification-service/manifest/
kubectl delete -f src/frontend/manifest/

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
├── .github/workflows/    # CI (lint+scan+build+push) and CD (EKS deploy)
├── Helm_charts/          # MongoDB, PostgreSQL, RabbitMQ Helm charts
├── Jenkinsfile           # Enterprise CI/CD pipeline with Swarm staging
├── docker-compose.swarm.yml  # Docker Swarm staging environment
├── monitoring/           # kube-prometheus-stack values, dashboard, alerts
├── src/
│   ├── auth-service/
│   ├── converter-service/
│   ├── frontend/         # React web app + nginx + Kubernetes manifests
│   ├── gateway-service/
│   └── notification-service/
└── terraform/
    ├── environments/dev/ # Root module (main, variables, outputs, backend)
    └── modules/          # vpc, iam, eks, security-groups
```
This is an edit to trigger CI, which builds the Docker images