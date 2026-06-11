# k8s/kyverno — Policy-as-Code (B2)

Seven Kyverno `ClusterPolicy` resources that enforce security/best-practice rules
at admission. **Every policy is in `Audit` mode in Sprint 3** — violations are
reported, nothing is blocked.

## Policies

| Policy | Rejects | Mode |
|---|---|---|
| `disallow-latest-tag` | untagged / `:latest` images | Audit |
| `require-requests-limits` | containers without cpu+mem requests AND limits | Audit |
| `require-non-root` | pods not running as non-root | Audit |
| `require-seccomp-runtime-default` | pods without seccomp RuntimeDefault | Audit |
| `require-labels` | pods missing app / environment / app.kubernetes.io/managed-by | Audit |
| `disallow-privileged` | privileged containers + SYS_ADMIN/NET_ADMIN/ALL caps | Audit |
| `verify-images` | **ACTIVATED (B5)** — unsigned `docker.io/<YOUR_DOCKERHUB_USER>/*` + ECR `vidcast-frontend` images (cosign keyless) | Audit |

System and platform namespaces (`kube-system`, `kyverno`, `argocd`, `keda`,
`external-secrets`, `monitoring`, …) are **excluded** so the Audit report stays
focused on the VidCast app in `default`.

## Install (applied separately, like ESO/KEDA/Argo)

```bash
helm repo add kyverno https://kyverno.github.io/kyverno && helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace -f k8s/kyverno/values.yaml
kubectl apply -k k8s/kyverno      # the ClusterPolicies (CRDs → need Kyverno first)
```

## Verify

```bash
kubectl get clusterpolicy                       # all 7 should be READY=true
kubectl get policyreport -A                      # per-namespace pass/fail (Audit results)
kubectl get clusterpolicyreport

# manual Audit test: a pod that violates several policies is ADMITTED (Audit), then
# shows up as failures in the report.
kubectl run audit-test --image=nginx:latest --restart=Never -n default
kubectl get policyreport -n default -o wide      # see audit-test fail disallow-latest-tag, require-* ...
kubectl delete pod audit-test -n default
```

On a torn-down cluster this is **runtime-verify on re-apply** — the artifacts now
are the 7 policy files (validated with `kustomize build` + YAML parse).

## Audit → Enforce promotion (NOT in Sprint 3 — deliberate follow-up)

Do this only after the known violations (see the B2 review note / gap analysis) are
fixed, one policy at a time:

```bash
kubectl get policyreport -A          # 1. review every violation
# 2. fix the offending manifests (datastore resources/securityContext/labels, seccomp
#    on app pods, outbox-relay + postgres image tags) — a separate clean commit
# 3. per policy, flip Audit -> Enforce once its violations are zero:
kubectl patch clusterpolicy require-non-root --type merge \
  -p '{"spec":{"validationFailureAction":"Enforce"}}'
# 4. verify-images stays Audit until B5 signing exists; promote it LAST.
```

Never bulk-flip all policies to Enforce — promote each only when its report is clean,
or you'll block legitimate deploys.

## B5 — verify-images cosign test (live cluster)

`verify-images` is now pointed at the real repos + the real keyless identity but
stays **Audit**. Until the operator's CI signs images, the Audit report will show our
images as **FAIL ("no signature")** — that is the expected "not yet signed" state.

Prereq: the Sigstore egress carve-out so Kyverno can reach Fulcio/Rekor/TUF +
the registries:

```bash
kubectl apply -f k8s/network-policies/allow-kyverno-sigstore-egress.yaml   # kyverno ns
```

Once CI is signing, prove PASS vs FAIL on a live cluster:

```bash
# PASS: a signed VidCast image verifies (after the cosign-sign CI job has run)
kubectl run sig-pass --image=docker.io/<YOUR_DOCKERHUB_USER>/gateway-service:<signed-sha> \
  --restart=Never -n default
kubectl describe clusterpolicyreport | grep -A3 verify-images   # result: pass

# FAIL: an unsigned image is reported (Audit → still admitted, but flagged)
kubectl run sig-fail --image=docker.io/<YOUR_DOCKERHUB_USER>/gateway-service:<unsigned-sha> \
  --restart=Never -n default
kubectl describe clusterpolicyreport | grep -A3 verify-images   # result: fail

kubectl delete pod sig-pass sig-fail -n default
```

Promote `verify-images` to **Enforce LAST** (and set `mutateDigest: true`) only
after a real signed image shows PASS here. Identity + chain: `SUPPLY_CHAIN.md`.
