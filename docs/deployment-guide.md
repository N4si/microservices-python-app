# VidCast — Deployment Guide

Complete step-by-step instructions for deploying, operating, and destroying the VidCast platform.

---

## Prerequisites

```bash
# Check all tools are installed
aws --version           # AWS CLI v2+
kubectl version         # 1.31+
helm version            # 3.x
terraform version       # 1.5+
psql --version          # PostgreSQL client
docker --version        # Docker 20+
```

Configure AWS credentials:
```bash
aws configure
# Or export AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
aws sts get-caller-identity  # Verify
```

---

## Phase 1 — Infrastructure (Terraform)

Create the S3 bucket and DynamoDB table for Terraform remote state first (one-time):

```bash
# State bucket
aws s3 mb s3://YOUR-STATE-BUCKET --region eu-west-2
aws s3api put-bucket-versioning --bucket YOUR-STATE-BUCKET \
  --versioning-configuration Status=Enabled

# State lock table
aws dynamodb create-table \
  --table-name vidcast-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region eu-west-2
```

Then apply Terraform:

```bash
cd terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set state_bucket to YOUR-STATE-BUCKET

terraform init \
  -backend-config="bucket=YOUR-STATE-BUCKET" \
  -backend-config="key=vidcast/dev/terraform.tfstate" \
  -backend-config="region=eu-west-2" \
  -backend-config="dynamodb_table=vidcast-terraform-locks"

terraform validate
terraform plan
terraform apply    # Takes ~20 minutes for EKS cluster creation
```

Get the kubeconfig update command from outputs:
```bash
terraform output kubeconfig_command
# Run the command it prints
kubectl get nodes -o wide  # Capture EXTERNAL-IP as NODE_IP
```

---

## Phase 2 — Infrastructure Services (Helm)

```bash
cd Helm_charts/MongoDB
helm install mongodb .
kubectl wait --for=condition=ready pod/mongodb-0 --timeout=180s

cd ../Postgres
helm install postgres .
kubectl wait --for=condition=ready pod -l app=postgres --timeout=120s

cd ../RabbitMQ
helm install rabbitmq .
kubectl wait --for=condition=ready pod/rabbitmq-0 --timeout=120s
cd ../..
```

---

## Phase 3 — Initialise PostgreSQL

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')

PGPASSWORD=YOUR_POSTGRES_PASSWORD psql \
  -h $NODE_IP -p 30003 \
  -U YOUR_POSTGRES_USERNAME -d authdb \
  -f Helm_charts/Postgres/init.sql

# Verify
PGPASSWORD=YOUR_POSTGRES_PASSWORD psql \
  -h $NODE_IP -p 30003 \
  -U YOUR_POSTGRES_USERNAME -d authdb \
  -c "SELECT email FROM auth_user;"
```

---

## Phase 4 — Create RabbitMQ Queues

```bash
curl -u guest:guest -X PUT http://$NODE_IP:30004/api/queues/%2F/video \
  -H "Content-Type: application/json" -d '{"durable":true}'

curl -u guest:guest -X PUT http://$NODE_IP:30004/api/queues/%2F/mp3 \
  -H "Content-Type: application/json" -d '{"durable":true}'

# Verify
curl -s -u guest:guest http://$NODE_IP:30004/api/queues | \
  python3 -c "import json,sys; [print(q['name']) for q in json.load(sys.stdin)]"
```

---

## Phase 5 — Create Kubernetes Secrets

Secrets are gitignored (`**/secret.yaml`). A `secret.yaml.example` template sits
beside each service's manifests — copy it to `secret.yaml`, fill in real values,
and it will be picked up by `kubectl apply -f <service>/manifest/`. Or create
them imperatively:

```bash
# Auth service
kubectl create secret generic auth-secret \
  --from-literal=PSQL_PASSWORD=YOUR_POSTGRES_PASSWORD \
  --from-literal=JWT_SECRET=YOUR_JWT_SECRET

# Gateway service — MongoDB URIs now live in the Secret, not the ConfigMap
kubectl create secret generic gateway-secret \
  --from-literal=MONGODB_VIDEOS_URI="mongodb://USER:PASS@mongodb:27017/videos?authSource=admin" \
  --from-literal=MONGODB_MP3S_URI="mongodb://USER:PASS@mongodb:27017/mp3s?authSource=admin"

# Converter service — MongoDB URI now lives in the Secret, not the ConfigMap
kubectl create secret generic converter-secret \
  --from-literal=MONGODB_URI="mongodb://USER:PASS@mongodb:27017/mp3s?authSource=admin"

# Notification service
kubectl create secret generic notification-secret \
  --from-literal=GMAIL_ADDRESS=YOUR_GMAIL \
  --from-literal=GMAIL_PASSWORD=YOUR_GMAIL_APP_PASSWORD
```

---

## Phase 6 — Deploy Microservices

```bash
kubectl apply -f src/auth-service/manifest/
kubectl rollout status deployment/auth --timeout=120s

kubectl apply -f src/gateway-service/manifest/
kubectl rollout status deployment/gateway --timeout=120s

kubectl apply -f src/converter-service/manifest/
kubectl rollout status deployment/converter --timeout=120s

kubectl apply -f src/notification-service/manifest/
kubectl rollout status deployment/notification --timeout=120s

kubectl apply -f src/frontend/manifest/
kubectl rollout status deployment/frontend --timeout=120s

kubectl get pods  # All should be Running
```

---

## Phase 7 — End-to-End Test

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')

# Login
TOKEN=$(curl -s -X POST http://$NODE_IP:30002/login -u "EMAIL:PASSWORD")
echo "Token: ${TOKEN:0:30}..."

# Upload
curl -X POST http://$NODE_IP:30002/upload \
  -F "file=@assets/video.mp4" \
  -H "Authorization: Bearer $TOKEN"
# Expected: "success!"

# Monitor conversion
sleep 10
curl -s -u guest:guest http://$NODE_IP:30004/api/queues/%2F/video | \
  python3 -c "import json,sys; q=json.load(sys.stdin); print('video queue:', q.get('messages', 0), 'messages')"

# Download (file_id from notification email)
curl -X GET "http://$NODE_IP:30002/download?fid=FILE_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -o output.mp3
ls -lh output.mp3
```

---

## Phase 8 — Monitoring (Optional)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install monitoring prometheus-community/kube-prometheus-stack \
  -f monitoring/values.yaml -n monitoring --create-namespace

kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=180s

kubectl apply -f monitoring/alerts/vidcast-alerts.yaml

echo "Grafana: http://$NODE_IP:30007 (admin / vidcast-demo)"
echo "Alertmanager: http://$NODE_IP:30008"
```

---

## Operational Commands

```bash
# Pod status
kubectl get pods -o wide

# Logs
kubectl logs -l app=gateway --tail=50
kubectl logs -l app=converter --tail=50 -c converter

# Restart a deployment
kubectl rollout restart deployment/gateway

# Scale converters for heavy load
kubectl scale deployment/converter --replicas=8

# Watch RabbitMQ queue depths
watch -n5 "curl -s -u guest:guest http://$NODE_IP:30004/api/queues/%2F | \
  python3 -c \"import json,sys; [print(q['name'], q.get('messages',0)) for q in json.load(sys.stdin)]\""

# Check health endpoints
curl http://$NODE_IP:30002/healthz  # Gateway
```

---

## Cost Management

Stop/start the node group to pause costs (saves ~$70/month when not in use):

```bash
# Stop (scale to 0 nodes)
aws eks update-nodegroup-config \
  --cluster-name vidcast-cluster \
  --nodegroup-name vidcast-nodes \
  --scaling-config minSize=0,maxSize=2,desiredSize=0 \
  --region eu-west-2

# Start (scale back up)
aws eks update-nodegroup-config \
  --cluster-name vidcast-cluster \
  --nodegroup-name vidcast-nodes \
  --scaling-config minSize=1,maxSize=2,desiredSize=1 \
  --region eu-west-2
```

Note: The EKS control plane still costs ~$73/month even with 0 nodes. For extended breaks, run `terraform destroy`.

---

## Teardown (Full Destroy)

```bash
# 1. Microservices
kubectl delete -f src/frontend/manifest/
kubectl delete -f src/auth-service/manifest/
kubectl delete -f src/gateway-service/manifest/
kubectl delete -f src/converter-service/manifest/
kubectl delete -f src/notification-service/manifest/

# 2. Monitoring
helm uninstall monitoring -n monitoring
kubectl delete namespace monitoring

# 3. Infrastructure services
helm uninstall mongodb
helm uninstall postgres
helm uninstall rabbitmq

# 4. EKS + VPC + IAM via Terraform
cd terraform/environments/dev
terraform destroy    # Takes ~15 minutes

# 5. Delete Terraform state bucket (optional)
aws s3 rb s3://YOUR-STATE-BUCKET --force
aws dynamodb delete-table --table-name vidcast-terraform-locks --region eu-west-2
```
