# VidCast — Ingress / TLS / Perimeter Deploy Guide (Sprint 2)

> Closes **P1 / I7** (ALB Ingress + HTTPS on a hostname) and **I2** (datastores +
> app services NodePort → ClusterIP). Branch:
> `feature/improvement-sprint-2-ingress-tls`. **Nothing here has been applied** —
> this is the deploy runbook for after sign-off.

---

## 1. What changes

- The platform moves from `http://<node-ip>:30006` to **`https://<hostname>`**,
  served by an **AWS ALB** the Load Balancer Controller provisions from
  `k8s/ingress/vidcast-ingress.yaml`.
- **All NodePorts are removed.** MongoDB (30005), PostgreSQL (30003), RabbitMQ
  (30004), gateway (30002), frontend (30006) → **ClusterIP**. The ALB is the only
  external entrypoint; datastores are admin-accessed via `kubectl port-forward`.

## 2. Design decisions (deviations from the original prompt — read these)

1. **Routing is `/` → `frontend`, not `/api` → `gateway`.** The frontend's nginx
   already serves the SPA and proxies `/api/` → `gateway:8080` **stripping the
   `/api` prefix** (`src/frontend/nginx.conf`). An ALB cannot strip path prefixes,
   so a direct `/api` → gateway rule would deliver `/api/login` to a gateway that
   only knows `/login` (404). Routing everything through the frontend preserves the
   working path for browsers **and** API clients (`https://<host>/api/login`) and
   keeps the **gateway internal** (ClusterIP) — smaller attack surface.
2. **TLS is ACM, not cert-manager.** The ALB terminates TLS with an **ACM
   certificate** (`alb.ingress.kubernetes.io/certificate-arn`). An ALB cannot read
   cert-manager's in-cluster TLS secrets, so the `ClusterIssuer`
   (`k8s/ingress/cert-manager/`) is shipped only as the **alternative** path (for an
   in-cluster ingress controller, or DNS-01 issuance you import to ACM). For the
   default ALB path you do **not** need cert-manager.
3. **No new `allow-alb-ingress` NetworkPolicy.** The existing `gateway` and
   `frontend` policies (`app-policies.yaml`) already allow ingress on 8080 **from
   any source**, so the ALB path is already permitted — a new VPC-CIDR policy would
   be a redundant no-op (NetworkPolicy is an additive union). *Hardening
   opportunity (separate change, since this sprint must not edit existing
   policies):* tighten those two ingress rules from "anywhere" to the VPC CIDR now
   that the ALB is the only entrypoint.
4. **LBC IRSA lives in `terraform/modules/lbc/`, not `modules/iam/`.** The iam
   module creates the cluster role the eks module depends on, and eks creates the
   OIDC provider the LBC trust policy needs — putting it in iam would form an
   iam↔eks cycle. Mirrors the `external-secrets` / `storage` IRSA modules.
5. **Grafana subpath routing deferred.** Routing `/grafana` needs grafana's
   `serve_from_sub_path`/`root_url` config (a monitoring change, out of this
   sprint's scope) or a dedicated `grafana.<host>` subdomain + cert SAN. Left as a
   follow-up; the Ingress uses `group.name: vidcast` so a grafana Ingress can later
   share the same ALB.

## 3. Placeholders to fill at deploy time

From `DEPLOYMENT_CONFIG.md` and `terraform output`:

| Placeholder | Source |
|---|---|
| `${VIDCAST_HOSTNAME}` | DEPLOYMENT_CONFIG.md (the public DNS name) |
| `${ACM_CERTIFICATE_ARN}` | ACM cert for the hostname (step 2 below) |
| `${LBC_IRSA_ROLE_ARN}` | `terraform output lbc_irsa_role_arn` |
| `${VPC_ID}` | `terraform output vpc_id` |
| `${ALERT_EMAIL}` | DEPLOYMENT_CONFIG.md (cert-manager path only) |

## 4. Deploy sequence

```bash
# 1. Terraform: create the LBC IRSA role (idempotent; adds only IAM — no ALB yet).
cd terraform/environments/dev && terraform apply   # review: should be additive only
LBC_IRSA_ROLE_ARN=$(terraform output -raw lbc_irsa_role_arn)
VPC_ID=$(terraform output -raw vpc_id)
cd -

# 2. ACM: request a cert for $VIDCAST_HOSTNAME (DNS-validated) and note its ARN.
#    aws acm request-certificate --domain-name "$VIDCAST_HOSTNAME" \
#      --validation-method DNS --region eu-west-2
#    (add the CNAME it returns to your DNS zone; wait for status ISSUED)

# 3. Install the AWS Load Balancer Controller.
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system -f k8s/ingress/alb-controller-values.yaml \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$LBC_IRSA_ROLE_ARN" \
  --set vpcId="$VPC_ID"
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller

# 4. (ONLY if using cert-manager instead of ACM)
# helm repo add jetstack https://charts.jetstack.io
# helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set installCRDs=true
# envsubst < k8s/ingress/cert-manager/cluster-issuer.yaml | kubectl apply -f -

# 5. Apply the Ingress (placeholders substituted). The ALB takes a few minutes.
export VIDCAST_HOSTNAME ACM_CERTIFICATE_ARN
envsubst < k8s/ingress/vidcast-ingress.yaml | kubectl apply -f -
kubectl get ingress vidcast-ingress -w   # wait for ADDRESS (the ALB DNS name)

# 6. Point DNS at the ALB: Route 53 ALIAS/CNAME  $VIDCAST_HOSTNAME -> <ALB DNS name>.

# 7. Flip services to ClusterIP. Datastores via Helm; gateway/frontend via Argo
#    (it auto-syncs overlays/dev) or `kubectl apply -k k8s/overlays/dev`.
helm upgrade mongodb  Helm_charts/MongoDB/  --reuse-values
helm upgrade postgres Helm_charts/Postgres/ -f <(helm get values postgres)   # keep the password
helm upgrade rabbitmq Helm_charts/RabbitMQ/ --reuse-values
#    NOTE: do this AFTER the ALB is serving — converting frontend/gateway to
#    ClusterIP removes the old NodePort access path.
```

## 5. Verification

```bash
# ALB provisioned + cert attached
kubectl get ingress vidcast-ingress -o wide
# HTTPS end-to-end (expect the SPA, then a working login through /api)
curl -sSI https://$VIDCAST_HOSTNAME/ | head -1               # 200
curl -sS  https://$VIDCAST_HOSTNAME/api/login -u 'baabalola@gmail.com:<pw>' | head -c 40  # JWT
# HTTP redirects to HTTPS
curl -sSI http://$VIDCAST_HOSTNAME/ | grep -i location       # -> https
# NodePorts are gone (datastores + app)
kubectl get svc | grep -i nodeport || echo "no NodePort services — good"
# Datastores no longer externally reachable; admin via port-forward:
kubectl port-forward svc/rabbitmq 15672:15672   # then localhost:15672
```

## 6. Cost & rollback

- **Cost:** ALB ~£22/month + low LCU. Route 53 ~£1. Within the assessment's
  approved envelope. The LBC IRSA role itself is free; the **ALB is created when
  the Ingress is applied** (step 5) — that's the billing trigger.
- **Rollback:** `kubectl delete ingress vidcast-ingress` (ALB de-provisions),
  `helm uninstall aws-load-balancer-controller`, and revert the Services to
  NodePort (`git revert` the service commits, re-apply). The app keeps running
  throughout; only the entrypoint changes.
```
