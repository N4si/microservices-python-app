# k8s/argocd — GitOps with Argo CD (B1)

Argo CD continuously reconciles the cluster to the manifests in
`k8s/overlays/{dev,prod}`. **dev auto-syncs; prod is manual-sync (the approval
gate).** Full design + the CD gate migration are in `GITOPS.md` (repo root).

## Install (applied separately, like ESO/KEDA — CRDs first)

```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
helm install argocd argo/argo-cd -n argocd --create-namespace -f k8s/argocd/values.yaml

# register the two Applications (these are argoproj.io CRDs → need Argo installed first)
kubectl apply -k k8s/argocd
```

## Access the UI (port-forward — not NodePort)

The Argo UI is an admin control plane, so it is **not** world-exposed via NodePort
(same posture as the RabbitMQ/DB admin ports under A6). Reach it with a port-forward:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# browse https://localhost:8080  (self-signed cert → accept the warning)
# initial admin password:
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

## Sync

```bash
kubectl get applications -n argocd                 # dev/prod status (Synced/OutOfSync/Health)
argocd app sync vidcast-prod                       # MANUAL prod sync = the deploy/approval action
# dev auto-syncs; to force: argocd app sync vidcast-dev
```

## ⚠️ Single-cluster caveat

`vidcast-dev` and `vidcast-prod` both target the `default` namespace on this one
cluster, so they manage the same-named resources. **Sync only ONE at a time** (dev
for validation, prod for the live footprint). Syncing both would make them fight
over the same Deployments. Multi-cluster would point each Application at a different
`destination.server`. Explained in `GITOPS.md`.

## What Argo manages vs what's manual

- **Argo manages:** the app workloads in `k8s/overlays/{dev,prod}` (Deployments,
  Services, ConfigMaps, and the ESO-created Secrets).
- **Manual / platform-owned (the operator):** Argo CD itself, KEDA, ESO, NetworkPolicies,
  Kyverno. Platform layer ≠ application layer. See `GITOPS.md`.

## Rollback

`git revert` the offending commit → Argo re-syncs to the previous state (dev
automatically; prod on the next manual sync). No `kubectl` needed.
