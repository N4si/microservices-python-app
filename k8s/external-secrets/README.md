# k8s/external-secrets/ — External Secrets Operator (A9)

Replaces the manual, gitignored `secret.yaml` files as the source of truth for
VidCast's application secrets. Secrets live in **AWS SSM Parameter Store** and are
pulled into the cluster by the **External Secrets Operator (ESO)** via IRSA — no
long-lived AWS keys, no secrets in git.

**Why Parameter Store, not Secrets Manager:** Secrets Manager bills
$0.40/secret/month (≈$3/mo for our 7 values, and it persists even when the
cluster is destroyed). Standard-tier SSM parameters are **free**, and
`SecureString` uses the **free** AWS-managed `alias/aws/ssm` key. This keeps the
project's "~$0 when the cluster is off" target. ESO supports both backends; the
only difference is `service: ParameterStore` in the ClusterSecretStore.

## Components

| File | Purpose |
|---|---|
| `shared/serviceaccount.yaml` | `vidcast-eso` SA, annotated with the IRSA role ARN (Terraform `external_secrets_irsa_role_arn`) |
| `shared/cluster-secret-store.yaml` | `ClusterSecretStore` → Parameter Store, eu-west-2, auth via the SA |
| `dev/`, `prod/` | One `ExternalSecret` per service; each writes the Secret the Deployment consumes (`auth-secret`, `gateway-secret`, `converter-secret`, `notification-secret`) |

## Prerequisites (one-time per cluster)

1. **Apply the IRSA role** (part of the Terraform stack):
   ```bash
   cd terraform/environments/dev && terraform apply   # creates *-external-secrets-irsa
   ```
   Confirm the SA annotation matches the output:
   ```bash
   terraform output external_secrets_irsa_role_arn
   ```

2. **Install ESO** (pin a chart version whose CRDs serve `external-secrets.io/v1`
   — that is **>= 0.14**; check with `helm search repo … --versions`):
   ```bash
   helm repo add external-secrets https://charts.external-secrets.io
   helm repo update
   helm install external-secrets external-secrets/external-secrets \
     -n external-secrets --create-namespace \
     --version 0.14.0          # or later; CRDs install by default on recent charts
   ```

## Seed the parameters

Values are read from environment variables so **no secret is ever written to a
tracked file**. Source them from the gitignored `DEPLOYMENT_CONFIG.md` first.
`prod` shown; for `dev` swap the path prefix to `/vidcast/dev/`.

```bash
REGION=eu-west-2
put() { aws ssm put-parameter --region "$REGION" --type SecureString --overwrite --name "$1" --value "$2"; }

# auth
put /vidcast/prod/auth/psql-password         "$POSTGRES_PASSWORD"
put /vidcast/prod/auth/jwt-secret            "$JWT_SECRET"
# gateway (full Mongo URIs, user+pass embedded)
put /vidcast/prod/gateway/mongodb-videos-uri "mongodb://$MONGODB_USERNAME:$MONGODB_PASSWORD@mongodb:27017/videos?authSource=admin"
put /vidcast/prod/gateway/mongodb-mp3s-uri   "mongodb://$MONGODB_USERNAME:$MONGODB_PASSWORD@mongodb:27017/mp3s?authSource=admin"
# converter
put /vidcast/prod/converter/mongodb-uri      "mongodb://$MONGODB_USERNAME:$MONGODB_PASSWORD@mongodb:27017/mp3s?authSource=admin"
# notification
put /vidcast/prod/notification/gmail-address "$GMAIL_ADDRESS"
put /vidcast/prod/notification/gmail-password "$GMAIL_APP_PASSWORD"   # strip spaces from the app password
```

## Deploy

```bash
# After ESO is installed and parameters are seeded:
kubectl apply -k k8s/external-secrets/prod      # or .../dev

# ESO reconciles each ExternalSecret into the named Secret. Verify:
kubectl get externalsecret -n default
#   NAME                  STORE                     READY
#   auth-secret           vidcast-parameter-store   True
#   ...
kubectl get secret auth-secret gateway-secret converter-secret notification-secret -n default
```

Then deploy the app (`kubectl apply -k k8s/overlays/prod`). The Deployments
reference these Secret names via `envFrom.secretRef`, unchanged — they neither
know nor care that ESO populated them.

## Rotation

Update the parameter (`put …` again) — ESO re-syncs within `refreshInterval`
(1h), or force it: `kubectl annotate externalsecret auth-secret force-sync=$(date +%s) --overwrite`.
Pods pick up the new value on their next restart (envFrom is read at start).

## What is NOT migrated here (honest scope)

`rabbitmq-secret` (broker credentials) is still created by the RabbitMQ **Helm
chart**, because that same secret provisions the in-cluster broker itself —
having ESO own it would make the dev broker depend on ESO being up first. Broker
credentials move to Parameter Store when the broker moves to **Amazon MQ**
(managed), which is documented-but-not-applied in `MANAGED_SERVICES.md`. The
parameter convention is reserved: `/vidcast/<env>/rabbitmq/{username,password}`.
