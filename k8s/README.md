# k8s/ — Application manifests (Kustomize)

VidCast's five application workloads (auth, gateway, converter, notification,
frontend) are managed with **Kustomize**: a shared `base/` plus per-environment
`overlays/`. This replaces the old raw per-service manifests under
`src/<service>/manifest/` and is the structure Argo CD (Phase Up B1) syncs from.

> **Scope.** This tree covers the *application* services only. The stateful
> backends (MongoDB, PostgreSQL, RabbitMQ) remain Helm charts under
> `Helm_charts/` (they are `dev-only` infra; see `MANAGED_SERVICES.md` for the
> managed-service alternatives and why they are documented-but-not-applied).
> Kubernetes **Secrets are not in this tree** — see "Secrets" below.

## Layout

```
k8s/
├── base/
│   ├── auth/          deployment + service (ClusterIP :5000) + configmap
│   ├── gateway/       deployment + service (NodePort :30002) + configmap
│   ├── converter/     deployment + configmap        (queue consumer, no Service)
│   ├── notification/  deployment + configmap        (queue consumer, no Service)
│   └── frontend/      deployment + service (NodePort :30006) + configmap
└── overlays/
    ├── dev/           1 replica per backend; lighter footprint  (Argo auto-sync ON)
    └── prod/          mirrors current live footprint (2/2/2/2/1) (Argo auto-sync OFF)
```

Each `base/<service>/` has its own `kustomization.yaml` so a service can become an
independent Argo CD `Application` later. Each overlay references all five bases
and applies environment-specific transforms (image tags, replica counts, and the
governance labels).

## Deploy

```bash
# 1. Secrets first — NOT in the Kustomize tree (see below):
kubectl apply -f ../src/auth-service/manifest/secret.yaml
kubectl apply -f ../src/gateway-service/manifest/secret.yaml
kubectl apply -f ../src/converter-service/manifest/secret.yaml
kubectl apply -f ../src/notification-service/manifest/secret.yaml
#   (rabbitmq-secret is created by the RabbitMQ Helm chart)

# 2. Render to check what you're about to apply:
kubectl kustomize overlays/prod          # or overlays/dev

# 3. Apply:
kubectl apply -k overlays/prod           # or overlays/dev
```

Teardown: `kubectl delete -k overlays/<env>` (match what you deployed).

## What the overlays change

| Transform | dev | prod |
|---|---|---|
| Replicas (auth/gateway/converter/notification) | 1 each | 2 each (base) |
| Frontend replicas | 1 | 1 |
| `environment` label | `dev` | `prod` |
| Governance labels (`cost-centre`, `owner`, `app.kubernetes.io/managed-by`) | yes | yes |
| Backend image tags | `images:` block | `images:` block |
| Frontend image | resolved to account ECR via `images:` `newName`/`newTag` | same |

The governance labels (`environment`, `cost-centre`, `owner`,
`app.kubernetes.io/managed-by`) are what the Kyverno `require-labels` policy
(B2) enforces. `app.kubernetes.io/managed-by` is `kustomize` today and flips to
`argocd` when B1 lands.

## Image tags = the GitOps source of truth

Image versions are set in each overlay's `images:` block, **not** by
`kubectl set image`. Today the CD pipeline still patches the live Deployment
directly; under B1 the pipeline will instead open a PR bumping `newTag` here, and
the merge of that PR is the deploy. Backends are on Docker Hub
(`<YOUR_DOCKERHUB_USER>/<svc>-service`); the frontend is in this account's ECR (CI does
not build the frontend).

## Secrets

Secrets are intentionally **excluded** from Kustomize:
- `**/secret.yaml` is gitignored, so they must never be rendered from tracked
  files; and
- Phase Up **A9** replaces the manual `secret.yaml` files with **External
  Secrets Operator** (`ExternalSecret` → AWS Parameter Store). At that point a
  `secretstore`/`externalsecrets` component is added to this tree and the
  manual apply in step 1 goes away.

`secret.yaml.example` templates still live under `src/<service>/manifest/` and
document the required keys.

## Validation

```bash
kubectl kustomize overlays/dev  >/dev/null && echo "dev  OK"
kubectl kustomize overlays/prod >/dev/null && echo "prod OK"
```

`prod` is intended to render equivalent to the pre-Kustomize raw manifests apart
from three deliberate additions: the governance labels, `namespace: default`, and
the resolved frontend image. `kubectl apply -k` is also run with
`--dry-run=server` in CI before a real apply.
