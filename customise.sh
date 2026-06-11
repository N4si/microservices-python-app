#!/usr/bin/env bash
# =============================================================================
# customise.sh — point VidCast at YOUR identity (Docker Hub / AWS / GitHub)
# =============================================================================
# Run this ONCE after forking, BEFORE ./deploy.sh. It rewrites the *identity*
# values in the repo's GitOps config so the cluster pulls YOUR images and Argo CD /
# AWS / Kyverno trust YOUR GitHub repo. It does NOT write any secret to a file —
# database passwords, the JWT secret, the Gmail password, and the admin's bcrypt
# hash are all handled at install time by deploy.sh (via `--set`, Parameter Store,
# and an in-database pgcrypto hash respectively).
#
# It does not hard-code anyone's values: it AUTO-DETECTS whatever identity is
# currently in the repo and replaces it with yours (from the env vars below).
#
# ── HOW TO GET EACH VALUE ────────────────────────────────────────────────────
#   DOCKER_HUB_USER   Your Docker Hub username — sign up free at hub.docker.com.
#                     The cluster pulls <user>/auth-service:<sha> etc.
#   AWS_ACCOUNT_ID    Run:  aws sts get-caller-identity --query Account --output text
#   GITHUB_ORG        Your GitHub username/org that owns the fork (github.com/<ORG>/<REPO>).
#   GITHUB_REPO       Your fork's repository name.
#   AWS_REGION        Your AWS region (default eu-west-2). Use one that allows
#                     non-T-type EKS nodes.
#   CLUSTER_NAME      Any name WITHOUT underscores (EKS rejects them); e.g. vidcast-cluster.
#   ECR_REPO_NAME     Name for the frontend image's ECR repo; e.g. vidcast-frontend.
#
# Anything left unset keeps the current value (a no-op for that field).
#
# USAGE:
#   export DOCKER_HUB_USER=... AWS_ACCOUNT_ID=... GITHUB_ORG=... GITHUB_REPO=...
#   ./customise.sh
# (Secrets for deploy.sh — POSTGRES_PASSWORD, MONGODB_PASSWORD, RABBITMQ_PASSWORD,
#  JWT_SECRET, GMAIL_ADDRESS, GMAIL_APP_PASSWORD, APP_LOGIN_EMAIL, APP_LOGIN_PASSWORD —
#  are NOT used here; set them in your shell before running ./deploy.sh.)
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

green=$'\e[32m'; yellow=$'\e[33m'; red=$'\e[31m'; reset=$'\e[0m'
upd()  { echo "  ${green}✓${reset} $*"; }
note() { echo "  ${yellow}!${reset} $*"; }

# ── Auto-detect the identity currently in the repo (no hard-coded values) ────
DEV_OVERLAY="k8s/overlays/dev/kustomization.yaml"
ARGO_APP="k8s/argocd/application-dev.yaml"

CUR_DOCKER_USER="$(grep -oE '[a-z0-9._-]+/auth-service' "$DEV_OVERLAY" 2>/dev/null | head -1 | cut -d/ -f1 || true)"
CUR_ACCOUNT_ID="$(grep -oE '[0-9]{12}' "$DEV_OVERLAY" 2>/dev/null | head -1 || true)"
CUR_ORG_REPO="$(grep -oE 'github\.com/[^/]+/[^/.]+' "$ARGO_APP" 2>/dev/null | head -1 | sed 's#github.com/##' || true)"
CUR_GITHUB_ORG="${CUR_ORG_REPO%%/*}"
CUR_GITHUB_REPO="${CUR_ORG_REPO##*/}"
CUR_REGION="$(grep -oE 'dkr\.ecr\.[a-z0-9-]+\.amazonaws' "$DEV_OVERLAY" 2>/dev/null | head -1 | sed -E 's/dkr\.ecr\.([a-z0-9-]+)\.amazonaws/\1/' || true)"
CUR_ECR_REPO="$(grep -oE 'amazonaws\.com/[a-z0-9-]+' "$DEV_OVERLAY" 2>/dev/null | head -1 | sed 's#amazonaws.com/##' || true)"
CUR_CLUSTER="$(grep -oE 'cluster_name[[:space:]]*=[[:space:]]*"[^"]+"' terraform/environments/dev/terraform.tfvars 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/' || true)"
: "${CUR_REGION:=eu-west-2}"; : "${CUR_CLUSTER:=vidcast-cluster}"; : "${CUR_ECR_REPO:=vidcast-frontend}"

# ── New values from env (default to current = no-op if unset) ────────────────
NEW_DOCKER_USER="${DOCKER_HUB_USER:-$CUR_DOCKER_USER}"
NEW_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$CUR_ACCOUNT_ID}"
NEW_GITHUB_ORG="${GITHUB_ORG:-$CUR_GITHUB_ORG}"
NEW_GITHUB_REPO="${GITHUB_REPO:-$CUR_GITHUB_REPO}"
NEW_REGION="${AWS_REGION:-$CUR_REGION}"
NEW_CLUSTER="${CLUSTER_NAME:-$CUR_CLUSTER}"
NEW_ECR_REPO="${ECR_REPO_NAME:-$CUR_ECR_REPO}"

echo "===== customise.sh — repointing identity to yours ====="
echo "  Docker Hub : ${CUR_DOCKER_USER:-?} -> $NEW_DOCKER_USER"
echo "  AWS acct   : ${CUR_ACCOUNT_ID:-?} -> $NEW_ACCOUNT_ID"
echo "  GitHub     : ${CUR_GITHUB_ORG:-?}/${CUR_GITHUB_REPO:-?} -> $NEW_GITHUB_ORG/$NEW_GITHUB_REPO"
echo "  Region     : ${CUR_REGION} -> $NEW_REGION   Cluster: ${CUR_CLUSTER} -> $NEW_CLUSTER   ECR: ${CUR_ECR_REPO} -> $NEW_ECR_REPO"
echo

repl() { # $1=file $2=from $3=to  (no-op if file missing, from empty, or unchanged)
  [ -f "$1" ] || return 0; [ -n "$2" ] || return 0; [ "$2" = "$3" ] && return 0
  sed -i "s|$2|$3|g" "$1"
}

# ── 1. Kustomize overlays — backend image names + frontend ECR ref ───────────
for ov in dev prod; do
  F="k8s/overlays/$ov/kustomization.yaml"
  repl "$F" "$CUR_DOCKER_USER/" "$NEW_DOCKER_USER/"
  repl "$F" "$CUR_ACCOUNT_ID.dkr.ecr.$CUR_REGION.amazonaws.com/$CUR_ECR_REPO" \
            "$NEW_ACCOUNT_ID.dkr.ecr.$NEW_REGION.amazonaws.com/$NEW_ECR_REPO"
  [ -f "$F" ] && upd "overlay $ov: image names + ECR ref"
done

# ── 2. Terraform variables (identity AWS trusts + builds) ────────────────────
F="terraform/environments/dev/terraform.tfvars"
if [ -f "$F" ]; then
  repl "$F" "\"$CUR_GITHUB_ORG\""  "\"$NEW_GITHUB_ORG\""
  repl "$F" "\"$CUR_GITHUB_REPO\"" "\"$NEW_GITHUB_REPO\""
  repl "$F" "\"$CUR_CLUSTER\""     "\"$NEW_CLUSTER\""
  repl "$F" "\"$CUR_REGION\""      "\"$NEW_REGION\""
  upd "terraform.tfvars: github_org/repo, cluster, region"
else
  note "terraform.tfvars not found (gitignored) — set github_org/github_repo/cluster_name/aws_region yourself."
fi

# ── 3. Argo CD Applications — the source repo Argo pulls from ─────────────────
for app in dev prod; do
  F="k8s/argocd/application-$app.yaml"
  repl "$F" "github.com/$CUR_GITHUB_ORG/$CUR_GITHUB_REPO" "github.com/$NEW_GITHUB_ORG/$NEW_GITHUB_REPO"
  [ -f "$F" ] && upd "argocd application-$app: repoURL"
done

# ── 4. Kyverno verify-images — the keyless cosign signer identity (B5) ───────
F="k8s/kyverno/verify-images.yaml"
repl "$F" "github.com/$CUR_GITHUB_ORG/$CUR_GITHUB_REPO/" "github.com/$NEW_GITHUB_ORG/$NEW_GITHUB_REPO/"
[ -f "$F" ] && upd "kyverno verify-images: cosign subject identity"

# ── Validation ───────────────────────────────────────────────────────────────
echo
echo "===== Validation ====="
if [ "$NEW_DOCKER_USER" = "$CUR_DOCKER_USER" ] && [ "$NEW_GITHUB_ORG" = "$CUR_GITHUB_ORG" ] && [ "$NEW_ACCOUNT_ID" = "$CUR_ACCOUNT_ID" ]; then
  note "No identity env vars set — nothing changed. Set DOCKER_HUB_USER / AWS_ACCOUNT_ID / GITHUB_ORG / GITHUB_REPO and re-run."
else
  LEFT="$(grep -rn "$CUR_DOCKER_USER/\|$CUR_ACCOUNT_ID\|github.com/$CUR_GITHUB_ORG/$CUR_GITHUB_REPO" \
    k8s/overlays k8s/argocd k8s/kyverno terraform/environments/dev/terraform.tfvars 2>/dev/null || true)"
  if [ -n "$LEFT" ]; then note "Some old identity values remain (review):"; echo "$LEFT" | sed 's/^/      /'
  else upd "no old identity values remain in the GitOps config"; fi
fi
echo
echo "Next: set your secrets in the shell, then run ./deploy.sh  (see DEPLOYMENT_GUIDE.md §A.2)."
echo "===== customise.sh complete ====="
