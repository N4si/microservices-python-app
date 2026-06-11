# k8s/network-policies — Default-deny NetworkPolicies (A6)

A zero-trust network posture for the `default` namespace: every pod denies all
ingress and egress except the flows explicitly allowed here.

## ⚠️ Hard prerequisite

The **VPC CNI network-policy agent must be enabled**, or these policies are
accepted by the API server and **never enforced** (decorative YAML). It's enabled
in Terraform: `terraform/modules/eks/main.tf` → `aws_eks_addon.vpc_cni` with
`enableNetworkPolicy = "true"`. Confirm after apply:

```bash
kubectl get ds aws-node -n kube-system -o yaml | grep -i network-policy   # agent flag
```

## Files (applied with default-deny LAST)

| File | What it allows |
|---|---|
| `allow-dns.yaml` | every pod → CoreDNS (UDP/TCP 53) — **must** exist before deny |
| `allow-monitoring.yaml` | Prometheus (`monitoring` ns) → gateway:8080, auth:5000 |
| `app-policies.yaml` | per-app ingress/egress (gateway, auth, frontend, converter, notification, outbox-relay) |
| `datastore-policies.yaml` | mongodb / postgres / rabbitmq / redis ingress from their clients (+ KEDA→rabbitmq) |
| `default-deny.yaml` | deny all ingress + egress (the catch-all) — **apply last** |

## The traffic matrix

```
            (browser, NodePort 30002/30006)
                       │
                       ▼
   frontend :8080 ──/api/──► gateway :8080 ──► auth :5000 ──► postgres :5432
                                  │
                                  ├──► mongodb :27017  (GridFS + outbox)
                                  └──► rabbitmq :5672  (publish / outbox path)

   outbox-relay ──► mongodb :27017,  rabbitmq :5672
   converter    ──► rabbitmq :5672,  mongodb :27017,  redis :6379
   notification ──► rabbitmq :5672,  redis :6379,     SMTP 0.0.0.0/0:587 (Gmail)
   KEDA (keda ns) ──► rabbitmq :5672 (queue-depth poll)
   Prometheus (monitoring ns) ──► gateway :8080, auth :5000
   all pods ──► CoreDNS :53
```

Anything not in this matrix is denied. Notably the DB/broker admin NodePorts
(30003/30004/30005) are **no longer reachable from outside the cluster** — that
also closes finding **H-1**. Use `kubectl port-forward` for admin access.

## Apply

```bash
# (after the CNI agent is enabled and the app is deployed)
kubectl apply -k k8s/network-policies     # allows + deny as one coherent set
```

## Verify (REQUIRED on a live cluster before declaring A6 done)

```bash
# positive: an ALLOWED path works
kubectl exec deploy/gateway -- python -c "import socket; socket.create_connection(('auth',5000),3); print('gateway->auth OK')"

# negative: a DENIED path hangs/times out (e.g. gateway must NOT reach redis)
kubectl exec deploy/gateway -- python -c "import socket; socket.create_connection(('redis',6379),3)"   # expect timeout

# DNS still resolves
kubectl exec deploy/gateway -- python -c "import socket; print(socket.gethostbyname('rabbitmq'))"

# Prometheus targets still UP for the scraped pods
```

## Rollback (fastest in the plan)

```bash
kubectl delete networkpolicy default-deny-all -n default   # instantly reopens networking
# or: kubectl delete -k k8s/network-policies
```

## B5 — Sigstore egress for Kyverno (kyverno namespace)

`allow-kyverno-sigstore-egress.yaml` lets the Kyverno image-verifier reach the OCI
registries + Fulcio/Rekor/TUF. It targets the **kyverno** namespace, so it is
**NOT** part of the `default`-ns kustomization above (that would force it into
`default`). Apply it standalone:

```bash
kubectl apply -f k8s/network-policies/allow-kyverno-sigstore-egress.yaml
```

⚠️ **Honest limitation — no hostname pinning.** Vanilla Kubernetes NetworkPolicy
matches egress by **IP/CIDR, not hostname**, so it cannot pin to `*.sigstore.dev`.
Sigstore + the registries sit on rotating CDN IPs, so the only expressible rule is
**TCP 443 to the public internet** (which also permits the registries Kyverno
needs anyway). True FQDN-scoped egress (fulcio/rekor/tuf only) requires a
DNS-aware CNI (Cilium) or an egress proxy — out of scope. The kyverno namespace
ships **no default-deny** today, so this policy is a safe, deliberate hardening to
apply when locking that namespace down.
