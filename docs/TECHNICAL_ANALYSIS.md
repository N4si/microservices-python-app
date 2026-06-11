# VidCast — Technical Project Analysis

> A senior-DevOps review of the VidCast video-to-audio microservices platform.
> Covers what the project does, how it is built, what it does well by
> industry standards, and where it falls short — with concrete, prioritised
> recommendations. Every source file (application code, Terraform, CI/CD,
> Helm, manifests, Dockerfiles, monitoring) was read line by line for this
> assessment.

---

## Part 1 — What This Project Is and Does

### One-line summary
VidCast is a **video-to-audio conversion platform** — "turn video recordings
into podcast-ready audio." A user logs in, uploads an MP4, the system
asynchronously extracts the audio track, stores it as an MP3, and emails them a
download link.

### The core flow (the actual logic)
The system is an **event-driven, asynchronous pipeline** built around two
RabbitMQ queues (`video` and `mp3`). Following a single upload through the code:

1. **Login** — The frontend (`src/frontend/src/api.js`) POSTs HTTP Basic
   credentials to the **gateway** `/login`, which proxies to the
   **auth-service** (`auth_svc/access.py` → `auth-service/server.py`). Auth looks
   the user up in PostgreSQL, verifies the password with `bcrypt.checkpw`
   (constant-time), and mints a **JWT** (`CreateJWT`) carrying `username`,
   `role`, a backward-compatible `admin` boolean, `iat`, and a 1-day `exp`.

2. **Upload** — The frontend POSTs the file plus `Authorization: Bearer <jwt>`
   to gateway `/upload`. The gateway validates the token by calling auth
   `/validate` (`auth/validate.py`), then `storage/util.py`:
   - Stores the raw video in **MongoDB GridFS** (`fs_videos`), tagging it with
     `metadata.owner_email` = the uploader's JWT email.
   - Publishes a persistent message `{video_fid, mp3_fid:null, username}` to the
     RabbitMQ **`video` queue**. If the publish fails, it rolls back the GridFS
     write (`fs.delete`) — a genuine write-consistency guard.

3. **Convert** — The **converter-service** (`consumer.py` →
   `convert/to_mp3.py`) consumes the `video` queue. It pulls the video out of
   GridFS into a temp file, uses **MoviePy/ffmpeg** to extract the audio, writes
   the MP3 into a *separate* GridFS DB (`fs_mp3s`) — copying the `owner_email`
   tag forward — then publishes `{..., mp3_fid}` to the **`mp3` queue**.
   ACK/NACK semantics drive retry.

4. **Notify** — The **notification-service** (`consumer.py` → `send/email.py`)
   consumes the `mp3` queue and emails the uploader (recipient = the `username`
   carried through the message, never hardcoded) via Gmail SMTP. It is written
   defensively: it never raises (a raise would crash-loop the pod), it ACK-drops
   unparseable or recipient-less messages, and it NACKs only on *retryable*
   failures.

5. **Download** — The user hits gateway `/download?fid=...`, which streams the
   MP3 back out of GridFS via Flask `send_file`.

### Extensions beyond the original fork
The repo is a hardened, extended descendant of `N4si/K8s-video-converter`:

- **Real RBAC** — a `role` column in PostgreSQL (`user` vs `admin`).
  Self-registration always creates a `user` (the comments note the original code
  minted admin JWTs — a fixed privilege-escalation hole). Admin-only gateway
  endpoints (`/admin/users` GET, PATCH) are guarded by `_require_admin`, with two
  real-world safety guardrails: an admin **cannot change their own role**, and the
  system **refuses to demote the last remaining admin** (lockout prevention).
  Role changes emit an audit log line.
- **Per-user ownership** — `/my-files` lists only the caller's conversions
  (GridFS `owner_email` query); `/notifications/unseen-count` powers a "new
  conversions" badge using a `since` timestamp.
- **Health endpoints** — auth `/healthz` pings PostgreSQL; gateway `/healthz`
  checks MongoDB + RabbitMQ; the queue consumers `touch /tmp/healthy` for
  exec-based liveness probes (with a startup touch so idle consumers don't
  crash-loop).
- **Frontend** (React + Vite + Tailwind) — Login, Upload, Download, My
  Conversions, plus admin-only Dashboard (Grafana iframe), Architecture diagram,
  and Users pages. It decodes the JWT client-side **for UX only** and explicitly
  documents that the backend is the real authority.

### Technology stack

| Layer | Technology |
|---|---|
| **Backend services** | Python 3.10, Flask (auth + gateway), Pika (RabbitMQ), psycopg2, bcrypt, PyJWT, PyMongo/GridFS, MoviePy + ffmpeg, smtplib |
| **Frontend** | React, Vite, Tailwind CSS, React Router, axios; nginx (non-root) |
| **Messaging** | RabbitMQ (`video` & `mp3` durable queues) |
| **Datastores** | MongoDB GridFS (video + mp3 binaries), PostgreSQL (users/auth) |
| **Orchestration** | Kubernetes on AWS EKS (prod, eu-west-2, m7i-flex.large); raw manifests per service + Helm charts for Mongo/Postgres/RabbitMQ |
| **Staging** | Docker Swarm on a t2.micro (`docker-compose.swarm.yml`) |
| **IaC** | Terraform (modules: vpc, iam, eks, security-groups, github-oidc) with S3/DynamoDB state backend |
| **CI/CD** | GitHub Actions (`ci.yml`, `cd.yml`) **and** a `Jenkinsfile` with a Swarm→approval→EKS promotion flow |
| **Observability** | Prometheus + Grafana + Alertmanager (kube-prometheus-stack), custom dashboard + alert rules |

---

## Part 2 — Technical Assessment: What Was Done Well

This is a strong portfolio/learning project that demonstrably reaches for
production patterns. The following are genuine, industry-standard strengths.

### 2.1 Architecture & application design
- **Clean event-driven decomposition.** Upload, convert, and notify are
  decoupled through durable queues with `PERSISTENT_DELIVERY_MODE`. This is the
  correct shape for CPU-heavy media work — the gateway returns immediately and
  conversion scales horizontally.
- **Correct messaging semantics.** Consumers ACK on success and NACK on
  retryable failure; the gateway compensates a failed publish by deleting the
  orphaned GridFS object. The notification service distinguishes *permanent*
  failures (ACK-drop) from *transient* ones (NACK-requeue) — a distinction many
  juniors miss.
- **Separation of concerns inside services.** The gateway splits `auth`
  (validate), `auth_svc` (login/register), and `storage` (GridFS + publish) into
  focused modules rather than one monolithic `server.py`.
- **Stateless services with externalised state.** All persistence lives in
  Mongo/Postgres/RabbitMQ, so the Flask/consumer pods scale and restart freely.

### 2.2 Security engineering (application layer)
- **bcrypt password hashing** with `gensalt(rounds=12)` and constant-time
  `checkpw`; legacy/non-bcrypt rows are treated as auth failures, never 500s.
- **Privilege-escalation fix** — self-registration is hard-pinned to `role=user`;
  it cannot mint an admin.
- **Thoughtful RBAC guardrails** — no self-demotion, no last-admin demotion
  (returns `409`), plus an audit log line on every role change. These are
  operational-maturity touches, not just feature code.
- **Secrets kept out of git.** `.gitignore` excludes `**/secret.yaml`,
  `terraform.tfvars`, `*.tfstate`, `customise.sh`, and session docs; tracked
  `*.example` templates document the shape without leaking values. Mongo URIs and
  the JWT secret were correctly **moved out of ConfigMaps into Secrets** (with a
  comment explaining why).
- **Defensive error handling** — endpoints avoid leaking stack traces;
  `silent=True` JSON parsing; explicit status codes (`400/401/403/404/409/502`).

### 2.3 Container & Kubernetes hardening
- **Non-root everywhere.** Every Dockerfile sets `USER 1000/1001`, and every
  Deployment sets `runAsNonRoot`, `runAsUser`, `allowPrivilegeEscalation: false`,
  and `capabilities: drop: ["ALL"]`.
- **`readOnlyRootFilesystem: true`** on all four backend services, with a
  correctly scoped writable `emptyDir` at `/tmp` exactly where it's needed
  (Werkzeug multipart buffering, ffmpeg temp files, the `/tmp/healthy`
  heartbeat). The comment trail shows this was reasoned, not cargo-culted.
- **Liveness/readiness probes** appropriate to each workload type — HTTP
  `/healthz` for the web services, exec `test -f /tmp/healthy` for the queue
  consumers (which have no HTTP surface).
- **Resource requests and limits** set per service and tuned to the real node
  (the converter was deliberately dropped from 4→2 replicas after hitting
  "Insufficient cpu" on a 2-vCPU node — a real capacity-planning decision,
  documented inline).
- **Frontend multi-stage build** (`node:18-alpine` builder → `nginx:1.25-alpine`
  runtime) running as a dedicated non-root uid with pre-chowned nginx dirs and
  PID file. Security headers (`X-Frame-Options`, `X-Content-Type-Options`,
  `X-XSS-Protection`) and a sane `client_max_body_size 256m` for uploads.

### 2.4 Supply-chain & dependency hygiene
- **Trivy scanning** wired into *both* pipelines at `CRITICAL,HIGH` with
  `exit-code 1` and `ignore-unfixed` — a real, blocking gate.
- **Deliberately curated requirements.** The `requirements.txt` files are
  remarkable: each pin carries a comment citing the specific CVE it clears
  (Werkzeug CVE-2024-34069, urllib3 2.x line, Pillow ≥10.3.0, numpy <2.0 for
  MoviePy compat), and dev-only tooling (pylint/astroid/jedi) and unused
  packages (prometheus-client) were stripped from the runtime image.
- **Dockerfiles patch the OS layer** (`apt-get upgrade`) and the Python
  toolchain (`pip install --upgrade pip setuptools wheel`) to clear base-image
  CVEs, with comments naming them.

### 2.5 Infrastructure as Code (Terraform)
- **Properly modularised** (`vpc`, `iam`, `eks`, `security-groups`,
  `github-oidc`) with a clean root composition in `environments/dev/main.tf`.
- **Remote state done right** — S3 backend with DynamoDB locking,
  `required_version >= 1.5`, providers pinned with `~>`.
- **Least-privilege-minded CI auth** — GitHub Actions authenticates via **OIDC**
  (`aws_iam_openid_connect_provider`) with a trust policy scoped to the repo, and
  the deploy role's *only* AWS permission is `eks:DescribeCluster` on one cluster
  ARN; Kubernetes-level rights are granted separately via an **EKS access entry**
  with `AmazonEKSEditPolicy`. No long-lived AWS keys in GitHub secrets. This is
  exactly the modern pattern.
- **A real `validation` block** rejecting T-type instances (encoding a known
  account SCP constraint into the type system so it fails fast at plan time), and
  IRSA enabled via the cluster OIDC provider.

### 2.6 CI/CD design
- **Matrix-parallel CI** across all four services (lint → build → scan →
  push-on-main-only) with `fail-fast: false` so one service's failure doesn't
  mask the others.
- **A genuine promotion pipeline in Jenkins** — lint → parallel build → Trivy →
  push → deploy to Swarm staging → smoke test → **manual approval gate** → deploy
  to EKS, with an automatic `kubectl rollout undo` on failure. The staging-on-
  Swarm choice is a legitimate ~97% cost optimisation over a second EKS cluster.
- **CD via `workflow_run`** gated on CI success, using short-SHA image tags and
  `kubectl rollout status` for verification.

### 2.7 Observability
- kube-prometheus-stack with sensible EKS-specific tuning (etcd/scheduler/
  controller-manager scraping disabled — EKS manages them), 7-day retention,
  persistent storage, NodePort-exposed Grafana/Alertmanager.
- **Meaningful alert rules** with runbook-style annotations
  (`kubectl logs --previous`, `kubectl describe pod rabbitmq-0`):
  CrashLoopBackOff, high node CPU/mem, queue backlog, RabbitMQ down.

### 2.8 Documentation & operational discipline
- Exceptional inline commenting — the "why," the CVE, the trade-off, and the
  backward-compatibility note are captured at the point of change.
- A handover/report/problems doc system for crash-safe, resumable multi-session
  work, and per-issue `*_EXPLAINED.md` study material.

**Overall verdict on merits:** the engineering *judgment* on display is well
above typical bootcamp output. The dependency hygiene, OIDC-based CI auth, pod
security contexts, and RBAC guardrails are all things real production teams ship.

---

## Part 3 — Areas for Improvement (Demerits & Risks)

Ordered roughly by severity. Severity reflects *production* readiness; several
are explicitly acknowledged as acceptable for a learning/demo context.

### 3.1 Critical / High

**[H-1] Databases exposed to the public internet via NodePort + `0.0.0.0/0`.**
The security-group module opens ports `30002–30008` to `0.0.0.0/0`, and Postgres
(`30003`), RabbitMQ (`30004`), and MongoDB (`30005`) are all NodePort services.
That publishes the datastores' admin ports to the entire internet.
→ *Fix:* remove DB NodePorts entirely (they're for admin convenience only —
use `kubectl port-forward`); restrict the remaining app NodePorts (or front them
with an ALB/Ingress + security group scoped to the LB). Never expose
stateful-service ports to `0.0.0.0/0`.

**[H-2] PostgreSQL runs with `POSTGRES_HOST_AUTH_METHOD: trust`.**
In `Helm_charts/Postgres/templates/postgres-deploy.yaml` Postgres accepts **any
connection with no password**. Combined with [H-1], anyone who can reach
`NODE_IP:30003` gets unauthenticated DB access — including the full `auth_user`
table.
→ *Fix:* drop `trust`, rely on `scram-sha-256`, and keep the DB ClusterIP-only.

**[H-3] A live-looking Gmail app password sits in the working tree.**
`customise.sh` (gitignored, so not committed — good) nonetheless contains a real
16-char `GMAIL_APP_PASSWORD`, the JWT secret, and DB passwords in plaintext on
disk. Gitignore prevents a commit but not local exfiltration, and the credential
is real.
→ *Fix:* **rotate that Gmail app password now**, then source these values from
the environment / a secret manager rather than baking them into a script.

**[H-4] No external secret management.** Secrets live in `stringData` in
gitignored `secret.yaml` files (committed comments even say "back this with AWS
Secrets Manager + External Secrets Operator"). Manual secret files don't rotate,
aren't audited, and drift between environments.
→ *Fix:* adopt the External Secrets Operator backed by the IRSA infra that
already exists.
→ *Status (Phase Up A9 — strong-partial):* **resolved for application secrets.**
ESO now syncs `auth/gateway/converter/notification` secrets from **AWS SSM
Parameter Store** (not Secrets Manager) via a least-privilege IRSA role
(`terraform/modules/external-secrets`, `k8s/external-secrets/`). Parameter Store
was chosen over Secrets Manager precisely to avoid the $0.40/secret/month charge:
standard-tier parameters and the AWS-managed `alias/aws/ssm` SecureString key are
both free, so the **standing cost is $0**. *Pending:* the `rabbitmq-secret` is
still Helm-provisioned (the broker is created from it) and migrates to Parameter
Store only if/when a managed broker is adopted — deferred with reason, see
`MANAGED_SERVICES.md` §4.

### 3.2 Medium

**[M-1] Flask development server in production.** Both `auth-service` and
`gateway-service` run `server.run(host=…)` — the single-threaded Werkzeug dev
server, which prints "do not use in a production deployment." Under concurrency
it will serialise requests and degrade badly.
→ *Fix:* run behind `gunicorn`/`uvicorn` workers (e.g.
`gunicorn -w 4 -b 0.0.0.0:8080 server:server`).

**[M-2] Monitoring scrape/alert mismatch — alerts that can never fire.**
- `monitoring/values.yaml` adds a scrape job for `gateway:8080/metrics`, but the
  gateway has **no `/metrics` endpoint** (prometheus-client was intentionally
  removed). That target will be permanently `down`.
- `vidcast-alerts.yaml` references `rabbitmq_queue_messages{queue="video"}` and
  `up{job="rabbitmq"}`, but **no RabbitMQ exporter / scrape job is configured**.
  The two most pipeline-relevant alerts (queue backlog, RabbitMQ down) will never
  evaluate.
→ *Fix:* either expose real app metrics (re-add a `/metrics` endpoint with
request/queue gauges) and deploy the RabbitMQ Prometheus plugin/exporter, or
remove the dangling scrape job and alerts so the monitoring stack reflects
reality.

**[M-3] No persistent storage for PostgreSQL.** The Postgres Helm chart is a
`Deployment` with no PVC — a pod reschedule wipes every user account.
(Acknowledged in CLAUDE.md as "use RDS in production.")
→ *Fix:* RDS, or at minimum a StatefulSet + PVC like MongoDB/RabbitMQ already
have.

**[M-4] Unpinned images.** The Postgres Helm value is `image: postgres` (→
`latest`), and the staging compose uses `:latest` tags throughout. This breaks
reproducibility and makes rollbacks nondeterministic.
→ *Fix:* pin every image to a digest or explicit version.

**[M-5] In-cluster service-to-service calls are unauthenticated.** The
auth-service's `/users` and `/validate` endpoints carry no auth of their own and
trust any in-cluster caller; the gateway is the sole enforcer (the code honestly
documents this trust gap). There is **no NetworkPolicy**, so any compromised pod
can call auth directly and enumerate/modify users.
→ *Fix:* default-deny NetworkPolicies scoping who can reach auth:5000, and/or a
shared internal token / service mesh mTLS.

**[M-6] Frontend image isn't built by CI and uses a placeholder.**
`frontend/manifest/deployment.yaml` points at
`<AWS_ACCOUNT_ID>.dkr.ecr…/vidcast-frontend:latest` — a literal placeholder that
won't deploy unedited, built out-of-band (CI only builds the four Python
services). This is a manual, error-prone step and a `:latest` tag.
→ *Fix:* add the frontend to the CI matrix (or a dedicated job) pushing to ECR
with a SHA tag, and template the account ID via kustomize/Helm.

### 3.3 Low / Polish

- **[L-1] No CPU/memory `HPA`** despite the whole point being scalable
  conversion; scaling is manual (edit replicas / node desired_size). A queue-depth
  or CPU HPA on the converter would close the loop.
- **[L-2] No PodDisruptionBudgets** — voluntary disruptions (node drains) can
  take all replicas of a 2-replica service at once.
- **[L-3] Odd `maxSurge` values** — `notification` has `maxSurge: 8` for 2
  replicas, `gateway`/`auth` use `maxSurge: 3`. Harmless but sloppy; pick values
  proportional to replica count and set `maxUnavailable` explicitly.
- **[L-4] No connection resilience on broker/DB.** `pika.BlockingConnection` is
  established once at import time with `heartbeat=0`; a RabbitMQ blip won't
  auto-reconnect (the gateway would need a pod restart). Postgres connections are
  opened per-request with no pooling (`psycopg2` raw) — fine at low volume,
  costly at scale.
- **[L-5] Single AZ-ish footprint / single node.** `desired_size=1` on one
  instance type means the node is a SPOF; the two subnets span AZs but the node
  group runs one node.
- **[L-6] Dockerfiles aren't multi-stage for the Python services.**
  `build-essential`, `python3-dev`, `libpq-dev` remain in the runtime image,
  enlarging it and the attack surface. A builder stage + `psycopg2-binary` (or
  copying only the built wheels) would slim them.
- **[L-7] No automated tests.** There are no unit/integration tests in the repo;
  CI lints and scans but never asserts behaviour. A few pytest cases around
  auth/RBAC and the publish-rollback path would catch regressions the linter
  can't.
- **[L-8] CD uses `|| true` on rollout steps**, so a failed `kubectl rollout
  status` won't fail the GitHub Actions job — a broken deploy can report green.
  (Jenkins handles this better with explicit rollback.)
- **[L-9] No Content-Security-Policy** header on the frontend (only the three
  legacy headers); `X-XSS-Protection` is deprecated.
- **[L-10] Terraform `dev`-only.** There's one environment dir; staging/prod
  parity is via Swarm compose rather than a `prod` Terraform workspace. Fine for
  the project's scope, but not a multi-env IaC layout.

---

## Part 4 — Prioritised Recommendations

**Do now (security):**
1. Rotate the Gmail app password exposed in `customise.sh` [H-3].
2. Remove DB NodePorts and stop opening `0.0.0.0/0` to stateful ports [H-1].
3. Remove `POSTGRES_HOST_AUTH_METHOD: trust`; require auth [H-2].

**Next (production-readiness):**
4. Put auth/gateway behind gunicorn [M-1].
5. Adopt External Secrets Operator on the existing IRSA foundation [H-4]. ✅ *Done (A9, Parameter Store, $0 standing; broker creds pending).*
6. Give Postgres durable storage (RDS or StatefulSet+PVC) [M-3].
7. Reconcile monitoring: real `/metrics` + RabbitMQ exporter, or remove the
   dead scrape/alerts [M-2].
8. Pin all images to digests/versions [M-4].

**Then (hardening & scale):**
9. NetworkPolicies (default-deny) + scope auth's internal endpoints [M-5].
10. Add the frontend to CI/ECR with SHA tags [M-6].
11. HPA on the converter, PDBs on all services, broker auto-reconnect
    [L-1, L-2, L-4].
12. Multi-stage Python Dockerfiles, a pytest suite, and make CD fail on rollout
    errors [L-6, L-7, L-8].

---

## Part 5 — Bottom Line

VidCast is, at its core, a **DevOps/cloud-engineering showcase** wrapped around a
deliberately simple media-conversion app. Judged as that, it is **well above
average**: the event-driven architecture is sound, and the surrounding platform
work — OIDC-based CI auth, curated CVE-clearing dependencies, pod security
contexts, RBAC with real lockout guardrails, a Swarm→approval→EKS promotion
pipeline, and unusually honest inline documentation — reflects mature
engineering judgment.

Its gaps are the predictable ones for a project optimised for a single-node demo
on a budget: **internet-exposed datastores with weak/no DB auth, dev-grade app
servers, no external secret management, no durable Postgres, and a monitoring
layer whose most important alerts can't fire.** None are hard to fix, and most
are already self-identified in the code comments and CLAUDE.md. Close the four
High items and the handful of Medium ones and this moves from "excellent
portfolio project" to "defensible small-scale production deployment."

*Per project records, the live EKS cluster was torn down on 2026-06-03 for cost
savings, with Terraform state, tfvars, and ECR images preserved for a
one-command re-apply.*
