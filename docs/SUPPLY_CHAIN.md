# SUPPLY_CHAIN.md — A8 Supply-Chain Hardening

How VidCast makes its container images **verifiable**: from a git commit, through
CI, to a signed image whose signature is logged in a public transparency log and
checked at admission by Kyverno (B5).

```
 git commit  ──►  CI build  ──►  image pushed  ──►  cosign keyless sign  ──►  Rekor log
 (source)        (SBOM +         (Docker Hub /      (Fulcio cert binds        (public,
                  SARIF +         ECR, by digest)    the GitHub OIDC           tamper-evident
                  Trivy gate)                        identity to the image)    transparency)
                                                            │
                                                            ▼
                                          Kyverno verifyImages at admission (B5)
                                          checks the signature + identity before
                                          a pod is allowed to run.
```

Each link adds a property: **SBOM** = know what's inside; **SARIF** = vulnerabilities
visible in GitHub Security; **Trivy gate** = CRITICAL/HIGH block the build; **cosign
sign** = provenance + integrity; **Rekor** = public, append-only proof; **Kyverno
verify** = only signed-by-us images run.

---

## Trust anchors

| Anchor | Value | Role |
|--------|-------|------|
| OIDC issuer | `https://token.actions.githubusercontent.com` | GitHub vouches for the workflow's identity |
| Fulcio (CA) | `https://fulcio.sigstore.dev` | issues a short-lived (10-min) cert binding that identity to the signature |
| Rekor (log) | `https://rekor.sigstore.dev` | public transparency log — every signature is recorded immutably |
| TUF root | `https://tuf-repo-cdn.sigstore.dev` | bootstraps trust in Fulcio/Rekor keys |

**Keyless** signing means there is **no private key to store or leak**. The signer's
identity *is* the GitHub Actions OIDC token; Fulcio issues a throwaway certificate
for the ~10 minutes it takes to sign, and the binding is recorded in Rekor forever.

---

## ⭐ Cosign signing identity (B5 needs this EXACTLY)

The Kyverno `verify-images` policy (B5) must match the certificate identity below
**character-for-character**. It is the GitHub Actions OIDC subject for the signing
workflow on `main`:

```
certificate-identity:      https://github.com/<YOUR_GITHUB_ORG>/vidcast/.github/workflows/ci.yml@refs/heads/main
certificate-oidc-issuer:   https://token.actions.githubusercontent.com
```

- If signing is moved to a different workflow file, the `.github/workflows/<file>`
  segment changes — update B5 to match.
- If you lock the OIDC trust to a tag/release instead of a branch, the
  `@refs/heads/main` suffix changes to `@refs/tags/<tag>`.

Repos signed: `<YOUR_DOCKERHUB_USER>/{auth,gateway,converter,notification}-service` (Docker
Hub) and `<AWS_ACCOUNT_ID>.dkr.ecr.eu-west-2.amazonaws.com/vidcast-frontend` (ECR).

---

## Manually verify a signature

```bash
# Any signed image (by tag or, better, by digest):
cosign verify \
  --certificate-identity   'https://github.com/<YOUR_GITHUB_ORG>/vidcast/.github/workflows/ci.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  <YOUR_DOCKERHUB_USER>/gateway-service:<SHORT_SHA>

# Inspect the attached SBOM attestation:
cosign verify-attestation --type cyclonedx \
  --certificate-identity   'https://github.com/<YOUR_GITHUB_ORG>/vidcast/.github/workflows/ci.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  <YOUR_DOCKERHUB_USER>/gateway-service:<SHORT_SHA>
```

A passing `cosign verify` proves: this exact image digest was signed by *our* CI
workflow on `main`, and the signature is in Rekor (so it can't have been forged or
back-dated).

---

## Admission verification (B5 — Kyverno `verify-images`)

The last link: `k8s/kyverno/verify-images.yaml` checks the signature **at admission**
— before a pod is allowed to run. It is now pointed at the real repos and the exact
keyless identity above:

- **imageReferences:** `docker.io/<YOUR_DOCKERHUB_USER>/*` (backends) **and**
  `<AWS_ACCOUNT_ID>.dkr.ecr.eu-west-2.amazonaws.com/vidcast-frontend*` (frontend) — **both
  registries verified**.
- **attestor:** keyless, `subject` = the A8 identity, `issuer` = GitHub OIDC,
  `rekor.url` = `https://rekor.sigstore.dev`.
- **mode:** `Audit`, `mutateDigest: false` — observe only. It **stays Audit** until
  CI is producing signatures and a signed image verifies PASS on a live cluster;
  only then does it go Enforce (+ `mutateDigest: true` to pin admitted pods to the
  verified digest). Until then the Audit report shows our images as FAIL ("no
  signature") — the expected, honest "not yet signed" state.

**Network prerequisite:** Kyverno must reach Fulcio/Rekor/TUF + the registries.
`k8s/network-policies/allow-kyverno-sigstore-egress.yaml` (kyverno namespace) is the
egress carve-out. Honest caveat: vanilla NetworkPolicy can't pin to the Sigstore
*hostnames* (IP/CIDR only), so it's a TCP-443-to-internet allow — FQDN pinning needs
Cilium/an egress proxy (documented in `k8s/network-policies/README.md`).

Live PASS/FAIL test commands: `k8s/kyverno/README.md` §B5.

## ECR hardening (mine — Terraform, implemented)

`terraform/modules/ecr/` (wired into `environments/dev/main.tf` as `module.ecr`):

| Control | Setting | Why |
|---------|---------|-----|
| Tag immutability | `IMMUTABLE` | a verified digest can't be swapped under the same tag |
| Scan on push | `scan_on_push = true` | basic CVE scan on every push (defence in depth behind the CI Trivy gate) |
| Lifecycle | untagged expire after **7d**; keep last **10** images | bounded storage / cost |
| Encryption | `AES256` (AWS-managed) | **CMK deliberately skipped** — ~$1/mo standing for marginal benefit |

`terraform validate` passes. **One-time import** (the repo already exists):

```bash
cd terraform/environments/dev
terraform import 'module.ecr.aws_ecr_repository.this["vidcast-frontend"]' vidcast-frontend
terraform plan   # should then show only the immutability/scan/lifecycle deltas
```

---

## CI diff for the operator (you write these — `.github/workflows/ci.yml`)

Four steps added to the `build-and-scan` job. Keyless signing + SARIF upload need
extra job permissions. Apply as one coherent change:

```diff
   build-and-scan:
     needs: lint
     runs-on: ubuntu-latest
+    # id-token: keyless cosign signing + provenance via GitHub OIDC.
+    # security-events: upload the Trivy SARIF report to the Security tab.
+    permissions:
+      contents: read
+      id-token: write
+      security-events: write
     strategy:
       fail-fast: false
       matrix:
         service: [auth-service, gateway-service, converter-service, notification-service]

     steps:
       - uses: actions/checkout@v4

       - name: Set short SHA
         run: echo "SHORT_SHA=${GITHUB_SHA::7}" >> $GITHUB_ENV

       - name: Build Docker image
         run: |
           docker build \
             -t ${{ secrets.DOCKERHUB_USERNAME }}/${{ matrix.service }}:${{ env.SHORT_SHA }} \
             src/${{ matrix.service }}/

+      # ── A8 step 1: SBOM (CycloneDX JSON) ───────────────────────────────────
+      # syft generates a component inventory; uploaded as a build artifact and
+      # (after push) attached to the image as a cosign attestation below.
+      - name: Generate SBOM (CycloneDX)
+        uses: anchore/sbom-action@v0
+        with:
+          image: ${{ secrets.DOCKERHUB_USERNAME }}/${{ matrix.service }}:${{ env.SHORT_SHA }}
+          format: cyclonedx-json
+          output-file: sbom-${{ matrix.service }}.cdx.json
+      - name: Upload SBOM artifact
+        uses: actions/upload-artifact@v4
+        with:
+          name: sbom-${{ matrix.service }}
+          path: sbom-${{ matrix.service }}.cdx.json

       # ── existing gating scan (unchanged): CRITICAL/HIGH fail the build ──────
       - name: Trivy vulnerability scan
         uses: aquasecurity/trivy-action@master
         with:
           image-ref: ${{ secrets.DOCKERHUB_USERNAME }}/${{ matrix.service }}:${{ env.SHORT_SHA }}
           severity: CRITICAL,HIGH
           exit-code: '1'
           ignore-unfixed: true
           format: table

+      # ── A8 step 2: SARIF → GitHub Security tab ─────────────────────────────
+      # A SECOND, non-gating Trivy run that emits SARIF (exit-code 0 so it never
+      # fails the build — the gate above already did that) and uploads it.
+      - name: Trivy scan (SARIF, report-only)
+        uses: aquasecurity/trivy-action@master
+        with:
+          image-ref: ${{ secrets.DOCKERHUB_USERNAME }}/${{ matrix.service }}:${{ env.SHORT_SHA }}
+          severity: CRITICAL,HIGH
+          exit-code: '0'
+          ignore-unfixed: true
+          format: sarif
+          output: trivy-${{ matrix.service }}.sarif
+      - name: Upload SARIF to code-scanning
+        uses: github/codeql-action/upload-sarif@v3
+        with:
+          sarif_file: trivy-${{ matrix.service }}.sarif
+          category: trivy-${{ matrix.service }}

       - name: Login to Docker Hub
         if: github.ref == 'refs/heads/main' && github.event_name == 'push'
         uses: docker/login-action@v3
         with:
           username: ${{ secrets.DOCKERHUB_USERNAME }}
           password: ${{ secrets.DOCKERHUB_TOKEN }}

       - name: Push image to Docker Hub
         if: github.ref == 'refs/heads/main' && github.event_name == 'push'
         run: docker push ${{ secrets.DOCKERHUB_USERNAME }}/${{ matrix.service }}:${{ env.SHORT_SHA }}

+      # ── A8 step 3: cosign keyless sign (main pushes only) ──────────────────
+      - name: Install cosign
+        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
+        uses: sigstore/cosign-installer@v3
+      - name: Resolve pushed digest
+        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
+        run: |
+          # Sign by DIGEST, never by mutable tag.
+          echo "IMAGE_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' \
+            ${{ secrets.DOCKERHUB_USERNAME }}/${{ matrix.service }}:${{ env.SHORT_SHA }})" >> $GITHUB_ENV
+      - name: Sign image (keyless, OIDC)
+        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
+        env:
+          COSIGN_YES: "true"           # non-interactive; uses the ambient GitHub OIDC token
+        run: cosign sign "${IMAGE_DIGEST}"

+      # ── A8 step 4: SLSA provenance + SBOM attestation ──────────────────────
+      # Attach the CycloneDX SBOM to the image as a signed attestation:
+      - name: Attest SBOM
+        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
+        env:
+          COSIGN_YES: "true"
+        run: cosign attest --type cyclonedx --predicate sbom-${{ matrix.service }}.cdx.json "${IMAGE_DIGEST}"
+      # For full SLSA build-provenance (L3), call the reusable generator as a
+      # SEPARATE job that takes the pushed digest as input — it produces a signed
+      # provenance attestation proving which commit + workflow built the image:
+      #   uses: slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@v2.0.0
+      #   with: { image: <repo>, digest: ${{ env.IMAGE_DIGEST-as-output }} }
+      #   secrets: { registry-username: ..., registry-password: ... }
```

**Why these belong to the operator:** they live under `.github/workflows/`, which is the
CI/CD boundary you own. The Kyverno side (B5) is mine and only goes to Enforce once
these steps are merged and have produced at least one verifiable signature.

---

## Cost decisions (A8)

- **No CMK** — AES256 AWS-managed encryption is free; a CMK is ~$1/mo standing.
- ECR scan-on-push, immutability, lifecycle, SBOM, SARIF, cosign keyless, Rekor:
  **all $0** within free limits. A8 adds no standing AWS charge.

---

## Status (honest)

| Item | State |
|------|-------|
| ECR Terraform (immutability/scan/lifecycle) | ✅ written, `terraform validate` passes; `import` + `apply` owed at re-apply |
| Cosign signing identity documented | ✅ (above — B5 consumes it) |
| CI diffs (SBOM/SARIF/cosign/provenance) | ✅ provided for the operator; not applied (his boundary) |
| Kyverno `verify-images` (B5) | ✅ activated, both registries, real identity, **Audit** (parses; `kustomize build` → 7 policies, 0 Enforce) |
| Sigstore egress NetworkPolicy (B5) | ✅ written (kyverno ns, Egress-only); apply + runtime-verify owed |
| Signatures actually in Rekor + a live PASS | ⏳ deferred — needs the operator's CI merged + a real run |
