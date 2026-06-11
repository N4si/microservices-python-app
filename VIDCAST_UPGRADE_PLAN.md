# VidCast — Production Upgrade Plan

**Project:** Video-to-Audio Microservices Platform on AWS EKS
**Product Name:** VidCast — "Turn video recordings into podcast-ready audio"
**Date:** May 2026
**Status:** Base platform deployed and passing end-to-end tests. This document covers planned improvements.

---

## How to Read This Document

This document is for the team. It explains every improvement we plan to make, why it matters, what it costs (in time and money), and what the alternatives were. If you're picking up a phase to work on, read the relevant section fully before writing any code. If something isn't clear, ask — don't guess.

Every improvement falls into one of three categories:

- **Build It** — We will implement this. It goes into the repo and the demo.
- **Talk About It** — We understand this and can explain it in the presentation, but we're not implementing it.
- **Skip It** — Not relevant for this project at this stage.

---

## Table of Contents

1. [Current State — What We Have](#1-current-state--what-we-have)
2. [Product Concept — VidCast](#2-product-concept--vidcast)
3. [Phase 1 — Terraform Infrastructure as Code](#3-phase-1--terraform-infrastructure-as-code)
4. [Phase 2 — CI/CD Pipeline](#4-phase-2--cicd-pipeline)
5. [Phase 3 — Security Hardening](#5-phase-3--security-hardening)
6. [Phase 4 — Monitoring and Observability](#6-phase-4--monitoring-and-observability)
7. [Phase 5 — Frontend Web Application](#7-phase-5--frontend-web-application)
8. [Phase 6 — Documentation and Presentation](#8-phase-6--documentation-and-presentation)
9. [Things We Talk About But Don't Build](#9-things-we-talk-about-but-dont-build)
10. [Repository Structure](#10-repository-structure)
11. [Branch Strategy](#11-branch-strategy)
12. [Cost Breakdown](#12-cost-breakdown)
13. [Real-World Use Cases](#13-real-world-use-cases)
14. [Presentation Strategy](#14-presentation-strategy)

---

## 1. Current State — What We Have

The base platform is deployed on AWS EKS in eu-west-2. It consists of four Python microservices (auth, gateway, converter, notification) and three infrastructure services (MongoDB, PostgreSQL, RabbitMQ) deployed via Helm charts. The application accepts video uploads via HTTP, converts them to MP3 asynchronously using RabbitMQ as a message broker, and emails the user when the audio file is ready for download.

What works: end-to-end flow (login, upload, convert, notify, download), JWT authentication, event-driven async processing, Helm-managed infrastructure services, multi-replica deployments.

What's missing: no infrastructure as code (cluster built manually via console), no CI/CD pipeline (images built and deployed manually), no health checks or resource limits on pods, no monitoring or alerting, credentials stored in plaintext YAML committed to the repo, no web interface (API-only via curl), no documentation beyond the deployment guide.

These gaps are normal for a first-pass learning project. The purpose of this upgrade plan is to close them systematically.

---

## 2. Product Concept — VidCast

Instead of presenting this as "a Kubernetes exercise," we're framing it as a product that solves a real problem. This makes the demo accessible to non-technical audiences and gives the architecture a business context.

**The product story:** Content creators record video — Zoom interviews, webinars, conference talks. They need the audio as a standalone podcast episode. VidCast lets them upload the video, converts it automatically, and emails them when the MP3 is ready to download.

**Why this framing matters:** Every architectural decision now has a business justification. "Why do we use a message queue?" becomes "Because the creator shouldn't have to wait 5 minutes staring at a loading screen — they upload and walk away." "Why do we have 4 converter replicas?" becomes "Because if 20 creators upload at once, we need parallel processing capacity."

**Why not YouTube downloads:** Downloading from YouTube violates their Terms of Service, yt-dlp breaks regularly as YouTube fights it, and a failed download during a live demo would derail the presentation. Our demo uses locally-stored video files that we control.

---

## 3. Phase 1 — Terraform Infrastructure as Code

### What We're Building

Terraform modules that create and manage all AWS infrastructure: VPC, subnets, internet gateway, route tables, security groups, IAM roles, EKS cluster, and managed node group. After this phase, the entire platform can be destroyed and recreated from a single `terraform apply` command.

### Why This Matters

Right now, if someone deletes the EKS cluster, we'd need to click through the AWS Console for 30-60 minutes to rebuild it, hoping we remember every setting. With Terraform, the infrastructure is version-controlled, reviewable, and repeatable. This is the single most impactful improvement for the CV and the demo.

In industry, this is non-negotiable. Every company running cloud infrastructure uses some form of IaC — Terraform, CloudFormation, Pulumi, or CDK. "I can destroy and recreate this entire platform from scratch with one command" is a sentence that separates you from most bootcamp graduates.

### What the Industry Calls This

Infrastructure as Code (IaC). The practice comes from the DevOps principle that infrastructure should be treated like application code: version-controlled, peer-reviewed, tested, and reproducible. The term was popularised by tools like Chef and Puppet in the 2010s, and Terraform (by HashiCorp, now part of IBM) became the dominant multi-cloud IaC tool.

### Trade-off Analysis

| Dimension | Terraform (Chosen) | AWS CloudFormation | Pulumi |
|---|---|---|---|
| Multi-cloud support | Yes — works with AWS, Azure, GCP | AWS only | Yes |
| Language | HCL (domain-specific) | JSON/YAML | Python, TypeScript, Go |
| Industry adoption | Dominant in multi-cloud shops | Dominant in AWS-only shops | Growing but smaller |
| Learning curve | Moderate — HCL is readable | Low for simple stacks | Low if you know the language |
| State management | Remote state in S3 + DynamoDB lock | Managed by AWS automatically | Managed by Pulumi Cloud or self-hosted |
| Bootcamp relevance | Taught in most DevOps curricula | Less commonly taught | Rarely taught in bootcamps |

**Why Terraform:** It's what we learned, it's what most job postings list, and it works across cloud providers. CloudFormation would also be fine for an AWS-only project, but Terraform demonstrates a transferable skill.

### What We're Creating

```
terraform/
├── environments/
│   └── dev/
│       ├── main.tf           # Root module — calls all child modules
│       ├── variables.tf      # Input variables (region, instance type, etc.)
│       ├── outputs.tf        # Cluster endpoint, node IP, kubeconfig command
│       └── terraform.tfvars  # Actual values (gitignored — never committed)
└── modules/
    ├── vpc/                  # VPC, subnets, IGW, route tables, NAT
    ├── eks/                  # EKS cluster, node group, OIDC provider
    ├── iam/                  # Cluster role, node role, policies
    └── security-groups/      # NodePort rules (30002-30005)
```

### Key Decisions

**Remote state in S3 with DynamoDB locking.** Local state files are not acceptable for any shared project. If two people run `terraform apply` simultaneously with local state, one of them will corrupt the infrastructure. S3 stores the state file, and DynamoDB prevents concurrent modifications. This is standard practice.

**Module structure instead of a single flat file.** Each concern (networking, compute, identity) is a separate module with its own inputs and outputs. This means one person can modify the security groups without touching the VPC configuration. It also means modules can be reused across environments (dev, staging, prod) with different variable values.

**terraform.tfvars is gitignored.** This file contains the actual values for your deployment — AWS account ID, region, instance type. It's environment-specific and must never be committed to the repo. Each team member creates their own from a template.

### Estimated Effort

4-6 hours to write and test all modules. Most of the time is in the EKS module (cluster creation takes 15 minutes per attempt, so iteration is slow).

---

## 4. Phase 2 — CI/CD Pipeline

### What We're Building

A GitHub Actions workflow that automatically lints, scans, builds, and deploys the application whenever code is pushed. A Jenkinsfile that achieves the same pipeline for teams using Jenkins.

### Why This Matters

Right now, deploying a code change means: manually build a Docker image on your laptop, manually push it to Docker Hub, manually run `kubectl apply` against the cluster, and hope you didn't forget a step. This is error-prone, unreviewable, and unauditable. Nobody knows who deployed what, when, or from which commit.

A CI/CD pipeline enforces a consistent process: every change goes through the same steps, every deployment is traceable to a specific commit, and security scanning happens automatically before any image reaches the cluster.

### What the Industry Calls This

Continuous Integration (CI) — automatically building and testing every change. Continuous Delivery/Deployment (CD) — automatically deploying validated changes to environments. Together, CI/CD. The practice originated in the early 2000s with tools like CruiseControl and Hudson (which became Jenkins). Modern implementations use GitHub Actions, GitLab CI, CircleCI, or Jenkins.

### Trade-off Analysis

| Dimension | GitHub Actions (Chosen) | Jenkins | GitLab CI |
|---|---|---|---|
| Infrastructure cost | Free for public repos, generous free tier | Must host and maintain Jenkins server | Free for public repos |
| Setup complexity | Zero — lives in the repo | High — needs a server, plugins, configuration | Low if using GitLab.com |
| Plugin ecosystem | Growing (Actions marketplace) | Massive (1800+ plugins) | Built-in features |
| Enterprise adoption | High and growing | Very high (legacy and current) | High in European companies |
| Pipeline as code | YAML in .github/workflows/ | Jenkinsfile in repo root | .gitlab-ci.yml in repo root |
| Demo-ability | Excellent — visible in GitHub UI | Requires Jenkins server running | Requires GitLab instance |

**Why both:** GitHub Actions for the actual pipeline (easy to demo, no infrastructure needed). Jenkinsfile in the repo to show we can work in enterprise environments. During the presentation, we show GitHub Actions running; we mention Jenkins as "the enterprise alternative I also wrote."

### Pipeline Stages

```
Push to any branch
    │
    ├── Lint (ruff for Python)
    ├── Trivy Scan (container vulnerability scanning)
    │
    └── If main branch:
        ├── Build Docker Image
        ├── Tag with Git SHA (never :latest)
        ├── Push to Docker Hub
        ├── Configure kubectl for EKS
        └── Deploy to cluster (kubectl apply or helm upgrade)
```

### Security Scanning — Where Trivy Fits

Trivy is an open-source vulnerability scanner by Aqua Security. It scans container images for known CVEs (Common Vulnerabilities and Exposures) in OS packages and application dependencies. In our pipeline, Trivy runs after the Docker image is built but before it's pushed to the registry. If Trivy finds a CRITICAL or HIGH severity CVE, the pipeline fails and the image never reaches the cluster.

This is the same concept as Docker Content Trust from Docker Swarm — ensuring that only verified, safe images run in your cluster. Trivy is the scanning step; Docker Content Trust (or Cosign/Sigstore in Kubernetes) is the signing step. We implement scanning; we talk about signing.

In industry, this is called "shift-left security" — catching security issues early in the development process rather than discovering them in production. Most companies run Trivy, Snyk, or Grype as a CI pipeline gate.

### Jenkins Pipeline

The Jenkinsfile mirrors the GitHub Actions workflow exactly. Same stages, same tools, different syntax. This demonstrates that the pipeline logic is tool-agnostic — the stages (lint, scan, build, push, deploy) are the same regardless of whether you're using GitHub Actions, Jenkins, GitLab CI, or CircleCI.

```groovy
// Jenkinsfile — same pipeline, different syntax
pipeline {
    agent any
    stages {
        stage('Lint')    { steps { sh 'ruff check src/' } }
        stage('Scan')    { steps { sh 'trivy image ...' } }
        stage('Build')   { steps { sh 'docker build ...' } }
        stage('Push')    { steps { sh 'docker push ...' } }
        stage('Deploy')  { steps { sh 'kubectl apply ...' } }
    }
}
```

### Estimated Effort

3-4 hours. The workflow files are straightforward; most time goes into configuring GitHub Secrets (Docker Hub credentials, AWS credentials, kubeconfig) and testing the pipeline end-to-end.

---

## 5. Phase 3 — Security Hardening

### What We're Building

Four categories of security improvements applied to every Kubernetes deployment manifest.

### 5a. Liveness and Readiness Probes

**What they are:** Health checks that Kubernetes runs continuously to determine if a pod is alive (liveness) and ready to receive traffic (readiness). If a liveness probe fails, Kubernetes restarts the pod. If a readiness probe fails, Kubernetes stops sending traffic to that pod but doesn't restart it.

**Why they matter:** Right now, Kubernetes has no way to know if our pods are actually healthy. It only knows they're running. If the Gateway loses its RabbitMQ connection, Kubernetes keeps routing traffic to it, and every upload silently fails. With probes, Kubernetes detects the failure and either restarts the pod or routes traffic to a healthy replica.

**Where this concept comes from:** Health checks are a core Kubernetes primitive, inspired by process monitoring in traditional infrastructure (like systemd watchdog timers or Nagios checks). The distinction between liveness and readiness was introduced by Kubernetes to handle the common case where a service is alive but temporarily unable to serve (e.g., during startup or when a dependency is down).

**What we're adding:**

| Service | Probe Type | Check Method | What It Checks |
|---|---|---|---|
| Auth | HTTP GET /healthz | Liveness + Readiness | Flask is responding, PostgreSQL is reachable |
| Gateway | HTTP GET /healthz | Liveness + Readiness | Flask is responding, MongoDB and RabbitMQ are reachable |
| Converter | Exec command | Liveness | Process is alive, RabbitMQ connection is active |
| Notification | Exec command | Liveness | Process is alive, RabbitMQ connection is active |

This requires adding a small `/healthz` endpoint to the Flask services (auth and gateway) — about 10 lines of Python each.

### 5b. Resource Requests and Limits

**What they are:** CPU and memory boundaries set on each pod. Requests are the guaranteed minimum — Kubernetes uses these for scheduling decisions. Limits are the hard ceiling — if a pod exceeds its memory limit, it gets killed (OOMKilled).

**Why they matter:** The converter service runs ffmpeg, which is CPU-intensive. Without limits, four converter replicas could consume all 2 vCPUs on our m7i-flex.large node, starving the gateway and auth services. Users would be able to upload files but never log in, because the auth service can't get CPU time to process JWT validation.

**What we're setting:**

| Service | CPU Request | CPU Limit | Memory Request | Memory Limit | Rationale |
|---|---|---|---|---|---|
| Auth | 50m | 200m | 64Mi | 128Mi | Lightweight Flask app, small queries |
| Gateway | 100m | 300m | 128Mi | 256Mi | HTTP handling + GridFS uploads |
| Converter | 250m | 500m | 256Mi | 512Mi | ffmpeg is CPU and memory hungry |
| Notification | 50m | 100m | 64Mi | 128Mi | Sends emails — minimal resources |

Total request across all replicas: approximately 1.5 vCPU and 1.5GB RAM, which fits comfortably on a 2 vCPU / 8GB node.

### 5c. Security Contexts (Runtime Hardening)

**What they are:** Linux-level security constraints applied to the container process. This is the direct Kubernetes equivalent of the Docker Swarm runtime hardening we learned in class.

**Where this concept comes from:** The principle of least privilege — a container should have only the permissions it needs to do its job, nothing more. In Docker Swarm, we configured this through service spec options. In Kubernetes, the same concepts exist in the `securityContext` block of the pod spec.

**What we're adding to every pod:**

```yaml
securityContext:
  runAsNonRoot: true          # Container cannot run as root user
  runAsUser: 1000             # Run as a non-privileged user
  readOnlyRootFilesystem: true # Filesystem is read-only (prevents malware writing to disk)
  allowPrivilegeEscalation: false  # Cannot gain more privileges than it started with
  capabilities:
    drop: ["ALL"]             # Drop all Linux capabilities (network raw, sys admin, etc.)
```

**Special case — Converter service:** The converter needs to write temporary files (the video input and MP3 output during conversion). We set `readOnlyRootFilesystem: true` but mount a writable `emptyDir` volume at `/tmp`. This means the converter can write temp files but cannot modify its own binaries, configuration, or any other part of the filesystem. If an attacker compromises the converter, they can write to /tmp but cannot install tools, modify the application, or persist across pod restarts.

**Mapping from Docker Swarm to Kubernetes:**

| Swarm Concept | Kubernetes Equivalent |
|---|---|
| `--user` flag | `securityContext.runAsUser` |
| `--read-only` flag | `securityContext.readOnlyRootFilesystem` |
| `--cap-drop ALL` | `securityContext.capabilities.drop: ["ALL"]` |
| `--no-new-privileges` | `securityContext.allowPrivilegeEscalation: false` |
| mTLS between services | Requires a service mesh (Istio/Linkerd) — Talk About It, don't build |
| Rotating join tokens | Managed by EKS automatically — Talk About It |
| Certificate management | ACM for external certs, EKS manages internal — Talk About It |

### 5d. .gitignore and Secrets Audit

**What we're adding:** A comprehensive .gitignore that prevents credentials, state files, and generated artifacts from being committed. We're also auditing every file in the repo for hardcoded secrets and documenting which files contain sensitive values.

**Files that must never be committed:**

```
# Terraform
terraform.tfvars
*.tfstate
*.tfstate.backup
.terraform/

# Kubernetes secrets (generated by customise.sh)
**/secret.yaml

# Credentials and state
deployment-ids.txt
DEPLOYMENT_CONFIG.md
DEPLOYMENT_GUIDE.md
customise.sh

# Build artifacts
*.mp3
*.mp4
node_modules/
__pycache__/
.env
```

### Estimated Effort

2-3 hours for all four categories. Most of the work is YAML editing and adding small health endpoints to the Python services.

---

## 6. Phase 4 — Monitoring and Observability

### What We're Building

A Prometheus + Grafana + Alertmanager monitoring stack deployed via the kube-prometheus-stack Helm chart, with one custom Grafana dashboard for the demo.

### Why This Matters

Right now, if the converter pods crash, if RabbitMQ fills up, if MongoDB runs out of disk — nobody knows until a user complains (or, more likely, until we notice during a demo that nothing is working). In industry, this is unacceptable for anything beyond a personal experiment.

Monitoring answers three questions: Is the system healthy right now? Was it healthy over the past hour/day/week? When did it stop being healthy, and what changed?

### What the Industry Calls This

Observability — the ability to understand the internal state of a system by examining its outputs. The "three pillars of observability" are metrics (numerical measurements over time), logs (structured event records), and traces (request paths across services). We're implementing metrics and dashboards. We'll discuss logs and traces in the presentation.

### Trade-off Analysis

| Dimension | kube-prometheus-stack (Chosen) | AWS CloudWatch | Datadog |
|---|---|---|---|
| Cost | Free (self-hosted) | Pay per metric/log/alarm | $15-23/host/month |
| Setup complexity | One Helm install | Requires CloudWatch agent, IAM roles | Agent install + SaaS config |
| Kubernetes integration | Native — built for K8s | Good but requires extra config | Excellent |
| Dashboard quality | Grafana — highly customisable | Basic but functional | Excellent out of the box |
| Industry relevance | Prometheus is the CNCF standard | Common in AWS-heavy shops | Common in well-funded startups |
| Demo impact | High — Grafana looks impressive | Medium | High but costs money |

**Why kube-prometheus-stack:** One Helm install gives us Prometheus (metrics collection), Grafana (dashboards), Alertmanager (alerts), kube-state-metrics (Kubernetes object metrics), and node-exporter (host-level metrics). It's free, it's the CNCF standard, and Grafana dashboards look professional in a demo.

### What We Get

**Out of the box (no extra configuration):** CPU and memory usage per pod, per node, and cluster-wide. Pod restart counts and crash loop detection. Network I/O. Disk usage. Kubernetes object status (deployments, statefulsets, pods).

**Custom dashboard for the demo ("VidCast Operations"):** RabbitMQ queue depth (video queue and mp3 queue) — this is the most compelling visual during a demo. Pod status for all four microservices. Node resource utilisation. Converter processing rate (if we add custom metrics to the Python code).

**Alerts:**

| Alert | Condition | Severity | Why |
|---|---|---|---|
| Pod CrashLoopBackOff | Pod restarted 3+ times in 10 minutes | Critical | Service is broken |
| High Node Memory | Node memory > 85% for 5 minutes | Warning | Risk of OOMKill |
| RabbitMQ Queue Backlog | Video queue depth > 10 for 5 minutes | Warning | Conversions are backing up |
| RabbitMQ Unavailable | RabbitMQ pod not ready for 2 minutes | Critical | Entire pipeline is blocked |

### Estimated Effort

3-4 hours. The Helm install takes 5 minutes; building a good custom dashboard takes iteration.

---

## 7. Phase 5 — Frontend Web Application

### What We're Building

A React web application that serves as the VidCast product interface. It communicates with the existing Gateway API and provides a visual way to interact with the platform during the demo.

### Why This Matters

Right now, the demo involves running curl commands in a terminal. This is fine for a technical audience, but for a bootcamp presentation where we need to explain the system to non-technical people, a visual interface makes the flow immediately understandable. The frontend also gives us a place to show the monitoring dashboard and the architecture diagram during the presentation.

### Pages

**Login Page:** Email and password form. Calls `/login` on the Gateway, stores the JWT in React state (not localStorage — that's not supported in artifacts/sandboxed environments, and it's a security consideration worth mentioning). Clean VidCast branding.

**Upload Page:** Drag-and-drop file upload. Sends the video to `/upload` with the JWT. Shows a success confirmation: "Your file is being processed. You'll receive an email when it's ready."

**Download Page:** Text input for the file ID (from the email notification). Calls `/download` with the JWT and file ID. Triggers a browser download of the MP3.

**Dashboard Page:** Embedded Grafana panels showing RabbitMQ queue depth and pod health, or a simplified custom view. This is the "behind the scenes" view for the presentation.

**Architecture Page:** An interactive system diagram showing the microservices and data flow. During the demo, this helps explain what happens when you upload a file — "the request hits the Gateway here, then the video goes into the queue here, then a converter worker picks it up here..."

### Deployment

The frontend gets its own Dockerfile (Node.js, nginx to serve the built React app), its own Kubernetes Deployment and Service (NodePort or Ingress), and its own entry in the CI/CD pipeline. It becomes the fifth microservice in the cluster.

### Trade-off Analysis

| Dimension | React SPA (Chosen) | Plain HTML/CSS/JS | Next.js |
|---|---|---|---|
| Complexity | Moderate | Low | High |
| State management | React hooks (useState) | Manual DOM manipulation | React + SSR complexity |
| Component reuse | Excellent | Poor | Excellent |
| Build step required | Yes (npm build) | No | Yes |
| Team familiarity | Depends | Everyone knows HTML | Fewer people know Next.js |
| Demo appearance | Professional | Can look professional | Professional |

**Why React:** Component-based architecture makes the dashboard and architecture views easier to build. Tailwind CSS keeps styling consistent without custom CSS. The built app is served as static files by nginx, so it's lightweight and fast.

### Estimated Effort

6-8 hours. This is the most visible piece but not the most complex — the backend already works, so the frontend is mostly API calls and UI design.

---

## 8. Phase 6 — Documentation and Presentation

### What We're Producing

An updated README.md that explains the project from the perspective of someone finding it on GitHub — what it does, how to deploy it, how to destroy it. Architecture diagrams. Presentation notes with talking points and analogies for non-technical audiences.

### Analogies for Non-Technical Audiences

**Microservices → Restaurant:** A monolith is one chef doing everything. Microservices are specialised roles: host, cook, runner, cashier. Each can be scaled independently.

**Message Queue → Post Office:** You don't wait at the counter for your letter to be delivered. You drop it off, and the postal workers process it on their own schedule.

**JWT Authentication → Security Badge:** You show your ID at reception once (login), get a badge (token), and swipe it for access to different rooms (upload, download) without going back to reception.

**Containers → Shipping Containers:** Standardised boxes that work the same everywhere — your laptop, a data centre, the cloud.

**Kubernetes → Port Authority:** Manages where containers go, replaces ones that fall off the ship, and adds more when demand increases.

**Infrastructure as Code → Building Blueprints:** Instead of telling builders "make it like the last one," you hand them exact blueprints. Anyone can build the same building from the same plans.

**CI/CD Pipeline → Factory Assembly Line:** Raw materials (code) go in one end, pass through quality checks, and a finished product (deployed application) comes out the other end. Every step is automated and inspected.

---

## 9. Things We Talk About But Don't Build

These are concepts we understand and can discuss in the presentation or interviews, but we're not implementing them in this project. For each one, the reason for not building it is included.

### ArgoCD / GitOps

**What it is:** A deployment model where Git is the single source of truth. Instead of running `kubectl apply` from a pipeline, ArgoCD watches the Git repo and automatically syncs the cluster state to match what's in Git. If someone manually changes something in the cluster, ArgoCD detects the drift and reverts it.

**Why we're not building it:** ArgoCD adds significant operational complexity (it needs its own deployment, RBAC, and repository credentials). For a single-developer project, the CI/CD pipeline with `kubectl apply` achieves the same outcome. ArgoCD shines in multi-team environments where drift detection and audit trails matter.

**What to say in an interview:** "For a single-developer project, I used direct deployment from the CI/CD pipeline. In a team environment, I'd introduce ArgoCD for drift detection and to enforce that all changes go through Git."

### KEDA / Queue-Based Autoscaling

**What it is:** Kubernetes Event-Driven Autoscaling. Instead of scaling based on CPU (which HPA does), KEDA scales based on external metrics — in our case, RabbitMQ queue depth. If 50 videos are in the queue, KEDA would scale the converter from 4 replicas to 20. When the queue drains, it scales back down.

**Why we're not building it:** Our demo processes one video at a time. KEDA is impressive but meaningless without a load-testing scenario to demonstrate it. Implementing it without a visible demo adds complexity without presentation value.

**What to say in an interview:** "The converter service would benefit from queue-based autoscaling with KEDA. Instead of a fixed 4 replicas, KEDA would watch the RabbitMQ queue depth and scale converter workers dynamically. This means we pay for compute only when there's work to do."

### Service Mesh / mTLS

**What it is:** A service mesh (Istio, Linkerd) adds a sidecar proxy to every pod that handles service-to-service communication. This enables mutual TLS (mTLS) — every connection between services is encrypted and both sides verify each other's identity. In Docker Swarm, mTLS is built in. In Kubernetes, it requires a service mesh.

**Why we're not building it:** Installing Istio would triple the resource consumption on our single node and add significant operational complexity. For a four-service demo with no sensitive data, it's overkill.

**What to say in an interview:** "In production, I'd add a service mesh like Istio or Linkerd for mTLS between services. Even if an attacker gets inside the cluster network, they can't intercept or modify traffic between the gateway and auth service. The same encryption that Docker Swarm provides built-in requires a service mesh in Kubernetes."

### Managed Database Services (RDS, DocumentDB, Amazon MQ)

**What it is:** Instead of running MongoDB, PostgreSQL, and RabbitMQ as containers in the cluster, use AWS managed services: RDS for PostgreSQL, DocumentDB or MongoDB Atlas for MongoDB, and Amazon MQ for RabbitMQ. AWS handles backups, patching, replication, and failover.

**Why we're not building it:** Managed services cost $200-400/month for a project we run for demos. They also remove the Kubernetes operational experience (running StatefulSets, Helm charts) that makes the project valuable. The in-cluster approach demonstrates more skills.

**What to say in an interview:** "In production, I'd migrate PostgreSQL to RDS and RabbitMQ to Amazon MQ. Managed services handle backups, patching, and replication — operational burden the platform team shouldn't own. I kept them as StatefulSets in this project to demonstrate Kubernetes data service management."

### External Secrets Operator / AWS Secrets Manager

**What it is:** Instead of storing secrets in Kubernetes Secret objects (which are just base64-encoded, not encrypted), store them in AWS Secrets Manager and use the External Secrets Operator to sync them into the cluster at runtime.

**Why we might not build it:** It requires an OIDC provider configured on the EKS cluster and IRSA (IAM Roles for Service Accounts). This is achievable but adds 2-3 hours of work. If time permits, we'll add it. If not, we document the approach and explain it.

**What to say in an interview:** "Credentials are currently in Kubernetes Secrets, which are base64-encoded but not encrypted at rest unless you enable EKS envelope encryption. In production, I'd use AWS Secrets Manager with the External Secrets Operator. Secrets are stored in Secrets Manager, retrieved at runtime via IRSA, and never exist in Git."

### Network Policies

**What it is:** Kubernetes NetworkPolicy resources that restrict which pods can communicate with each other. By default, every pod in a Kubernetes cluster can talk to every other pod. Network Policies implement the principle of least privilege at the network level.

**Why we should try to build it (stretch goal):** It's a 20-minute task that demonstrates security awareness. The auth service should only accept traffic from the gateway. MongoDB should only accept traffic from the gateway and converter.

**What to say in an interview:** "I implemented Network Policies to restrict east-west traffic. The auth service only accepts connections from the gateway — even if an attacker compromises the converter, they can't directly access the auth database."

---

## 10. Repository Structure

```
vidcast/                              (repo root)
│
├── README.md                         # Public-facing: what, why, how to deploy, how to destroy
├── VIDCAST_UPGRADE_PLAN.md           # This document
├── .gitignore                        # Comprehensive — secrets, state, artifacts
├── Jenkinsfile                       # Enterprise CI/CD alternative
│
├── .github/
│   └── workflows/
│       ├── ci.yml                    # Lint + scan + build + push
│       └── cd.yml                    # Deploy to EKS
│
├── terraform/
│   ├── environments/
│   │   └── dev/
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       ├── outputs.tf
│   │       ├── backend.tf           # S3 + DynamoDB state config
│   │       └── terraform.tfvars     # GITIGNORED — actual values
│   └── modules/
│       ├── vpc/
│       ├── eks/
│       ├── iam/
│       └── security-groups/
│
├── Helm_charts/                      # Existing — unchanged
│   ├── MongoDB/
│   ├── Postgres/
│   └── RabbitMQ/
│
├── src/
│   ├── auth-service/                 # Existing + health endpoint + security context
│   ├── gateway-service/              # Existing + health endpoint + security context
│   ├── converter-service/            # Existing + security context + resource limits
│   ├── notification-service/         # Existing + security context
│   └── frontend/                     # NEW — React web application
│       ├── Dockerfile
│       ├── nginx.conf
│       ├── package.json
│       ├── src/
│       │   ├── App.jsx
│       │   ├── pages/
│       │   │   ├── Login.jsx
│       │   │   ├── Upload.jsx
│       │   │   ├── Download.jsx
│       │   │   ├── Dashboard.jsx
│       │   │   └── Architecture.jsx
│       │   └── components/
│       └── manifest/
│           ├── deployment.yaml
│           ├── service.yaml
│           └── configmap.yaml
│
├── monitoring/
│   ├── values.yaml                   # Custom values for kube-prometheus-stack
│   ├── dashboards/
│   │   └── vidcast-operations.json   # Custom Grafana dashboard
│   └── alerts/
│       └── vidcast-alerts.yaml       # Custom alert rules
│
├── docs/
│   ├── architecture.md
│   ├── deployment-guide.md
│   └── presentation-notes.md
│
└── assets/
    └── video.mp4                     # Test video
```

---

## 11. Branch Strategy

```
main                          ← current working state (base project)
 │
 ├── feature/terraform-infra  ← Phase 1: all Terraform code
 ├── feature/ci-cd-pipeline   ← Phase 2: GitHub Actions + Jenkinsfile
 ├── feature/security-harden  ← Phase 3: probes, limits, security contexts, .gitignore
 ├── feature/monitoring       ← Phase 4: kube-prometheus-stack + dashboard
 ├── feature/frontend         ← Phase 5: React web application
 └── feature/documentation    ← Phase 6: README, arch docs, presentation notes
```

Each branch is merged to main via a Pull Request when complete and tested. This gives us a clean Git history where each PR represents a meaningful improvement. The PR descriptions become talking points: "Here's the PR where I added infrastructure as code. Here's where I introduced container security scanning."

**Rules:**
- Never push directly to main. Always use a feature branch and PR.
- Each PR should have a description explaining what changed and why.
- Merge in order: Phase 1 → 2 → 3 → 4 → 5 → 6 (though 2 and 3 can be parallel).

---

## 12. Cost Breakdown

| Component | Monthly Cost | Notes |
|---|---|---|
| EKS cluster | ~$73 | $0.10/hour for the control plane |
| EC2 node (m7i-flex.large) | ~$70 on-demand | Could reduce with Spot (~$25) but not for a demo |
| EBS storage (30GB gp3) | ~$2.40 | Root volume for the node |
| S3 (Terraform state) | <$0.10 | A few KB of state files |
| DynamoDB (state lock) | <$0.10 | On-demand pricing, minimal usage |
| Data transfer | ~$5 | Minimal for a demo |
| Docker Hub | Free | Public repos, free tier |
| **Total (running 24/7)** | **~$150/month** | |
| **Total (8 hours/day, weekdays only)** | **~$40/month** | Stop the node group outside working hours |

**Cost-saving tip:** The biggest expense is the EC2 node. If you're not actively using the cluster, delete the node group (`aws eks delete-nodegroup`) and recreate it when you need it. The EKS control plane still costs $73/month even with no nodes, so for extended breaks, destroy the whole cluster and recreate it from Terraform.

---

## 13. Real-World Use Cases

This architecture pattern — API gateway, async processing queue, worker services, notification — is used everywhere in industry. Here are concrete examples to reference during the presentation:

**Media processing (YouTube, TikTok, Spotify):** When you upload a video, it goes through a processing pipeline: transcoding to multiple resolutions, thumbnail generation, audio extraction for captions, content moderation. Each step is a separate service consuming from a queue. Our project does the same thing at a smaller scale.

**E-commerce order processing (Amazon, ASOS):** When you place an order, separate services handle payment, inventory, warehouse notification, shipping labels, and confirmation email. The queue absorbs traffic spikes (Black Friday) without dropping orders.

**Banking document processing:** Mortgage applications, bank statements, and identity documents go through OCR, data extraction, fraud checks, and compliance verification — each as a separate service.

**Healthcare imaging:** MRI and X-ray images are uploaded, converted to standard formats, analysed by AI, stored in archives, and the referring doctor is notified. Upload, queue, process, store, notify — same pattern.

---

## 14. Presentation Strategy

### Flow (12-15 minutes)

**Open with the product (2 min):** "This is VidCast — a platform that converts video recordings into podcast-ready audio." Demo the upload through the web interface. Everyone understands what the system does.

**Explain the architecture (3 min):** Switch to the architecture view. Use the restaurant analogy for microservices, the post office analogy for queues. Walk through the data flow.

**Show the platform engineering (5 min):** Show Terraform creating infrastructure. Show the CI/CD pipeline deploying a change. Show the Grafana dashboard. Show the security contexts. Explain each in terms the audience can follow.

**Talk about what you'd do next (2 min):** Managed databases, service mesh, KEDA, GitOps. Shows you see beyond what you built.

**Close with real-world connection (1 min):** "This is the same pattern used by YouTube, Spotify, and every media processing platform. The scale is different, but the principles are identical."

### Teaching Tips

- Start with the problem, not the technology.
- One analogy per concept. Don't stack metaphors.
- If you're about to say a technical term, explain it immediately: "RabbitMQ — that's our post office sorting room — was showing a backlog."
- Show, don't tell. A live demo is worth ten slides.
- End each section with "and this is why it matters" before moving on.
