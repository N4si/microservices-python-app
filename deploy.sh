#!/usr/bin/env bash
# =============================================================================
# deploy.sh — VidCast automated bring-up
# =============================================================================
# Takes the cluster from "Terraform applied, node Ready" to "everything live and
# verified". This automates §3–§8 of DEPLOYMENT_GUIDE.md so you don't have to
# copy-paste the runbook. (§0–§2 — AWS prerequisites + `terraform apply` — are
# still run by hand because they create account-level infrastructure.)
#
# WHAT IT DOES, IN ORDER (each step waits for readiness before the next):
#   1. Validate prerequisites (cluster reachable, tools present, env vars set)
#   2. Datastores via Helm:  MongoDB -> PostgreSQL -> RabbitMQ
#   3. PostgreSQL init.sql (RBAC schema + bcrypt admin seed)
#   4. Seed AWS Parameter Store (the 7 SecureString secrets)
#   5. External Secrets Operator + the 4 ExternalSecrets (pull secrets into the cluster)
#   6. App workloads (kubectl apply -k <overlay>)
#   7. KEDA   (converter scale-to-zero) + gateway HPA + metrics-server
#   8. Argo CD (GitOps; dev auto-sync / prod manual gate)
#   9. Kyverno (policy-as-code, all Audit)
#  10. Monitoring (kube-prometheus-stack + scrape configs + alerts + SLO rules + dashboards)
#  11. Kubecost (FinOps; pinned to a stable chart)
#  12. NetworkPolicies (allows first, default-deny LAST)
#  13. Smoke test + print access URLs
#
# IDEMPOTENT: uses `helm upgrade --install` and `kubectl apply`, so re-running is
# safe and just reconciles to the desired state.
#
# USAGE:
#   ./deploy.sh                 # bring up (reads config from env vars / DEPLOYMENT_CONFIG)
#   ./deploy.sh --teardown      # terraform destroy + confirm zero spend
#   ./deploy.sh --help
#
# CONFIG (env vars; required ones are validated up front):
#   POSTGRES_USERNAME POSTGRES_PASSWORD
#   MONGODB_USERNAME  MONGODB_PASSWORD
#   RABBITMQ_PASSWORD (RABBITMQ_USERNAME optional, default 'rabbituser')
#   JWT_SECRET
#   GMAIL_ADDRESS     GMAIL_APP_PASSWORD
#   APP_LOGIN_EMAIL   APP_LOGIN_PASSWORD     (used to seed the admin login + the login smoke test)
#   DOCKER_HUB_USER                          (informational; image names live in the overlay)
#   ENVIRONMENT       (dev|prod, default: dev)
#   AWS_REGION        (default: eu-west-2)
#   NODE_IP           (optional — auto-detected from the node's ExternalIP)
#
#   Secrets are NOT stored in any tracked file: DB passwords are injected into the
#   Helm charts here via `--set` (the chart values hold CHANGEME placeholders), the
#   admin's bcrypt hash is generated in-DB, and JWT/Gmail go to Parameter Store.
#   Run ./customise.sh first to set identity (Docker Hub user / AWS account / GitHub
#   repo), then source your config into the shell and run this.
# =============================================================================

set -euo pipefail

# ── Locate the repo root (so the script works from anywhere) ─────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# ── Defaults ─────────────────────────────────────────────────────────────────
ENVIRONMENT="${ENVIRONMENT:-dev}"
AWS_REGION="${AWS_REGION:-eu-west-2}"
OVERLAY="k8s/overlays/${ENVIRONMENT}"
KUBECOST_CHART_VERSION="2.8.6"   # 2.9.x is a broken transitional chart — pin stable

# ── Pretty output helpers ────────────────────────────────────────────────────
c_reset=$'\e[0m'; c_blue=$'\e[34m'; c_green=$'\e[32m'; c_yellow=$'\e[33m'; c_red=$'\e[31m'; c_bold=$'\e[1m'
step()  { echo; echo "${c_blue}${c_bold}▶ $*${c_reset}"; }
ok()    { echo "  ${c_green}✓${c_reset} $*"; }
warn()  { echo "  ${c_yellow}!${c_reset} $*"; }
die()   { echo "${c_red}${c_bold}✗ $*${c_reset}" >&2; exit 1; }

# =============================================================================
# TEARDOWN  (./deploy.sh --teardown)
# =============================================================================
teardown() {
  step "TEARDOWN — destroying all AWS infrastructure (this stops the billing)"
  warn "This runs 'terraform destroy'. The EKS cluster, node, VPC, etc. are deleted."
  read -r -p "  Type 'destroy' to confirm: " confirm
  [ "$confirm" = "destroy" ] || die "Aborted (you did not type 'destroy')."
  ( cd terraform/environments/dev && terraform destroy -auto-approve )
  step "Verifying zero spend"
  if [ "$(aws eks list-clusters --region "$AWS_REGION" --query 'length(clusters)' --output text 2>/dev/null || echo '?')" = "0" ]; then
    ok "No EKS clusters remain — standing cost is now ~\$0."
  else
    warn "EKS clusters still listed — check 'aws eks list-clusters --region $AWS_REGION'."
  fi
  echo
  echo "Preserved (free to keep; makes the next bring-up one command):"
  echo "  • S3 Terraform state bucket + DynamoDB lock table"
  echo "  • terraform.tfvars, .terraform.lock.hcl"
  echo "  • Parameter Store SecureStrings, frontend ECR images"
  exit 0
}

[ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] && { sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
[ "${1:-}" = "--teardown" ] && teardown

# =============================================================================
# STEP 1 — VALIDATE PREREQUISITES  (fail early, with a clear list)
# =============================================================================
step "1/13  Validating prerequisites"

# 1a. tools on PATH
for t in kubectl helm aws psql; do
  command -v "$t" >/dev/null 2>&1 || die "Required tool not found on PATH: $t  (see DEPLOYMENT_GUIDE.md §A.1)"
done
ok "tools present: kubectl, helm, aws, psql"

# 1b. cluster reachable
kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster. Run: aws eks update-kubeconfig --name <cluster> --region $AWS_REGION"
if ! kubectl get nodes 2>/dev/null | grep -q ' Ready '; then
  die "No node is Ready yet. Wait for the node group, then re-run. (kubectl get nodes)"
fi
ok "cluster reachable; at least one node Ready"

# RabbitMQ creds (the chart provisions the broker with these; the app reads them
# from the chart-created rabbitmq-secret). Username defaults; password is required.
RABBITMQ_USERNAME="${RABBITMQ_USERNAME:-rabbituser}"

# 1c. required env vars (collect ALL missing, then fail once with the full list).
# NOTE: for an EXISTING cluster these must match the passwords the databases were
# first created with — Mongo/Postgres set the root password at init only, so a
# changed value would leave the app unable to authenticate. For a fresh cluster,
# any strong values work (e.g. `openssl rand -base64 24`).
REQUIRED=(POSTGRES_USERNAME POSTGRES_PASSWORD MONGODB_USERNAME MONGODB_PASSWORD RABBITMQ_PASSWORD JWT_SECRET GMAIL_ADDRESS GMAIL_APP_PASSWORD)
missing=()
for v in "${REQUIRED[@]}"; do [ -n "${!v:-}" ] || missing+=("$v"); done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "${c_red}  Missing required environment variables:${c_reset}"
  for m in "${missing[@]}"; do echo "    - $m"; done
  echo "  Set them (e.g. source the values from DEPLOYMENT_CONFIG.md) and re-run."
  die "Cannot continue without the secrets above."
fi
ok "all required secrets are set"

# 1d. auto-detect NODE_IP if not provided
NODE_IP="${NODE_IP:-$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)}"
[ -n "$NODE_IP" ] && ok "NODE_IP = $NODE_IP" || warn "could not auto-detect NODE_IP (NodePort smoke tests will be skipped)"

ok "environment = ${ENVIRONMENT}   region = ${AWS_REGION}   overlay = ${OVERLAY}"

# small helper: wait for a rollout, tolerating 'not found yet'
wait_rollout() { # $1=kind/name  $2=namespace  $3=timeout
  kubectl rollout status "$1" -n "${2:-default}" --timeout="${3:-180s}" 2>/dev/null \
    || warn "rollout wait for $1 timed out or not found (continuing — check manually)"
}

# =============================================================================
# STEP 2 — DATASTORES (Helm, in dependency order: Mongo -> Postgres -> RabbitMQ)
# =============================================================================
# Order matters: the app needs all three, and RabbitMQ's chart creates the
# 'rabbitmq-secret' that gateway/converter/notification consume.
step "2/13  Installing datastores (MongoDB → PostgreSQL → RabbitMQ)"
# Credentials are injected here via --set from env vars, NOT stored in the chart
# values (which carry CHANGEME placeholders) — so no DB password lives in the repo.

helm upgrade --install mongodb Helm_charts/MongoDB \
  --set secret.root_username="$MONGODB_USERNAME" --set secret.username="$MONGODB_USERNAME" \
  --set secret.users_list="$MONGODB_USERNAME" \
  --set secret.root_password="$MONGODB_PASSWORD" --set secret.password="$MONGODB_PASSWORD" >/dev/null
wait_rollout statefulset/mongodb default 180s; ok "MongoDB ready"

helm upgrade --install postgres Helm_charts/Postgres \
  --set container.env.user="$POSTGRES_USERNAME" --set container.env.password="$POSTGRES_PASSWORD" >/dev/null
wait_rollout deployment/postgres-deploy default 120s; ok "PostgreSQL ready"

helm upgrade --install rabbitmq Helm_charts/RabbitMQ \
  --set secret.default_user="$RABBITMQ_USERNAME" --set secret.default_pass="$RABBITMQ_PASSWORD" >/dev/null
wait_rollout statefulset/rabbitmq default 180s; ok "RabbitMQ ready"

# =============================================================================
# STEP 3 — PostgreSQL init (RBAC schema + bcrypt admin seed)
# =============================================================================
# Skipping this = every login 500s (no auth_user table / no admin row). The DB
# admin NodePort :30003 is still open here (NetworkPolicies are applied last).
step "3/13  Initialising PostgreSQL (schema, then admin seed)"
if [ -n "$NODE_IP" ]; then
  PSQL=(psql -h "$NODE_IP" -p 30003 -U "$POSTGRES_USERNAME" -d authdb -v ON_ERROR_STOP=1)
  if PGPASSWORD="$POSTGRES_PASSWORD" "${PSQL[@]}" -f Helm_charts/Postgres/init.sql >/dev/null 2>&1; then
    ok "schema applied (auth_user table + pgcrypto)"
    # Seed the admin with a bcrypt hash generated IN the database (pgcrypto), so no
    # password or hash is ever written to a file. Needs APP_LOGIN_EMAIL + _PASSWORD.
    if [ -n "${APP_LOGIN_EMAIL:-}" ] && [ -n "${APP_LOGIN_PASSWORD:-}" ]; then
      if PGPASSWORD="$POSTGRES_PASSWORD" "${PSQL[@]}" \
           -v email="$APP_LOGIN_EMAIL" -v pw="$APP_LOGIN_PASSWORD" >/dev/null 2>&1 <<'SQL'
INSERT INTO auth_user (email, password, role)
VALUES (:'email', crypt(:'pw', gen_salt('bf', 12)), 'admin')
ON CONFLICT (email) DO UPDATE SET password = EXCLUDED.password, role = EXCLUDED.role;
SQL
      then ok "admin seeded: ${APP_LOGIN_EMAIL} (bcrypt hash generated in-DB)"
      else warn "admin seed failed (is pgcrypto available in this postgres image?)."
      fi
    else
      warn "APP_LOGIN_EMAIL/APP_LOGIN_PASSWORD not set — no admin seeded, login won't work until you seed one."
    fi
  else
    warn "schema init failed (port 30003 reachable? credentials match?). Re-run by hand if needed."
  fi
else
  warn "NODE_IP unknown — skipping DB init. Run it manually per DEPLOYMENT_GUIDE.md §3.1."
fi

# =============================================================================
# STEP 4 — SEED AWS PARAMETER STORE (the 7 SecureString secrets)
# =============================================================================
# The app never reads these from a file — ESO (step 5) pulls them at runtime.
# Parameter Store = the safe-deposit box; the app holds the key (its AWS identity).
step "4/13  Seeding Parameter Store (/vidcast/${ENVIRONMENT}/*)"
put() { aws ssm put-parameter --region "$AWS_REGION" --type SecureString --overwrite --name "$1" --value "$2" >/dev/null; }
P="/vidcast/${ENVIRONMENT}"
put "$P/auth/psql-password"         "$POSTGRES_PASSWORD"
put "$P/auth/jwt-secret"            "$JWT_SECRET"
put "$P/gateway/mongodb-videos-uri" "mongodb://$MONGODB_USERNAME:$MONGODB_PASSWORD@mongodb:27017/videos?authSource=admin"
put "$P/gateway/mongodb-mp3s-uri"   "mongodb://$MONGODB_USERNAME:$MONGODB_PASSWORD@mongodb:27017/mp3s?authSource=admin"
put "$P/converter/mongodb-uri"      "mongodb://$MONGODB_USERNAME:$MONGODB_PASSWORD@mongodb:27017/mp3s?authSource=admin"
put "$P/notification/gmail-address" "$GMAIL_ADDRESS"
put "$P/notification/gmail-password" "${GMAIL_APP_PASSWORD// /}"   # strip any spaces from the app password
ok "7 SecureString parameters written under $P"

# =============================================================================
# STEP 5 — EXTERNAL SECRETS OPERATOR + the 4 ExternalSecrets
# =============================================================================
step "5/13  Installing External Secrets Operator + ExternalSecrets"
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null 2>&1 || true
# 0.18.2+ serves the external-secrets.io/v1 API the manifests use.
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace --version 0.18.2 >/dev/null
wait_rollout deployment/external-secrets external-secrets 150s
ok "ESO installed"

# Best-effort: stamp the IRSA role ARN onto the ESO ServiceAccount from terraform output.
if IRSA_ARN="$(cd terraform/environments/dev 2>/dev/null && terraform output -raw external_secrets_irsa_role_arn 2>/dev/null)"; then
  [ -n "$IRSA_ARN" ] && warn "ESO IRSA role: $IRSA_ARN (ensure shared/serviceaccount.yaml matches)"
fi

kubectl apply -k k8s/external-secrets/shared          >/dev/null   # SA + ClusterSecretStore
kubectl apply -k "k8s/external-secrets/${ENVIRONMENT}" >/dev/null   # the 4 ExternalSecrets
ok "applied ClusterSecretStore + ExternalSecrets"

# Wait for ESO to materialise the 4 Secrets (READY=True on each ExternalSecret).
step "    waiting for ExternalSecrets to sync (auth/gateway/converter/notification)"
for es in auth-secret gateway-secret converter-secret notification-secret; do
  if kubectl wait --for=condition=Ready "externalsecret/$es" -n default --timeout=120s >/dev/null 2>&1; then
    ok "$es synced"
  else
    warn "$es NOT ready — check the IRSA annotation on sa/vidcast-eso and the parameter paths."
  fi
done

# =============================================================================
# STEP 6 — APP WORKLOADS (Kustomize overlay)
# =============================================================================
step "6/13  Deploying app workloads (kubectl apply -k ${OVERLAY})"
kubectl apply -k "$OVERLAY" >/dev/null
for d in auth gateway converter notification frontend outbox-relay redis; do
  wait_rollout "deployment/$d" default 180s
done
ok "app workloads applied"

# =============================================================================
# STEP 7 — KEDA + HPA + metrics-server
# =============================================================================
# KEDA scales the converter on queue depth (to zero when idle). The gateway HPA
# scales on CPU, which needs metrics-server (EKS doesn't bundle it).
step "7/13  Installing KEDA + metrics-server + autoscalers"
helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo update kedacore >/dev/null 2>&1 || true
helm upgrade --install keda kedacore/keda -n keda --create-namespace -f k8s/keda/values.yaml >/dev/null
wait_rollout deployment/keda-operator keda 150s

# metrics-server (idempotent apply of the upstream manifest)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml >/dev/null 2>&1 || true

# KEDA's RabbitMQ scaler needs a connection-string Secret. It dials from the 'keda'
# namespace, so the host MUST be the FQDN (the short name 'rabbitmq' won't resolve
# cross-namespace). Build it from the RabbitMQ chart's credentials.
RMQ_USER="$(kubectl get secret rabbitmq-secret -n default -o jsonpath='{.data.RABBITMQ_DEFAULT_USER}' 2>/dev/null | base64 -d || true)"
RMQ_PASS="$(kubectl get secret rabbitmq-secret -n default -o jsonpath='{.data.RABBITMQ_DEFAULT_PASS}' 2>/dev/null | base64 -d || true)"
if [ -n "$RMQ_USER" ] && [ -n "$RMQ_PASS" ]; then
  kubectl create secret generic keda-rabbitmq-secret -n default \
    --from-literal=host="amqp://${RMQ_USER}:${RMQ_PASS}@rabbitmq.default.svc.cluster.local:5672/" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "keda-rabbitmq-secret created (FQDN host)"
else
  warn "could not read rabbitmq-secret — apply k8s/keda/secret.yaml manually before the ScaledObject works."
fi
kubectl apply -k k8s/keda >/dev/null   # ScaledObject + HPA + TriggerAuthentication
ok "KEDA ScaledObject + gateway HPA applied"

# =============================================================================
# STEP 8 — ARGO CD (GitOps)
# =============================================================================
step "8/13  Installing Argo CD + Applications"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null 2>&1 || true
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace -f k8s/argocd/values.yaml >/dev/null
wait_rollout deployment/argocd-server argocd 180s
kubectl apply -k k8s/argocd >/dev/null   # dev (auto-sync) + prod (manual gate) Applications
ok "Argo CD installed; dev auto-syncs, prod waits for manual Sync"

# =============================================================================
# STEP 9 — KYVERNO (policy-as-code, all Audit)
# =============================================================================
step "9/13  Installing Kyverno + ClusterPolicies (Audit)"
helm repo add kyverno https://kyverno.github.io/kyverno >/dev/null 2>&1 || true
helm repo update kyverno >/dev/null 2>&1 || true
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace -f k8s/kyverno/values.yaml >/dev/null
wait_rollout deployment/kyverno-admission-controller kyverno 180s
kubectl apply -k k8s/kyverno >/dev/null
ok "7 ClusterPolicies applied (all Audit)"

# =============================================================================
# STEP 10 — MONITORING (Prometheus / Grafana / Alertmanager + SLO stack)
# =============================================================================
# Uses an emptyDir override because this cluster has no dynamic EBS provisioner.
step "10/13  Installing monitoring stack + dashboards"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null 2>&1 || true
EMPTYDIR_OVERRIDE=""
[ -f monitoring/values-emptydir.yaml ] && EMPTYDIR_OVERRIDE="-f monitoring/values-emptydir.yaml"
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -f monitoring/values.yaml $EMPTYDIR_OVERRIDE -n monitoring --create-namespace >/dev/null
wait_rollout deployment/monitoring-grafana monitoring 240s

kubectl apply -f monitoring/scrape/ >/dev/null 2>&1 || true            # ServiceMonitors + PodMonitors
kubectl apply -f monitoring/alerts/vidcast-alerts.yaml >/dev/null 2>&1 || true
kubectl apply -f monitoring/alerts/vidcast-slo-rules.yaml >/dev/null 2>&1 || true
for dash in vidcast-operations vidcast-slo vidcast-finops; do
  [ -f "monitoring/dashboards/$dash.json" ] || continue
  kubectl create configmap "$dash" -n monitoring --from-file="monitoring/dashboards/$dash.json" \
    --dry-run=client -o yaml | kubectl label -f - --local -o yaml grafana_dashboard=1 | kubectl apply -f - >/dev/null
done
ok "Prometheus + Grafana + Alertmanager + SLO rules + 3 dashboards"

# =============================================================================
# STEP 11 — KUBECOST (FinOps) — installed LAST (heaviest add-on; watch node pressure)
# =============================================================================
step "11/13  Installing Kubecost (FinOps)"
helm repo add kubecost https://kubecost.github.io/cost-analyzer/ >/dev/null 2>&1 || true
helm repo update kubecost >/dev/null 2>&1 || true
KC_LOCAL=""
[ -f k8s/kubecost/values-local.yaml ] && KC_LOCAL="-f k8s/kubecost/values-local.yaml"
helm upgrade --install kubecost kubecost/cost-analyzer --version "$KUBECOST_CHART_VERSION" \
  -n kubecost --create-namespace -f k8s/kubecost/values.yaml $KC_LOCAL >/dev/null
wait_rollout deployment/kubecost-cost-analyzer kubecost 240s
# If the node is under pressure (Pending pods), park Kubecost rather than fail the run.
if kubectl get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | grep -q .; then
  warn "Pending pods detected — node may be full. Consider scaling Kubecost to 0:"
  warn "  kubectl scale deploy/kubecost-cost-analyzer -n kubecost --replicas=0"
fi
ok "Kubecost installed (chart $KUBECOST_CHART_VERSION)"

# =============================================================================
# STEP 12 — NETWORK POLICIES (allows FIRST, default-deny LAST)
# =============================================================================
# Ordering matters: apply every 'allow' before the catch-all deny, so there's no
# window where traffic is dropped before its exception exists.
step "12/13  Applying NetworkPolicies (allows first, default-deny last)"
kubectl apply -f k8s/network-policies/allow-dns.yaml \
               -f k8s/network-policies/allow-monitoring.yaml \
               -f k8s/network-policies/app-policies.yaml \
               -f k8s/network-policies/datastore-policies.yaml >/dev/null
kubectl apply -f k8s/network-policies/allow-kyverno-sigstore-egress.yaml >/dev/null 2>&1 || true
kubectl apply -f k8s/network-policies/default-deny.yaml >/dev/null   # LAST
ok "default-deny in force with allow-list exceptions"

# =============================================================================
# STEP 13 — SMOKE TEST + ACCESS URLS
# =============================================================================
step "13/13  Smoke test"
PASS=0; TOTAL=0
check() { TOTAL=$((TOTAL+1)); if eval "$2" >/dev/null 2>&1; then PASS=$((PASS+1)); ok "$1"; else warn "$1 — FAILED"; fi; }

check "gateway /healthz returns ok" \
  "kubectl exec -n default deploy/gateway -- python -c \"import urllib.request as u,sys; sys.exit(0 if b'ok' in u.urlopen('http://localhost:8080/healthz').read() else 1)\""
check "in-cluster DNS resolves (gateway → rabbitmq)" \
  "kubectl exec -n default deploy/gateway -- python -c \"import socket; socket.gethostbyname('rabbitmq')\""
if [ -n "${APP_LOGIN_PASSWORD:-}" ] && [ -n "$NODE_IP" ]; then
  LOGIN_EMAIL="${APP_LOGIN_EMAIL:-$GMAIL_ADDRESS}"
  check "login returns a JWT (${LOGIN_EMAIL})" \
    "[ \$(curl -s -m 15 -o /dev/null -w '%{http_code}' -X POST http://$NODE_IP:30002/login -u \"${LOGIN_EMAIL}:${APP_LOGIN_PASSWORD}\") = 200 ]"
else
  warn "skipping login check (set APP_LOGIN_PASSWORD + ensure NODE_IP to enable it)"
fi

echo
echo "${c_bold}Deploy complete. ${PASS}/${TOTAL} smoke checks passed.${c_reset}"

# ── Access URLs + port-forwards ──────────────────────────────────────────────
echo
echo "${c_bold}Access URLs${c_reset} (NodePorts — need the security group to allow your IP):"
if [ -n "$NODE_IP" ]; then
  echo "  Frontend (web UI):   http://$NODE_IP:30006"
  echo "  Gateway  (API):      http://$NODE_IP:30002"
  echo "  Grafana  (dashboards): http://$NODE_IP:30007   (admin / vidcast-demo)"
else
  echo "  (NODE_IP unknown — find it: kubectl get nodes -o wide)"
fi
echo
echo "${c_bold}Port-forwards${c_reset} (for tools not exposed publicly — open localhost in a browser):"
echo "  Prometheus:   kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090   # http://localhost:9090"
echo "  Alertmanager: kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 # http://localhost:9093"
echo "  Kubecost:     kubectl -n kubecost   port-forward deploy/kubecost-cost-analyzer 9091:9090               # http://localhost:9091"
echo "  Argo CD:      kubectl -n argocd     port-forward svc/argocd-server 8080:443                            # https://localhost:8080"
echo
echo "Tear it all down when finished:  ./deploy.sh --teardown"
