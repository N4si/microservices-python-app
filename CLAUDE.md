# CLAUDE.md — VidCast Platform (Video-to-Audio Microservices on AWS EKS)

---

## ⚠️ READ THIS FIRST — BEFORE ANYTHING ELSE

### Step 1 — Identify which prompt type is being used

This file supports two execution modes. The mode determines who builds the CI/CD pipeline, health endpoints, and security hardening.

```
FULL PROMPT   (CLAUDE_CODE_FULL_PROMPT_V2.md)
  → Claude builds everything — all phases, all files
  → Sections marked [FULL ONLY] apply
  → Sections marked [HYBRID ONLY] do NOT apply — skip them

HYBRID PROMPT (CLAUDE_CODE_HYBRID_PROMPT_V2.md)
  → Claude builds Terraform, monitoring, frontend, Swarm compose, docs
  → Developer manually builds CI/CD, health endpoints, security hardening
  → Sections marked [HYBRID ONLY] apply
  → Sections marked [FULL ONLY] do NOT apply — skip them
```

Read the active prompt file to determine mode. If uncertain, ask.

### Step 2 — Read all companion files

```bash
ls -la *.md
cat VIDCAST_UPGRADE_PLAN.md
ls DEPLOYMENT_CONFIG.md 2>/dev/null && cat DEPLOYMENT_CONFIG.md
ls DEPLOYMENT_HANDOVER.md 2>/dev/null && cat DEPLOYMENT_HANDOVER.md
```

If `DEPLOYMENT_CONFIG.md` has unfilled bracket placeholders (`[VALUE]`), list them and ask the user to fill them before proceeding. Do NOT continue with placeholder values.

### Step 3 — Check for a previous session

If `DEPLOYMENT_HANDOVER.md` exists, read it, identify which phases are complete, and resume from the next incomplete phase. Never recreate resources that already exist.

### Step 4 — Validate AWS access

```bash
aws sts get-caller-identity
```

---

## Concurrent File Management (Non-Negotiable)

Maintain two tracking files throughout ALL work. These are your crash recovery system.

**DEPLOYMENT_HANDOVER.md** — Session state. Update this:
- BEFORE any destructive operation (terraform destroy, kubectl delete, helm uninstall)
- AFTER every completed phase
- AFTER every successful infrastructure change (terraform apply, helm install, kubectl apply)
- IMMEDIATELY if usage limits are approaching — save state before stopping

**DEPLOYMENT_REPORT.md** — Full record of everything done. Update after every significant action.

If Claude Code stops for any reason, the next session reads DEPLOYMENT_HANDOVER.md and resumes exactly from where it left off. Every phase completion and every resource ID must be recorded here.

DEPLOYMENT_HANDOVER.md structure:
```markdown
# VidCast Deployment Handover
## Last Updated: [timestamp]

### Base Deployment Phases (0-12)
- [x] Phase 0: Prerequisites
- [ ] Phase 1: IAM Roles
...

### Upgrade Phases
- [ ] Phase U0: Repo Cleanup
- [ ] Phase U1: Terraform IaC
...

### AWS Resources
- VPC ID: [value]
- EKS Cluster: [value]
- Node Group: [value]
- Node IP: [value]
- Security Group: [value]

### Staging Environment
- Swarm EC2 IP: [value]
- Swarm status: [running/stopped/not created]

### Resume Instructions
[Exact commands to pick up from current state]
```

---

## Project Overview

**Product:** VidCast — "Turn video recordings into podcast-ready audio"

This is a Python microservices platform that converts uploaded MP4 video files to MP3 audio files. It runs on AWS EKS with an event-driven, asynchronous architecture. A user uploads a video, it's processed via a RabbitMQ pipeline, and they receive an email with the download link.

**Repository base:** https://github.com/N4si/K8s-video-converter.git (forked to student's account)

---

## System Architecture

```
Client (Browser / curl / React Frontend)
     │
     ▼
┌──────────────────────────────────────────────────────┐
│  Frontend — React + nginx (NodePort :30006)  [NEW]   │
│  Login → Upload → Download → Dashboard → Arch Diagram│
└──────────────────────────────────────────────────────┘
     │
     ▼
┌──────────────────────────────────────────────────────┐
│  Gateway Service — Flask :8080 (NodePort :30002)     │
│  POST /login    → Auth Service (:5000) → PostgreSQL  │
│  POST /upload   → MongoDB GridFS + RabbitMQ "video"  │
│  GET  /download → MongoDB GridFS → stream MP3        │
│  GET  /healthz  → health check endpoint [NEW]        │
└──────────────────────────────────────────────────────┘
     │
     ▼ RabbitMQ "video" queue
┌──────────────────────────────────────────────────────┐
│  Converter Service — 4 replicas (Pika + ffmpeg)      │
│  Reads video → extracts audio → stores MP3           │
│  → publishes to RabbitMQ "mp3" queue                 │
└──────────────────────────────────────────────────────┘
     │
     ▼ RabbitMQ "mp3" queue
┌──────────────────────────────────────────────────────┐
│  Notification Service — 2 replicas (Pika + smtplib)  │
│  Sends email with file ID for download               │
└──────────────────────────────────────────────────────┘
```

### Services

| Service | Technology | Replicas | Access | Health Check |
|---------|-----------|----------|--------|-------------|
| Frontend | React + nginx | 1 | NodePort :30006 | HTTP GET / |
| Auth Service | Flask + PyJWT + psycopg2 | 2 | ClusterIP :5000 | HTTP GET /healthz |
| Gateway Service | Flask + PyMongo + Pika | 2 | NodePort :30002 | HTTP GET /healthz |
| Converter Service | Pika + MoviePy + ffmpeg | 4 | None (queue consumer) | Exec: test -f /tmp/healthy |
| Notification Service | Pika + smtplib | 2 | None (queue consumer) | Exec: test -f /tmp/healthy |
| MongoDB | mongo:4.0.8 | 1 (StatefulSet) | NodePort :30005 | TCP :27017 |
| PostgreSQL | postgres | 1 (Deployment) | NodePort :30003 | TCP :5432 |
| RabbitMQ | rabbitmq:3-management | 1 (StatefulSet) | NodePort :30004 | TCP :5672 |

### Environments

| Environment | Platform | Purpose | Cost |
|-------------|----------|---------|------|
| Production | AWS EKS eu-west-2 (m7i-flex.large) | Live traffic | ~$150/month |
| Staging | Docker Swarm (t2.micro EC2) | Pre-production via Jenkins | ~$10/month |
| Local | Docker Compose | Developer testing | Free |

**Why Docker Swarm for staging:** A second EKS staging environment costs ~$0.40/hour (~$290/month). A Swarm staging environment on a single t2.micro costs ~$0.01/hour (~$7.50/month, free tier eligible). 97% cost reduction for a functionally equivalent testing environment. The Jenkins pipeline deploys to Swarm first, runs a smoke test, waits for human approval, then deploys to EKS. This directly connects the Docker Swarm bootcamp module to the Kubernetes production deployment.

### Port Map

| Port | Service | Type | Purpose |
|------|---------|------|---------|
| 30002 | Gateway | NodePort | Client API |
| 30003 | PostgreSQL | NodePort | Admin access |
| 30004 | RabbitMQ UI | NodePort | Queue management |
| 30005 | MongoDB | NodePort | Admin access |
| 30006 | Frontend | NodePort | Web interface |
| 30007 | Grafana | NodePort | Monitoring dashboard |
| 30008 | Alertmanager | NodePort | Alert management |

---

## Repository Structure

```
vidcast/
├── CLAUDE.md                         # THIS FILE
├── VIDCAST_UPGRADE_PLAN.md           # Detailed improvement plan
├── MEDIAFLOW_COMPARISON.md           # MediaFlow comparison analysis
├── README.md                         # Public-facing documentation
├── .gitignore                        # Comprehensive — secrets, state, artifacts
├── Jenkinsfile                       # Staging → Approval → Production pipeline
├── docker-compose.swarm.yml          # Docker Swarm staging environment
├── DEPLOYMENT_CONFIG.md              # GITIGNORED — your AWS + app configuration
├── DEPLOYMENT_HANDOVER.md            # GITIGNORED — session state
├── DEPLOYMENT_REPORT.md              # GITIGNORED — deployment timeline
│
├── .github/
│   └── workflows/
│       ├── ci.yml                    # Lint + Trivy + build + push
│       └── cd.yml                    # Deploy to EKS
│
├── terraform/
│   ├── environments/
│   │   └── dev/
│   │       ├── main.tf               # Root module
│   │       ├── variables.tf          # Inputs
│   │       ├── outputs.tf            # Cluster endpoint, node IP, kubeconfig cmd
│   │       ├── backend.tf            # S3 + DynamoDB state
│   │       └── terraform.tfvars      # GITIGNORED — actual values
│   └── modules/
│       ├── vpc/                      # VPC, 2 subnets, IGW, routes
│       ├── eks/                      # Cluster + node group + OIDC
│       ├── iam/                      # Cluster role, node role
│       └── security-groups/         # NodePort rules 30002-30008
│
├── Helm_charts/
│   ├── MongoDB/
│   ├── Postgres/
│   └── RabbitMQ/
│
├── src/
│   ├── auth-service/
│   ├── gateway-service/
│   ├── converter-service/
│   ├── notification-service/
│   └── frontend/                    # React web app
│       ├── Dockerfile
│       ├── nginx.conf
│       ├── package.json
│       ├── src/
│       └── manifest/
│
├── monitoring/
│   ├── values.yaml
│   ├── dashboards/
│   │   └── vidcast-operations.json
│   └── alerts/
│       └── vidcast-alerts.yaml
│
├── docs/
│   ├── architecture.md
│   ├── deployment-guide.md
│   └── presentation-notes.md
│
└── assets/
    └── video.mp4
```

---

## Configuration Values (from DEPLOYMENT_CONFIG.md)

Parse DEPLOYMENT_CONFIG.md before proceeding. Validate no bracket placeholders remain:
```bash
grep -n '\[.*\]' DEPLOYMENT_CONFIG.md
```

| Variable | Description |
|----------|-------------|
| YOUR_NAME | For deployment report |
| AWS_ACCOUNT_ID | Auto-detect: `aws sts get-caller-identity` |
| AWS_REGION | eu-west-2 (London) |
| CLUSTER_NAME | e.g., vidcast-cluster |
| NODE_INSTANCE_TYPE | m7i-flex.large (NEVER T-type — see constraints) |
| NODE_COUNT | 1 |
| VPC_ID | Leave blank to create new |
| DOCKER_HUB_USERNAME | Your Docker Hub username |
| APP_LOGIN_EMAIL | Login email for the app |
| APP_LOGIN_PASSWORD | App login password |
| GMAIL_ADDRESS | Gmail for sending notifications |
| GMAIL_APP_PASSWORD | 16-char app password (or SKIP) |
| MONGODB_USERNAME | MongoDB app user |
| MONGODB_PASSWORD | MongoDB password |
| POSTGRES_USERNAME | PostgreSQL username |
| POSTGRES_PASSWORD | PostgreSQL password |
| JWT_SECRET | Random 32+ char string |

---

## Customisation Checklist

After setting config values, update these files consistently:

### MongoDB Credentials (3 files must match)
- `Helm_charts/MongoDB/values.yaml` → username, password
- `src/gateway-service/manifest/configmap.yaml` → MONGODB_VIDEOS_URI, MONGODB_MP3S_URI
- `src/converter-service/manifest/configmap.yaml` → MONGODB_URI

### PostgreSQL Credentials (4 files must match)
- `Helm_charts/Postgres/values.yaml` → user, password, db
- `Helm_charts/Postgres/init.sql` → INSERT INTO auth_user
- `src/auth-service/manifest/secret.yaml` → PSQL_PASSWORD (base64)
- `src/auth-service/manifest/configmap.yaml` → DATABASE_USER

### JWT Secret, Gmail, Docker Images
- `src/auth-service/manifest/secret.yaml` → JWT_SECRET (base64)
- `src/notification-service/manifest/secret.yaml` → GMAIL_ADDRESS, GMAIL_PASSWORD (base64)
- All 4 deployment YAML files → image name

Generate and run `customise.sh` using sed to apply all substitutions atomically.
Validate: `grep -r "nasi\|sarcasm\|iambatmanthegoat" . --include="*.yaml" --include="*.sql"`

---

## Part 1 — Base Deployment Phases (Original Project)

These phases deploy the base application. If already complete, check DEPLOYMENT_HANDOVER.md and skip to Part 2.

```
Phase 0:  Prerequisites (tools + AWS credentials + repo)
Phase 1:  IAM roles (eks-cluster-role, eks-node-role)
Phase 2:  VPC and networking (CLI only — no console)
Phase 3:  EKS cluster + node group (~20 minutes)
Phase 4:  Security group rules (30002-30005)
Phase 5:  Customise files + apply bug fixes
Phase 6:  Helm deployments (MongoDB → PostgreSQL → RabbitMQ)
Phase 7:  PostgreSQL init (run init.sql)
Phase 8:  RabbitMQ queues (via HTTP Management API)
Phase 9:  Docker images (prebuilt or build+push)
Phase 10: Deploy microservices
Phase 11: End-to-end test
Phase 12: Deployment report
```

### Phase 1: IAM Roles
```bash
# Check before creating — skip if already exists
aws iam get-role --role-name eks-cluster-role 2>/dev/null || \
  aws iam create-role --role-name eks-cluster-role \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"eks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name eks-cluster-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

aws iam get-role --role-name eks-node-role 2>/dev/null || \
  aws iam create-role --role-name eks-node-role \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name eks-node-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
aws iam attach-role-policy --role-name eks-node-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
aws iam attach-role-policy --role-name eks-node-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
```
Save role ARNs to DEPLOYMENT_HANDOVER.md.

### Phase 2: VPC and Networking (only if VPC_ID blank)
```bash
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=vidcast-vpc}]' \
  --query Vpc.VpcId --output text)
IGW_ID=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
SUBNET_1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 \
  --availability-zone eu-west-2a --query Subnet.SubnetId --output text)
SUBNET_2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 \
  --availability-zone eu-west-2b --query Subnet.SubnetId --output text)
aws ec2 create-tags --resources $SUBNET_1 $SUBNET_2 \
  --tags Key=kubernetes.io/role/elb,Value=1
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_1 --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_2 --map-public-ip-on-launch
RTB=$(aws ec2 create-route-table --vpc-id $VPC_ID --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id $RTB --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $RTB --subnet-id $SUBNET_1
aws ec2 associate-route-table --route-table-id $RTB --subnet-id $SUBNET_2
```
Save all IDs to DEPLOYMENT_HANDOVER.md.

### Phase 3: EKS Cluster

⚠️ NEVER use T-type instances. Use m7i-flex.large or M/C/R-series only.

```bash
aws eks create-cluster --name vidcast-cluster --region eu-west-2 \
  --kubernetes-version 1.31 \
  --role-arn arn:aws:iam::ACCOUNT_ID:role/eks-cluster-role \
  --resources-vpc-config subnetIds=SUBNET_1,SUBNET_2,endpointPublicAccess=true

aws eks wait cluster-active --name vidcast-cluster --region eu-west-2
aws eks update-kubeconfig --name vidcast-cluster --region eu-west-2

aws eks create-nodegroup --cluster-name vidcast-cluster \
  --nodegroup-name vidcast-nodes \
  --node-role arn:aws:iam::ACCOUNT_ID:role/eks-node-role \
  --subnets SUBNET_1 SUBNET_2 \
  --instance-types m7i-flex.large \
  --scaling-config minSize=1,maxSize=2,desiredSize=1 \
  --ami-type AL2_x86_64 --region eu-west-2

aws eks wait nodegroup-active --cluster-name vidcast-cluster \
  --nodegroup-name vidcast-nodes --region eu-west-2

kubectl get nodes -o wide  # capture EXTERNAL-IP as NODE_IP
```

### Phase 4: Security Group Rules
```bash
NODE_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:kubernetes.io/cluster/vidcast-cluster,Values=owned" \
  --query "SecurityGroups[0].GroupId" --output text)
for PORT in 30002 30003 30004 30005 30006 30007 30008; do
  aws ec2 authorize-security-group-ingress \
    --group-id $NODE_SG --protocol tcp --port $PORT --cidr 0.0.0.0/0
done
```

### Phase 6: Helm Deployments
```bash
cd Helm_charts/MongoDB && helm install mongodb . && cd ../..
kubectl get pods -w  # wait for mongodb-0 Running
cd Helm_charts/Postgres && helm install postgres . && cd ../..
kubectl get pods -w  # wait for postgres Running
cd Helm_charts/RabbitMQ && helm install rabbitmq . && cd ../..
kubectl get pods -w  # wait for rabbitmq-0 Running
```

### Phase 7: PostgreSQL Init
```bash
PGPASSWORD=YOUR_POSTGRES_PASSWORD psql -h NODE_IP -p 30003 \
  -U YOUR_POSTGRES_USERNAME -d authdb -f Helm_charts/Postgres/init.sql
PGPASSWORD=YOUR_POSTGRES_PASSWORD psql -h NODE_IP -p 30003 \
  -U YOUR_POSTGRES_USERNAME -d authdb -c "SELECT * FROM auth_user;"
```

### Phase 8: RabbitMQ Queues (HTTP API — not browser)
```bash
curl -u guest:guest -X PUT http://NODE_IP:30004/api/queues/%2F/video \
  -H "Content-Type: application/json" -d '{"durable":true}'
curl -u guest:guest -X PUT http://NODE_IP:30004/api/queues/%2F/mp3 \
  -H "Content-Type: application/json" -d '{"durable":true}'
curl -s -u guest:guest http://NODE_IP:30004/api/queues | python3 -m json.tool | grep name
```

### Phase 10: Deploy Microservices
```bash
kubectl apply -f src/auth-service/manifest/
kubectl rollout status deployment/auth
kubectl apply -f src/gateway-service/manifest/
kubectl rollout status deployment/gateway
kubectl apply -f src/converter-service/manifest/
kubectl rollout status deployment/converter
kubectl apply -f src/notification-service/manifest/
kubectl rollout status deployment/notification
kubectl get pods  # all should be Running
```

### Phase 11: End-to-End Test
```bash
# Login
JWT=$(curl -s -X POST http://NODE_IP:30002/login -u "EMAIL:PASSWORD")
echo "JWT: $JWT"

# Upload
curl -X POST http://NODE_IP:30002/upload \
  -F "file=@assets/video.mp4" -H "Authorization: Bearer $JWT"

# Monitor queues
sleep 5
curl -s -u guest:guest http://NODE_IP:30004/api/queues/%2F/video \
  | python3 -m json.tool | grep messages

# Download (use FILE_ID from email)
curl -X GET "http://NODE_IP:30002/download?fid=FILE_ID" \
  -H "Authorization: Bearer $JWT" -o output.mp3
```

---

## Part 2 — Upgrade Phases

These phases transform the base project into a production-grade platform.

```
Phase U0: Repo cleanup + .gitignore
Phase U1: Terraform IaC (VPC, IAM, EKS, SGs)
Phase U2: CI/CD Pipeline
          [FULL ONLY]: Claude generates ci.yml, cd.yml, Jenkinsfile
          [HYBRID ONLY]: Claude generates docker-compose.swarm.yml only
                         Developer manually writes ci.yml, cd.yml, Jenkinsfile
Phase U3: Security Hardening
          [FULL ONLY]: Claude adds probes, limits, security contexts, health endpoints
          [HYBRID ONLY]: Developer writes all security hardening manually
Phase U4: Monitoring Stack (Prometheus + Grafana + Alertmanager)
Phase U5: Frontend Application (React)
Phase U6: Documentation
```

### Phase U2: CI/CD Pipeline

**GitHub Actions ci.yml — all modes:**

Matrix strategy running lint + Trivy scan + build + push for all four services in parallel:
- Matrix: `service: [auth-service, gateway-service, converter-service, notification-service]`
- Lint: ruff check
- Build: docker build tagged with SHORT_SHA (`${GITHUB_SHA::7}`)
- Scan: aquasecurity/trivy-action with CRITICAL,HIGH severity, exit-code 1, ignore-unfixed
- Push: docker/login-action + docker push (main branch only)

**GitHub Actions cd.yml — all modes:**

Trigger: `workflow_run` on CI completion (main branch). Uses `aws-actions/configure-aws-credentials@v4`, then `aws eks update-kubeconfig`, then `kubectl set image` + `kubectl rollout status` for each service.

**Jenkinsfile — key stages (all modes):**

```
Stage 1: Lint (ruff)
Stage 2: Build Images (parallel — all 4 services)
Stage 3: Security Scan (Trivy — all 4 images)
Stage 4: Push Images (Docker Hub)
Stage 5: Deploy Staging → docker stack deploy to Swarm EC2
Stage 6: Smoke Test → curl -f http://${STAGING_IP}:8080/healthz || exit 1
Stage 7: Approve Production → input message: 'Deploy to Production?'
Stage 8: Deploy Production → kubectl set image + kubectl rollout status
post { failure { kubectl rollout undo all services } }
```

**docker-compose.swarm.yml:** All 7 services with overlay networking, named volumes for MongoDB and PostgreSQL, failure_action: rollback on all services, restart_policy: on-failure max 3.

**[HYBRID ONLY]:** Developer builds ci.yml, cd.yml, and Jenkinsfile manually. See HYBRID_IMPLEMENTATION_GUIDE_V2.md for step-by-step instructions.

### Phase U3: Security Hardening

**Health endpoints:**
- `src/auth-service/server.py`: add Flask `/healthz` route testing PostgreSQL connectivity
- `src/gateway-service/server.py`: add `/healthz` testing MongoDB + RabbitMQ. Add flask-cors to requirements.txt and `CORS(server)` after app creation
- `src/converter-service/consumer.py`: in main loop, `pathlib.Path("/tmp/healthy").touch()` after processing
- `src/notification-service/consumer.py`: same touch file pattern

**Deployment manifests — all four services:**

Probes (auth/gateway — HTTP, converter/notification — exec):
```yaml
livenessProbe:
  httpGet: {path: /healthz, port: PORT}
  initialDelaySeconds: 15
  periodSeconds: 10
  failureThreshold: 3
readinessProbe:
  httpGet: {path: /healthz, port: PORT}
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 3
```

Resources:
```
Auth:         cpu 50m/200m    mem 64Mi/128Mi
Gateway:      cpu 100m/300m   mem 128Mi/256Mi
Converter:    cpu 250m/500m   mem 256Mi/512Mi
Notification: cpu 50m/100m    mem 64Mi/128Mi
```

Security context (all pods):
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
```

Converter and notification: add writable emptyDir volume at /tmp.

**[HYBRID ONLY]:** Developer writes all security hardening manually. See HYBRID_IMPLEMENTATION_GUIDE_V2.md.

### Phase U4: Monitoring Stack

Install via Helm: `helm install monitoring prometheus-community/kube-prometheus-stack -f monitoring/values.yaml -n monitoring`

Key config: Grafana NodePort 30007 (password: vidcast-demo), Alertmanager 30008, 7d retention, 10Gi storage. Disable etcd/scheduler/controller-manager (EKS manages these).

Custom dashboard "VidCast Operations": pod status, restarts, node CPU/memory, queue depth.
Alert rules: PodCrashLoopBackOff (critical), HighNodeMemory >85% (warning), HighNodeCPU >85% (warning).

### Phase U5: Frontend

React + Vite + Tailwind CSS. Pages: Login, Upload, Download, Dashboard (Grafana iframe), Architecture (animated diagram). Nginx multi-stage Dockerfile, runs as non-root on port 8080. NodePort 30006.

---

## Known Issues and Applied Fixes

| # | Severity | Issue | Fix |
|---|----------|-------|-----|
| 1 | High | NameError in gateway-service/server.py — unauth_count.inc() | Remove lines 36 and 60 |
| 2 | High | JWT secret was "sarcasm" | Replace with 32+ char random string |
| 3 | High | Plaintext passwords in PostgreSQL | Document — acceptable for learning |
| 4 | High | Credentials in source YAML | .gitignore for secret.yaml files |
| 5 | Low | ffmpeg in notification Dockerfile | Remove if rebuilding images |
| 6 | Medium | No liveness/readiness probes | Fixed in Phase U3 |
| 7 | Medium | No resource limits | Fixed in Phase U3 |
| 8 | Medium | PostgreSQL has no PersistentVolume | Acceptable — use RDS in production |
| 9 | Low | prometheus-client unused in gateway | Remove if rebuilding |

---

## AWS Account Constraints

- **NEVER use T-type instances.** SCPs reject `CreditSpecification: unlimited` which EKS auto-generates for T-type. Every attempt fails after a long wait.
- **Working instance type:** m7i-flex.large (2 vCPU, 8 GB)
- **Region:** eu-west-2 (London)
- This constraint is already encoded as a validation block in the Terraform eks module.

---

## Error Handling Rules

1. Never silently continue past a non-zero exit code — stop, report, diagnose
2. Show every command before running it
3. Pod in CrashLoopBackOff → immediately `kubectl logs` and `kubectl describe pod`, fix before continuing
4. Never delete AWS resources without explicit user confirmation
5. Update DEPLOYMENT_HANDOVER.md AND DEPLOYMENT_REPORT.md after every phase
6. If GMAIL_APP_PASSWORD is SKIP, skip Gmail configuration — user checks queues manually
7. If usage limits are approaching, update both tracking files immediately before stopping

---

## Cleanup and Destroy

```bash
# Helm
helm uninstall mongodb postgres rabbitmq
helm uninstall monitoring -n monitoring

# Kubernetes
kubectl delete -f src/auth-service/manifest/
kubectl delete -f src/gateway-service/manifest/
kubectl delete -f src/converter-service/manifest/
kubectl delete -f src/notification-service/manifest/
kubectl delete -f src/frontend/manifest/

# EKS
aws eks delete-nodegroup --cluster-name vidcast-cluster \
  --nodegroup-name vidcast-nodes --region eu-west-2
aws eks wait nodegroup-deleted --cluster-name vidcast-cluster \
  --nodegroup-name vidcast-nodes --region eu-west-2
aws eks delete-cluster --name vidcast-cluster --region eu-west-2

# Terraform (if used)
cd terraform/environments/dev && terraform destroy

# VPC (if created manually — use IDs from DEPLOYMENT_HANDOVER.md)
aws ec2 delete-route-table --route-table-id RTB_ID
aws ec2 detach-internet-gateway --internet-gateway-id IGW_ID --vpc-id VPC_ID
aws ec2 delete-internet-gateway --internet-gateway-id IGW_ID
aws ec2 delete-subnet --subnet-id SUBNET_1_ID
aws ec2 delete-subnet --subnet-id SUBNET_2_ID
aws ec2 delete-vpc --vpc-id VPC_ID
```
