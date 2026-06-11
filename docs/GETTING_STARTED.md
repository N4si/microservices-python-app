# VidCast — Getting Started (Clone → Run → Teardown)

This is the complete, end-to-end walkthrough: everything from cloning the repo to a
working deployment on AWS EKS, and finally tearing it down so it stops costing money.
It is the operational companion to the high-level [`README.md`](../README.md) and the
narrative [`PROJECT_GUIDE.md`](PROJECT_GUIDE.md).

> **No secrets live in this repo.** Every credential (DB passwords, JWT secret, Gmail
> app password, AWS account ID) is supplied by *you* at deploy time through gitignored
> files and CI/CD secrets. Placeholders such as `<AWS_ACCOUNT_ID>`, `YOUR_STATE_BUCKET`,
> and `<BCRYPT_HASH_HERE>` mark every spot you must fill in.

---

## 0. What you need first

| Tool | Version | Notes |
|------|---------|-------|
| AWS CLI | v2 | `aws configure` with a user that can create EKS/VPC/IAM |
| kubectl | 1.31+ | |
| Helm | 3.x | |
| Terraform | 1.5+ | |
| Docker | 20+ | for building images locally |
| psql | any | PostgreSQL client, for seeding the auth DB |
| mongosh | 7.x | optional, for inspecting MongoDB |

On WSL2/Ubuntu you can install kubectl, Helm, Python, psql, mongosh and Terraform with:

```bash
./install_prerequisites.sh
```

AWS CLI and Docker are assumed already installed. Verify access before anything else:

```bash
aws sts get-caller-identity
```

> **Account constraint:** this AWS account's SCPs reject T-type instances (EKS auto-adds
> `CreditSpecification: unlimited`, which is denied). Use `m7i-flex.large` or any
> M/C/R-series type. The Terraform EKS module enforces this with a validation block.

---

## 1. Clone

```bash
git clone https://github.com/<YOUR_GITHUB_ORG>/vidcast.git
cd vidcast
```

---

## 2. Provide your configuration

Nothing sensitive is committed, so you fill in values in **gitignored** files:

```bash
# Terraform inputs
cp terraform/environments/dev/terraform.tfvars.example terraform/environments/dev/terraform.tfvars
# then edit: state_bucket, cluster_name, region, instance type
```

You will also choose application credentials as you go (Mongo/Postgres passwords, a
32+ char `JWT_SECRET`, an optional Gmail app password for notifications). Keep them in
a local note — `DEPLOYMENT_CONFIG.md` is gitignored for exactly this purpose.

---

## 3. Provision infrastructure (Terraform)

```bash
cd terraform/environments/dev

terraform init \
  -backend-config="bucket=YOUR_STATE_BUCKET" \
  -backend-config="key=vidcast/dev/terraform.tfstate" \
  -backend-config="region=eu-west-2" \
  -backend-config="dynamodb_table=vidcast-terraform-locks"

terraform plan
terraform apply        # ~20 minutes for the EKS control plane + node group
cd ../../..
```

This creates the VPC, IAM roles, EKS cluster + node group, security-group NodePort
rules (30002–30008), and the GitHub OIDC deploy role. Grab two outputs you'll reuse:

```bash
cd terraform/environments/dev
terraform output github_actions_role_arn   # → GitHub secret AWS_DEPLOY_ROLE_ARN
cd ../../..

aws eks update-kubeconfig --name vidcast-cluster --region eu-west-2
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
echo "Node external IP: $NODE_IP"
```

---

## 4. Deploy the data services (Helm)

```bash
cd Helm_charts/MongoDB   && helm install mongodb  . && cd ../..
kubectl wait --for=condition=ready pod/mongodb-0 --timeout=120s
cd Helm_charts/Postgres  && helm install postgres . && cd ../..
cd Helm_charts/RabbitMQ  && helm install rabbitmq . && cd ../..
kubectl get pods -w   # wait until all are Running
```

> Mongo/Postgres/RabbitMQ credentials come from each chart's `values.yaml`. Set them
> there before `helm install`, and make them match the service config/secrets (see the
> "Customisation Checklist" in `CLAUDE.md`).

---

## 5. Seed PostgreSQL

`Helm_charts/Postgres/init.sql` ships with **placeholders only** — no real admin email
or password hash. Generate a bcrypt hash and edit the file before applying:

```bash
python3 -c "import bcrypt; print(bcrypt.hashpw(b'YOUR_PASSWORD', bcrypt.gensalt(rounds=12)).decode())"
# paste the result into init.sql in place of <BCRYPT_HASH_HERE>, set your admin email

PGPASSWORD=YOUR_POSTGRES_PASSWORD psql -h "$NODE_IP" -p 30003 \
  -U YOUR_POSTGRES_USERNAME -d authdb -f Helm_charts/Postgres/init.sql
```

---

## 6. Create the RabbitMQ queues

```bash
curl -u guest:guest -X PUT "http://$NODE_IP:30004/api/queues/%2F/video" \
  -H "Content-Type: application/json" -d '{"durable":true}'
curl -u guest:guest -X PUT "http://$NODE_IP:30004/api/queues/%2F/mp3" \
  -H "Content-Type: application/json" -d '{"durable":true}'
```

---

## 7. Get the images

**Option A — let CI build them (recommended).** Push to `main` and GitHub Actions lints,
scans (Trivy), builds, and pushes all four backend services to Docker Hub, then deploys
to EKS. This needs the secrets in [section 10](#10-cicd-secrets).

**Option B — build and push manually.**

```bash
for svc in auth-service gateway-service converter-service notification-service; do
  docker build -t YOUR_DOCKERHUB_USER/$svc:dev src/$svc
  docker push YOUR_DOCKERHUB_USER/$svc:dev
done
```

The frontend is **not** built by CI; build it and push to your ECR (or Docker Hub),
then set the image in the Kustomize overlay you deploy
(`k8s/overlays/<env>/kustomization.yaml`, the `images:` entry named
`vidcast-frontend`). Backend image tags live in the same `images:` block.

---

## 8. Deploy the microservices

Manifests are managed with Kustomize (`k8s/base` + `k8s/overlays/{dev,prod}`).
Secrets are applied separately (they are not in the Kustomize tree):

```bash
# Secrets first (gitignored; rabbitmq-secret comes from the RabbitMQ Helm chart):
kubectl apply -f src/auth-service/manifest/secret.yaml
kubectl apply -f src/gateway-service/manifest/secret.yaml
kubectl apply -f src/converter-service/manifest/secret.yaml
kubectl apply -f src/notification-service/manifest/secret.yaml

# Then the overlay (use overlays/dev for the lighter single-replica dev env):
kubectl apply -k k8s/overlays/prod
kubectl get pods    # all should reach Running
```

---

## 9. Test end-to-end

```bash
# Login (use the admin email + password you seeded in step 5)
TOKEN=$(curl -s -X POST "http://$NODE_IP:30002/login" -u "admin@example.com:YOUR_PASSWORD")

# Upload a video
curl -X POST "http://$NODE_IP:30002/upload" \
  -F "file=@assets/video.mp4" -H "Authorization: Bearer $TOKEN"

# Watch the queue drain
curl -s -u guest:guest "http://$NODE_IP:30004/api/queues/%2F/video" | python3 -m json.tool | grep messages

# Download the MP3 (file id comes from the notification email or the frontend)
curl -X GET "http://$NODE_IP:30002/download?fid=FILE_ID" \
  -H "Authorization: Bearer $TOKEN" -o output.mp3
```

Or just open the web UI at `http://$NODE_IP:30006` and do it through the browser.

---

## 10. CI/CD secrets

The pipelines authenticate with secrets you configure in GitHub / Jenkins — none are
stored in the repo.

### GitHub Actions — CI (`ci.yml`)

Settings → Secrets and variables → Actions:

| Secret | Description | Example |
|--------|-------------|---------|
| `DOCKERHUB_USERNAME` | Docker Hub username | your username |
| `DOCKERHUB_TOKEN` | Docker Hub **access token** (not your password) | `dckr_pat_...` |

Create the token at hub.docker.com → Account Settings → Security → New Access Token.

### GitHub Actions — CD (`cd.yml`), OIDC — no static AWS keys

CD assumes an IAM role via GitHub OIDC (short-lived creds). There are **no**
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` secrets. The role + OIDC provider are
created by Terraform (`terraform/modules/github-oidc`).

| Secret | Source |
|--------|--------|
| `AWS_DEPLOY_ROLE_ARN` | `terraform output github_actions_role_arn` (step 3) |
| `AWS_REGION` | `eu-west-2` |
| `EKS_CLUSTER_NAME` | `vidcast-cluster` |
| `DOCKERHUB_USERNAME` | your Docker Hub username (sets the deployment image name) |

`cd.yml` already sets `permissions: id-token: write` so it can request the OIDC token.

### Jenkins (`Jenkinsfile`)

Manage Jenkins → Credentials:

| Credential ID | Type | Description |
|---------------|------|-------------|
| `dockerhub-credentials` | Username/Password | Docker Hub login |
| `aws-credentials` | AWS Credentials | IAM key for EKS access |
| `swarm-staging-ip` | Secret text | IP of the Swarm staging EC2 |

---

## 11. Monitoring (optional)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install monitoring prometheus-community/kube-prometheus-stack \
  -f monitoring/values.yaml -n monitoring --create-namespace
kubectl apply -f monitoring/alerts/vidcast-alerts.yaml
```

Grafana → `http://$NODE_IP:30007` (admin / vidcast-demo). Alertmanager → `:30008`.

---

## 12. Teardown (stop paying for it)

```bash
kubectl delete -k k8s/overlays/prod    # match the overlay you deployed

helm uninstall mongodb postgres rabbitmq
helm uninstall monitoring -n monitoring

cd terraform/environments/dev && terraform destroy && cd ../../..
```

Because everything is infrastructure-as-code, `terraform apply` brings the whole stack
back in ~20 minutes whenever you need it again.

---

## Troubleshooting

- **Pod in `CrashLoopBackOff`** → `kubectl logs <pod>` and `kubectl describe pod <pod>`.
  Most often a credential mismatch between a chart `values.yaml` and a service config.
- **Every login fails after deploying a new auth image** → the bcrypt image and the DB
  seed must land together; re-run `init.sql`. See [`MERGE_RUNBOOK_RBAC.md`](MERGE_RUNBOOK_RBAC.md).
- **`terraform apply` hangs then fails on the node group** → you used a T-type instance.
  Switch to `m7i-flex.large`.
- **Can't reach a NodePort** → confirm the security-group rules for 30002–30008 exist
  (Terraform creates them) and that you're hitting the node's *external* IP.
