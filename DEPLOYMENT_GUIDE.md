# VidCast Deployment Guide

This is the **single canonical guide** for taking VidCast from "cluster torn down,
nothing running" to "everything live and verified," including all Sprint 1–4 upgrades
(Kustomize, ESO, KEDA, Argo CD, Kyverno, NetworkPolicies, outbox/idempotency/DLQ, SLO
alerting, supply-chain, Kubecost). Every command is copy-pasteable; every "wait for X"
has a check command.

> **No personal data here.** This guide uses **placeholders** (`<AWS_ACCOUNT_ID>`,
> `<YOUR_DOCKERHUB_USER>`, `<YOUR_GITHUB_ORG>`, `<NODE_IP>`, …). Substitute your own
> values — the easiest way is the two scripts below.

## ⚡ The fast path (two scripts)

Most of this guide is reference. The actual bring-up is **two commands** once your
infrastructure exists (Terraform applied, node Ready) and your config is in your shell:

```bash
./customise.sh    # rewrites identity (Docker Hub user, AWS account, GitHub repo) + DB
                  # creds + the bcrypt admin hash across the repo's config files
./deploy.sh       # installs datastores → secrets → app → KEDA/Argo/Kyverno/monitoring/
                  # Kubecost → NetworkPolicies, then smoke-tests and prints the URLs
./deploy.sh --teardown   # when finished: terraform destroy + confirm $0 spend
```

Both read their inputs from **environment variables** (so no secret is ever written to
a tracked file). See **§A.2** for what to set and **how to obtain each value**, and the
header comments inside each script for the full list. The sections below explain what
the scripts do, step by step, so you can run them by hand or debug them.

**This document serves two audiences:**
- **Part A** — for someone forking VidCast onto their **own AWS account** for the first
  time: what to install, what each account needs, every value to change (and how to get
  it), and an honest cost warning.
- **Part B (§0 onward)** — the concrete bring-up runbook (what `deploy.sh` automates),
  with copy-pasteable commands using placeholders.

> **Footprint decision (signed off):** deploy the **dev overlay** (1-replica
> backends) and run **Kubecost on the dev footprint** — this keeps the single
> 2-vCPU node at ~81% idle. Prod overlay + Kubecost would breach the 90% gate.

---

# PART A — For Newcomers (read this first if you're forking the repo)

## A.1 Prerequisites — What You Need Before You Start

You need **four accounts** and **seven tools**. Budget ~30 minutes for first-time
setup before you ever touch the cluster.

### Accounts

1. **An AWS account** with either **admin access** or, at minimum, permission to
   create: VPCs, EKS clusters, EC2 (the node), IAM roles/policies + an OIDC provider,
   ECR repositories, and SSM Parameter Store entries. (Admin is simplest for a
   learning project; the least-privilege set is the list above.) New AWS accounts get
   a free tier, but **EKS itself is not free** — see the Cost Warning (§A.3).
2. **A Docker Hub account** (free) — the five backend images are built by CI and
   pushed here, then pulled by the cluster. You'll set your username everywhere the
   project currently says `<YOUR_DOCKERHUB_USER>`.
3. **A Gmail account with an "App Password"** — the notification service sends the
   "your audio is ready" email via Gmail's SMTP. Normal Gmail passwords won't work for
   SMTP; you must generate a 16-character **App Password** (requires 2-factor auth on
   the account). Instructions: <https://myaccount.google.com/apppasswords>. Strip the
   spaces when you paste it.
4. **A GitHub account with this repo forked.** GitHub is where the code lives, where
   CI runs, and — importantly — the identity AWS trusts for keyless deploys (OIDC) and
   image signing. Your fork's `owner/repo` name must be wired into a few places (§A.2).

### Tools (Ubuntu / WSL2 install commands)

| Tool | What it's for | Install |
|---|---|---|
| **AWS CLI v2** | talk to AWS from the terminal | `curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip && unzip awscliv2.zip && sudo ./aws/install` |
| **Terraform ≥ 1.5** | build the AWS infra from code | `sudo apt-get update && sudo apt-get install -y gnupg software-properties-common && wget -O- https://apt.releases.hashicorp.com/gpg \| gpg --dearmor \| sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null && echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \| sudo tee /etc/apt/sources.list.d/hashicorp.list && sudo apt-get update && sudo apt-get install -y terraform` |
| **kubectl** | talk to the Kubernetes cluster | `curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl` |
| **Helm v3** | install off-the-shelf software (DBs, monitoring) | `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` |
| **Docker** | build/run container images | `curl -fsSL https://get.docker.com \| sh && sudo usermod -aG docker $USER` (log out/in after) |
| **git** | clone the repo, push changes | `sudo apt-get install -y git` |
| **psql client** | run the database init script | `sudo apt-get install -y postgresql-client` |

After installing, configure AWS auth once: `aws configure` (enter your access key,
secret, region `eu-west-2`, output `json`), then verify with
`aws sts get-caller-identity` — it should print *your* account ID.

---

## A.2 Customisation — Making It Your Own + How to Get Each Value

To run VidCast yourself you supply your **own** values. Set them as environment
variables, then **`./customise.sh`** writes the identity/DB values into the repo's
config files and **`./deploy.sh`** uses the secrets at install time. The table below is
the full inventory: each value, **how to obtain it**, and where it's used.

| Value (env var) | How to get it | Where it's used |
|---|---|---|
| **AWS account ID** (`AWS_ACCOUNT_ID`) | `aws sts get-caller-identity --query Account --output text` | ECR image refs in `k8s/overlays/*/kustomization.yaml`; Terraform |
| **AWS region** (`AWS_REGION`) | Pick a region; default `eu-west-2`. Use one that allows non-T-type EKS nodes. | `terraform.tfvars`, ESO `ClusterSecretStore` |
| **Docker Hub username** (`DOCKER_HUB_USER`) | Sign up free at hub.docker.com — it's your account name. | `k8s/overlays/*` backend image names; GitHub secret `DOCKERHUB_USERNAME` |
| **GitHub org/repo** (`GITHUB_ORG`,`GITHUB_REPO`) | Your fork's URL: `github.com/<org>/<repo>`. | OIDC trust (Terraform), Argo CD `repoURL`, Kyverno cosign signer identity — all must point at **your** fork |
| **Cluster name** (`CLUSTER_NAME`) | Pick any name **without underscores** (EKS rejects them); e.g. `vidcast-cluster`. | `terraform.tfvars` |
| **ECR repo name** (`ECR_REPO_NAME`) | Pick a name for the frontend image repo; e.g. `vidcast-frontend`. | Terraform `repository_names`; overlay frontend `newName` |
| **PostgreSQL user / password** (`POSTGRES_USERNAME`,`POSTGRES_PASSWORD`) | User: pick one (e.g. `pguser`). Password: `openssl rand -base64 24`. | injected into the Postgres chart by `deploy.sh`; Parameter Store `/vidcast/<env>/auth/psql-password` |
| **MongoDB user / password** (`MONGODB_USERNAME`,`MONGODB_PASSWORD`) | User: pick one (e.g. `mongouser`). Password: `openssl rand -base64 24`. | injected into the Mongo chart by `deploy.sh`; embedded in the Mongo URIs in Parameter Store |
| **RabbitMQ user / password** (`RABBITMQ_USERNAME`,`RABBITMQ_PASSWORD`) | User: default `rabbituser`. Password: `openssl rand -base64 24`. | injected into the RabbitMQ chart by `deploy.sh` (→ `rabbitmq-secret`) |
| **JWT secret** (`JWT_SECRET`) | `openssl rand -base64 32` — the key that signs login tokens. | Parameter Store `/vidcast/<env>/auth/jwt-secret` |
| **Gmail address** (`GMAIL_ADDRESS`) | A Gmail account you control — the "from" address on the notification email. | Parameter Store `/vidcast/<env>/notification/gmail-address` |
| **Gmail App Password** (`GMAIL_APP_PASSWORD`) | Enable 2FA, then generate a 16-char app password at <https://myaccount.google.com/apppasswords> (strip spaces). | Parameter Store `/vidcast/<env>/notification/gmail-password` |
| **Login email / password** (`APP_LOGIN_EMAIL`,`APP_LOGIN_PASSWORD`) | Pick the admin login. `customise.sh` turns the password into a **bcrypt hash** in `init.sql` (you never store the plaintext). | seeded admin row in `Helm_charts/Postgres/init.sql` |

> **Where each kind of value lives — and why secrets never touch Git:**
> - **Secrets** (DB passwords, JWT, Gmail password) → **AWS Parameter Store**, seeded by
>   `deploy.sh` from your env vars. The chart values carry only `CHANGEME` placeholders;
>   `deploy.sh` injects the real passwords with `--set` at install time. **No secret is
>   ever written to a tracked file.**
> - **Identity** (Docker Hub user, AWS account, GitHub repo) → tracked config that the
>   GitOps engine (Argo CD) and AWS need to *function* — these are inherently public
>   (a public Docker Hub user / GitHub repo). `customise.sh` rewrites them to yours.

> **Parameter Store is your safe-deposit box.** The secrets above aren't written into
> any file — they're put into Parameter Store once (by `deploy.sh`), and the app
> retrieves them at runtime via the External Secrets Operator. The app holds a key (its
> AWS identity) to the box; the contents are never committed anywhere.

Convenient way to set everything, then customise + deploy:
```bash
# put your values in a LOCAL, gitignored file (never commit it), then:
set -a; source ./my-vidcast.env; set +a     # exports all the vars above
./customise.sh        # rewrites identity + DB creds + bcrypt admin hash in the repo
./deploy.sh           # brings everything up and verifies
```

---

## A.3 ⚠️ COST WARNING — Read Before You `apply`

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  RUNNING THIS PROJECT COSTS REAL MONEY WHILE THE CLUSTER IS UP.               │
│                                                                              │
│   • EKS control plane (the managed Kubernetes brain)  ~ $0.10 / hour  (~$73/mo)│
│   • The node (m7i-flex.large EC2 instance)            ~ $0.11 / hour  (~$77/mo)│
│   • EBS / data transfer / etc. (small)                 a few $ / month        │
│   ───────────────────────────────────────────────────────────────────────────│
│   ≈ $0.21 / hour while up   →   ~$150 / month if left running 24×7.            │
│                                                                              │
│  A 1-hour demo costs about 20 cents. Leaving it on all month costs ~$150.     │
│                                                                              │
│  👉 DESTROY IT WHEN YOU'RE DONE. Standing cost when destroyed = ~$0.          │
│     (Terraform state in S3, the DynamoDB lock table, and Parameter Store      │
│      entries are all free to leave; the frontend ECR images are pennies.)     │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Teardown (the one command that stops the billing):**
```bash
./deploy.sh --teardown          # runs terraform destroy + confirms zero spend
# — or manually —
cd terraform/environments/dev && terraform destroy -auto-approve   # ~10 min
aws eks list-clusters --region eu-west-2     # expect []  (nothing left billing)
```
Everything is rebuildable from code in ~20 minutes, so the right habit is: **bring it
up for a session, then tear it down.** Treat "is the cluster on?" as the cost switch.

> **Tip:** set an **AWS Budgets** alarm (e.g. alert at $20/month) before your first
> `apply`, so a forgotten cluster can't surprise you. AWS Console → Billing → Budgets.

---

# PART B — The Runbook (worked example: original operator's values)

> Everything below uses the original account/Docker Hub/cluster values as a concrete,
> copy-pasteable example. If you did §A.2, substitute your own values. **`deploy.sh`
> automates §3–§8 of this part;** §0–§2 (prerequisites, Terraform apply) are still
> run by hand because they create the AWS account-level infrastructure.

## 0. Fixed facts (account / state / preserved resources)

```
AWS_ACCOUNT_ID:      <AWS_ACCOUNT_ID>
AWS_REGION:          eu-west-2
CLUSTER_NAME:        vidcast-cluster            # Terraform-managed (NOT the old cba-microservices)
NODE_INSTANCE_TYPE:  m7i-flex.large  (2 vCPU / 8 GiB; NEVER T-type — SCP blocks it)
DOCKER_HUB_USER:     <YOUR_DOCKERHUB_USER>
APP_LOGIN_EMAIL:     <YOUR_LOGIN_EMAIL>
```

**Preserved across teardown (DO NOT delete — they make re-apply one command):**
```
S3 state bucket:     vidcast-tfstate-<AWS_ACCOUNT_ID>   (key: vidcast/dev/terraform.tfstate)
DynamoDB lock table: vidcast-terraform-locks        (ACTIVE)
terraform.tfvars:    terraform/environments/dev/terraform.tfvars   (gitignored, real inputs)
ECR repo + images:   vidcast-frontend  (tags incl. d9e4282 — frontend need NOT be rebuilt)
```

---

## 1. Prerequisites (before `terraform apply`)

### 1.1 Tools
```bash
aws --version          # v2.x
terraform version      # >= 1.5
kubectl version --client
helm version           # v3.x
git --version
```

### 1.2 AWS credentials
```bash
aws sts get-caller-identity   # expect account <AWS_ACCOUNT_ID> (user johnadmin / johnsadmin)
```

### 1.3 Docker Hub backend images must exist (you — build & push the backend images first)
The dev overlay pins these tags; each must be pullable **before** the app is deployed:
```bash
# Replace <SHA> with the tag the overlay pins (k8s/overlays/dev/kustomization.yaml)
for s in auth-service gateway-service converter-service notification-service outbox-relay; do
  docker manifest inspect <YOUR_DOCKERHUB_USER>/$s:<SHA> >/dev/null 2>&1 \
    && echo "$s ✓" || echo "$s ✗ MISSING — build via CI before deploying";
done
```
> If any is ✗, the corresponding pod will `ImagePullBackOff`. The B4 `/metrics`
> endpoints exist ONLY in images rebuilt from Sprint-4 code (push to main → CI).
> The frontend (`vidcast-frontend:d9e4282`) is on ECR and pulled via the node role.

### 1.4 Parameter Store seeded (you — seed these before installing ESO)
ESO reads these 7 `dev` SecureString parameters. Seed from the gitignored
`DEPLOYMENT_CONFIG.md` values (NOT committed anywhere):
```bash
REGION=eu-west-2
put() { aws ssm put-parameter --region "$REGION" --type SecureString --overwrite --name "$1" --value "$2"; }
put /vidcast/dev/auth/psql-password          "$POSTGRES_PASSWORD"
put /vidcast/dev/auth/jwt-secret             "$JWT_SECRET"
put /vidcast/dev/gateway/mongodb-videos-uri  "mongodb://$MONGODB_USERNAME:$MONGODB_PASSWORD@mongodb:27017/videos?authSource=admin"
put /vidcast/dev/gateway/mongodb-mp3s-uri    "mongodb://$MONGODB_USERNAME:$MONGODB_PASSWORD@mongodb:27017/mp3s?authSource=admin"
put /vidcast/dev/converter/mongodb-uri       "mongodb://$MONGODB_USERNAME:$MONGODB_PASSWORD@mongodb:27017/mp3s?authSource=admin"
put /vidcast/dev/notification/gmail-address  "$GMAIL_ADDRESS"
put /vidcast/dev/notification/gmail-password "$GMAIL_APP_PASSWORD"   # 16 chars, NO spaces
# Verify:
aws ssm get-parameters-by-path --region $REGION --path /vidcast/dev --recursive --query 'Parameters[].Name'
```

---

## 2. Terraform apply (infra: VPC, EKS, node group, VPC-CNI netpol agent, ECR, OIDC)

```bash
cd terraform/environments/dev
terraform init \
  -backend-config="bucket=vidcast-tfstate-<AWS_ACCOUNT_ID>" \
  -backend-config="key=vidcast/dev/terraform.tfstate" \
  -backend-config="region=eu-west-2" \
  -backend-config="dynamodb_table=vidcast-terraform-locks"
terraform validate
```

### 2.1 ECR import (A8 — the existing repo predates the module)
The `vidcast-frontend` ECR repo already exists; import it so `apply` doesn't fail
with "already exists":
```bash
terraform import 'module.ecr.aws_ecr_repository.this["vidcast-frontend"]' vidcast-frontend
```
> If the GitHub OIDC provider errors `EntityAlreadyExistsException` on apply, import it too:
> `terraform import module.github_oidc.aws_iam_openid_connect_provider.github arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com`

### 2.2 Apply (~20 min: EKS control plane)
```bash
terraform plan         # review — should show EKS + node group + ECR hardening deltas
terraform apply -auto-approve
```

### 2.3 Connect + confirm
```bash
aws eks update-kubeconfig --name vidcast-cluster --region eu-west-2
kubectl get nodes -o wide            # WAIT: 1 node Ready (~2-3 min after node group)
kubectl get nodes -o wide | grep -q ' Ready ' && echo "NODE READY ✓"

# Confirm the VPC-CNI network-policy AGENT is on (A6 — else NetworkPolicies are decorative):
kubectl get ds aws-node -n kube-system -o jsonpath='{.spec.template.spec.containers[*].name}'; echo
#   expect to see 'aws-eks-nodeagent' alongside 'aws-node'

# Capture the deploy role ARN for CD (set this as the GitHub secret AWS_DEPLOY_ROLE_ARN):
terraform output github_actions_role_arn
terraform output external_secrets_irsa_role_arn   # used by the ESO ServiceAccount annotation
terraform output ecr_repository_urls
```

---

## 3. Helm installs — datastores (dependency order)

Order: **MongoDB → PostgreSQL → RabbitMQ** (the app needs all three; RabbitMQ also
creates `rabbitmq-secret` which gateway/converter/notification consume).

```bash
cd /home/john/microservices-python-app

helm install mongodb  Helm_charts/MongoDB
kubectl rollout status statefulset/mongodb --timeout=180s

helm install postgres Helm_charts/Postgres
kubectl rollout status deployment/postgres-deploy --timeout=120s

helm install rabbitmq Helm_charts/RabbitMQ
kubectl rollout status statefulset/rabbitmq --timeout=180s

kubectl get pods    # WAIT: mongodb-0, postgres-deploy-*, rabbitmq-0 all Running
```

### 3.1 PostgreSQL init — schema + admin seed (SKIPPING THIS = login fails)
`init.sql` creates the `auth_user` table and enables pgcrypto, but contains **no
password hash** (nothing secret in the repo). The admin is seeded separately, with
its bcrypt hash generated **inside** PostgreSQL from your env vars — so the plaintext
and the hash never touch a file. `deploy.sh` does both steps; by hand:
```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
PSQL="psql -h $NODE_IP -p 30003 -U $POSTGRES_USERNAME -d authdb -v ON_ERROR_STOP=1"

# 1) schema (table + pgcrypto extension)
PGPASSWORD="$POSTGRES_PASSWORD" $PSQL -f Helm_charts/Postgres/init.sql

# 2) seed the admin — bcrypt hash generated in-DB via pgcrypto (no hash in any file)
PGPASSWORD="$POSTGRES_PASSWORD" $PSQL -v email="$APP_LOGIN_EMAIL" -v pw="$APP_LOGIN_PASSWORD" <<'SQL'
INSERT INTO auth_user (email, password, role)
VALUES (:'email', crypt(:'pw', gen_salt('bf', 12)), 'admin')
ON CONFLICT (email) DO UPDATE SET password = EXCLUDED.password, role = EXCLUDED.role;
SQL

PGPASSWORD="$POSTGRES_PASSWORD" $PSQL -c "SELECT email, role FROM auth_user;"   # expect your admin row
```
> The DB/broker admin NodePorts (30003/30004/30005) are reachable until NetworkPolicies
> are applied in §8. Run DB init now, before the lockdown.

### 3.2 RabbitMQ queues
The converter declares the full retry/DLQ topology (`video`, `video.retry`,
`video.dlq`, `vidcast.dlx`, `mp3`…) on startup (A3), so no manual queue creation is
strictly required. Confirm after consumers are up (§5) via the management UI on
`:30004` or the verification in §7.

---

## 4. External Secrets Operator (A9) — after Parameter Store is seeded (§1.4)

```bash
helm repo add external-secrets https://charts.external-secrets.io && helm repo update
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace --version 0.14.0   # or later (CRDs serve external-secrets.io/v1)
kubectl rollout status deployment/external-secrets -n external-secrets --timeout=120s

# The vidcast-eso ServiceAccount must carry the IRSA role annotation. Confirm it matches TF:
kubectl apply -k k8s/external-secrets/shared        # SA + ClusterSecretStore
kubectl get sa vidcast-eso -n default -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'; echo
#   must equal `terraform output external_secrets_irsa_role_arn`

kubectl apply -k k8s/external-secrets/dev           # the 4 ExternalSecrets

# WAIT for ESO to materialize the Secrets:
kubectl get externalsecret -n default               # all READY=True
kubectl get secret auth-secret gateway-secret converter-secret notification-secret -n default
```
> `rabbitmq-secret` is created by the RabbitMQ Helm chart (§3), NOT by ESO — by design.

---

## 5. App workloads — Kustomize (dev overlay)

```bash
kubectl apply -k k8s/overlays/dev
for d in auth gateway converter notification frontend outbox-relay redis; do
  kubectl rollout status deployment/$d --timeout=180s
done
kubectl get pods -o wide                            # all Running, 0 restarts
```
> KEDA is not installed yet, so `converter` runs at its static floor (1 in dev).
> KEDA takes over the replica count in §6.

---

## 6. Platform tooling (in this order)

### 6.1 KEDA (A7 — scale-to-zero for the converter)
```bash
helm repo add kedacore https://kedacore.github.io/charts && helm repo update
helm install keda kedacore/keda -n keda --create-namespace -f k8s/keda/values.yaml
kubectl rollout status deployment/keda-operator -n keda --timeout=120s
kubectl apply -k k8s/keda                            # ScaledObject (converter) + HPA (gateway) + TriggerAuth
kubectl get scaledobject -n default                  # READY=True
```

### 6.2 Argo CD (B1 — GitOps)
```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
helm install argocd argo/argo-cd -n argocd --create-namespace -f k8s/argocd/values.yaml
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s
kubectl apply -k k8s/argocd                          # Application CRDs (dev auto-sync, prod manual-sync)
kubectl get applications -n argocd
```
> Argo syncs from the git repo, so the Sprint-1–4 manifests must be pushed to `main`
> (Part 1 #3). Until then the dev Application shows `OutOfSync`/`Unknown` — expected.

### 6.3 Kyverno (B2/B5 — policy-as-code, ALL Audit)
```bash
helm repo add kyverno https://kyverno.github.io/kyverno && helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace -f k8s/kyverno/values.yaml
kubectl rollout status deployment/kyverno-admission-controller -n kyverno --timeout=180s
kubectl apply -k k8s/kyverno                         # 7 ClusterPolicies (0 Enforce)
kubectl get clusterpolicy                            # all READY=True
```

### 6.4 Monitoring (B4 — Prometheus/Grafana/Alertmanager + SLO stack)
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update
helm install monitoring prometheus-community/kube-prometheus-stack \
  -f monitoring/values.yaml -n monitoring --create-namespace
kubectl rollout status deployment/monitoring-grafana -n monitoring --timeout=240s

kubectl apply -f monitoring/scrape/                  # ServiceMonitors + PodMonitors (gateway/rabbitmq/converter/notification/kubecost)
kubectl apply -f monitoring/alerts/vidcast-alerts.yaml
kubectl apply -f monitoring/alerts/vidcast-slo-rules.yaml

# Load dashboards (sidecar picks up ConfigMaps labelled grafana_dashboard=1):
for d in vidcast-operations vidcast-slo vidcast-finops; do
  kubectl create configmap $d -n monitoring --from-file=monitoring/dashboards/$d.json \
    --dry-run=client -o yaml | kubectl label -f - --local -o yaml grafana_dashboard=1 | kubectl apply -f -
done
```

### 6.5 Kubecost (B3 — LAST; dev footprint per the sign-off)
```bash
helm repo add kubecost https://kubecost.github.io/cost-analyzer/ && helm repo update
helm install kubecost kubecost/cost-analyzer -n kubecost --create-namespace -f k8s/kubecost/values.yaml
kubectl rollout status deployment/kubecost-cost-analyzer -n kubecost --timeout=240s
# (vidcast-kubecost ServiceMonitor was applied in §6.4)
```
> If the node shows pressure (Pending pods), park Kubecost and continue:
> `kubectl scale deploy/kubecost-cost-analyzer -n kubecost --replicas=0`

---

## 7. Runtime verification checklist

Run **every** item. Record command → output → PASS/FAIL in `DEPLOYMENT_REPORT.md`.

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
```

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 1 | Gateway boots under gunicorn | `kubectl exec deploy/gateway -- python -c "import urllib.request as u;print(u.urlopen('http://localhost:8080/healthz').read())"` | `{"status":"ok",...}` 200 |
| 2 | Gateway /metrics (B4) | `kubectl exec deploy/gateway -- python -c "import urllib.request as u;print(b'vidcast_gateway_requests_total' in u.urlopen('http://localhost:8080/metrics').read())"` | `True` |
| 3 | Converter/notification /metrics | `kubectl exec deploy/converter -- python -c "import urllib.request as u;print(u.urlopen('http://localhost:9000/metrics').status)"` | `200` |
| 4 | Outbox relay publishing | seed a row (below), then check the `video` queue depth on `:30004` | published count increments |
| 5 | DLQ topology (A3) | publish a poison msg to `video`; after MAX_RETRIES it lands in `video.dlq` | message in `video.dlq` |
| 6 | Idempotency (A2) | publish the same `video_fid` twice | 2nd logs `[idempotency] duplicate, skipping` |
| 7 | KEDA scale-to-zero | `kubectl get deploy converter -w` with empty queue | replicas → 0; →1+ on new msg |
| 8 | DNS resolves | `kubectl exec deploy/gateway -- python -c "import socket;print(socket.gethostbyname('rabbitmq'))"` | an IP |
| 9 | Prometheus targets UP | port-forward `:9090` → Status▸Targets | gateway/rabbitmq/converter/notification/kubecost UP |
| 10 | SLO rules evaluating | query `slo:availability:burnrate1h` in Prometheus | a series (after some traffic) |
| 11 | Kyverno PolicyReports | `kubectl get clusterpolicyreport` | pass/fail counts present |
| 12 | Argo CD UI | port-forward `argocd-server :8080`, login | app tree visible; dev=Synced |
| 13 | Argo dev auto-sync | edit a dev manifest in git, push | Argo auto-syncs the change |
| 14 | Argo prod manual-sync gate | inspect prod Application | `syncPolicy.automated` ABSENT |
| 15 | Kubecost data | port-forward `kubecost :9090` or check `node_total_hourly_cost` in Prometheus | a cost value |
| 16 | NetworkPolicy deny (after §10) | gateway→notification should TIME OUT; gateway→auth should CONNECT | see §10 |

**Helper — outbox relay test (item 4):**
```bash
kubectl exec deploy/gateway -- python - <<'PY'
import os, datetime, pymongo
c = pymongo.MongoClient(os.environ["MONGODB_VIDEOS_URI"])
c.get_default_database().outbox.insert_one({"event_type":"video.uploaded","routing_key":"video",
  "payload":{"video_fid":"test","mp3_fid":None,"username":"<YOUR_LOGIN_EMAIL>"},
  "created_at":datetime.datetime.utcnow(),"published_at":None})
print("seeded outbox row")
PY
# within OUTBOX_POLL_INTERVAL (30s): kubectl logs deploy/outbox-relay  -> "published 1 event(s)"
```

**Port-forwards for the platform tools (what each one shows you).**
A *port-forward* opens a private tunnel from a port on your laptop to a service
inside the cluster — most of these tools are deliberately **not** exposed publicly
(only the frontend `:30006`, gateway `:30002`, and Grafana `:30007` have NodePorts),
so port-forwarding is how an operator reaches them. Open `http://localhost:<port>` in
your browser after each. (Run with `&` to background them; `kill %1 %2 …` to stop.)

```bash
# ── PROMETHEUS (the metrics database) → http://localhost:9090 ──────────────────
# What it shows: every raw number the system emits. Use Status ▸ Targets to confirm
# all services are being scraped ("UP"), and the Graph tab to query metrics like
# `vidcast_conversions_total`, `rabbitmq_queue_messages`, or the SLO burn-rate rules.
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &

# ── ALERTMANAGER (the alert router) → http://localhost:9093 ───────────────────
# What it shows: which SLO/health alerts are currently FIRING and their grouping/
# silences. Quiet = healthy. This is where a burn-rate page would surface.
# (Also reachable directly on NodePort :30008 if the security group allows your IP.)
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 &

# ── GRAFANA (the dashboards) → http://localhost:3000  (or NodePort :30007) ─────
# What it shows: the human-friendly graphs — the 3 VidCast dashboards (Operations,
# SLO, FinOps/Cost) plus the stock Kubernetes ones. Login: admin / vidcast-demo.
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80 &

# ── KUBECOST (the cost breakdown) → http://localhost:9091 ─────────────────────
# What it shows: cost attributed per namespace/pod/label, and the cost-per-conversion
# figure. Remember it's an ESTIMATE (list prices) — use it for trends, the AWS bill
# for absolutes.
kubectl -n kubecost port-forward deploy/kubecost-cost-analyzer 9091:9090 &

# ── ARGO CD (the GitOps deployer) → https://localhost:8080 ────────────────────
# What it shows: the live sync state of the dev/prod Applications — Synced vs
# OutOfSync, the resource tree, and the manual "Sync" button that IS the prod gate.
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
# Argo CD admin password (user is `admin`):
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

**End-to-end app test (item — the headline):**
```bash
JWT=$(curl -s -X POST http://$NODE_IP:30002/login -u "<YOUR_LOGIN_EMAIL>:$APP_LOGIN_PASSWORD")
curl -s -X POST http://$NODE_IP:30002/upload -F "file=@assets/video.mp4" -H "Authorization: Bearer $JWT"
# wait ~30-60s for converter; an email is sent if the real Gmail app password is in Parameter Store
sleep 60
# download (FILE_ID from the email, or from gateway /my-files):
curl -s -X GET "http://$NODE_IP:30002/download?fid=<FILE_ID>" -H "Authorization: Bearer $JWT" -o out.mp3
file out.mp3        # expect: Audio file / MPEG ADTS
```

---

## 8. NetworkPolicies — APPLY LAST (after §7 all green)

Applied last so any unexpected block is unambiguously the policy. Allows first,
default-deny last (the file order already does this).
```bash
kubectl apply -k k8s/network-policies                         # default ns: allows + default-deny
kubectl apply -f k8s/network-policies/allow-kyverno-sigstore-egress.yaml   # kyverno ns (B5)

# Deny-test (verification item 16):
kubectl exec deploy/gateway -- python -c "import socket; socket.create_connection(('auth',5000),3); print('gateway->auth OK')"   # CONNECT
kubectl exec deploy/gateway -- timeout 5 python -c "import socket; socket.create_connection(('notification',9000),3)" ; echo "exit=$? (nonzero = correctly denied)"
kubectl exec deploy/gateway -- python -c "import socket; print(socket.gethostbyname('rabbitmq'))"   # DNS still works
```
> Rollback (fastest in the plan): `kubectl delete networkpolicy default-deny-all -n default`.

---

## 9. Teardown (cost saving)

```bash
# App + platform (Helm + kustomize) can be left; the destroy removes the cluster anyway.
cd terraform/environments/dev && terraform destroy -auto-approve     # ~10 min
# Verify zero spend:
aws eks list-clusters --region eu-west-2          # []
terraform state list                               # 0 resources
```
**PRESERVE (never delete):** S3 state bucket, DynamoDB lock table, `terraform.tfvars`,
`.terraform.lock.hcl`, the `vidcast-frontend` ECR repo+images. **Parameter Store**
SecureStrings are free and harmless to leave (they persist; ESO re-reads them next
bring-up) — delete only if rotating secrets. No Secrets Manager is used (cost decision).

---

## 10. Known issues / runtime gaps to watch (collected from all sprint review notes)

**Genuinely deferred (depend on CI — can't test until merged):**
- **Cosign signing / SBOM / SARIF / SLSA provenance (A8):** not in CI yet → **B5
  `verify-images` Audit report will show our images as "fail: no signature"** — this
  is the EXPECTED "not yet signed" state, not a failure. Flip B5 to Enforce only
  after signing is live and one image verifies PASS (`k8s/kyverno/README.md` §B5).

**Verify-on-this-deploy (the point of the bring-up):**
- **Datastore non-root (gap-fix):** RabbitMQ now runs non-root (uid 999 + fsGroup) —
  confirm it boots against the existing PVC. mongo/postgres CANNOT run non-root
  (documented Kyverno `require-non-root` exception) — confirm they still start.
- **postgres:16.4-alpine** (was implicit `:latest`) — confirm init.sql + `HOST_AUTH_METHOD`.
- **RabbitMQ `/metrics/per-object`** (B4) — confirm `rabbitmq_queue_messages{queue="video"}`
  appears (the two RabbitMQ alerts depend on it).
- **gunicorn multiprocess metrics (B4)** — confirm `/metrics` aggregates across both
  gateway workers (counts shouldn't halve between scrapes).
- **Kubecost vs external Prometheus** — confirm the FQDN resolves and cost series populate.

**Carried operational notes:**
- NodePort SG: 30003/30004/30005/30007/30008 should be locked to the operator IP;
  30002 (gateway) + 30006 (frontend) stay public. (SG module / manual.)
- Kyverno Audit→Enforce is a deliberate later step: 5/6 policies are clean post
  gap-fix; `require-non-root` needs a label-scoped exclude for mongo/postgres first.
- Node budget: dev footprint + all add-ons ≈ **~81% idle**; converter 2nd replica at
  peak is best-effort (may stay Pending) — by design on a 2-vCPU node.

---

## 11. History (condensed)

- **May–Jun 1:** base deploy (hand-built `cba-microservices`, since torn down) →
  Terraform IaC (`vidcast-cluster`) + GitHub OIDC + state backend created.
- **Jun 2:** full app live on `vidcast-cluster`; images `<YOUR_DOCKERHUB_USER>/*:16f49a0`;
  Mongo 4.0.8→4.2; RBAC + frontend (ECR `vidcast-frontend`) merged (PR #1/#2).
- **Jun 3:** `terraform destroy` (cost saving) — 22 resources destroyed, state
  emptied, backend+ECR+tfvars preserved.
- **Jun 6–8 (Sprint 1–4):** Kustomize+ESO+KEDA+Argo+Kyverno+NetworkPolicies+outbox/
  idempotency/DLQ (A-series); B4 SLO alerting, A8 supply-chain, B5 cosign verify,
  B3 Kubecost. All config-verified; this runbook brings them up live.
```
