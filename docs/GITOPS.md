# GITOPS.md — Deployment model with Argo CD (B1)

> How VidCast deploys after Sprint 3. Tracked (not gitignored): this is the
> contract for how changes reach the cluster.

---

## 1. The model in one paragraph

Argo CD runs in-cluster and continuously reconciles the `default` namespace to the
Kustomize manifests in this repo under `k8s/overlays/{dev,prod}`. **Git is the
source of truth.** Nobody runs `kubectl apply` or `kubectl set image` against the
app anymore — you change git, and Argo makes the cluster match. **dev auto-syncs;
prod syncs only on a human action (the approval gate).**

---

## 2. Why in-repo manifests (Q3 decision)

The Argo `Application`s point at `k8s/overlays/{dev,prod}` **in this same repo** —
there is no separate manifest repo and no reorganisation into an `apps/` tree.

- **Separate manifest repo** is the textbook pattern for **multi-team orgs**: it
  decouples "who can change app code" from "who can change what's deployed," and
  lets many app repos feed one deployment repo.
- **Single-repo** is the right call for a **solo project**: one PR captures both
  the code change *and* the manifest/image-tag change, with one review and one
  audit trail. The indirection of a second repo would add ceremony with no
  separation-of-duties benefit when one person owns everything.

This is a deliberate, documented trade-off — not an oversight.

---

## 3. Manifest layout (what Argo reads)

```
k8s/
  base/<svc>/                 # A10 base manifests (one per workload)
  overlays/
    dev/   → Application vidcast-dev  (auto-sync)   1 replica each
    prod/  → Application vidcast-prod (manual-sync) live footprint
```

Argo runs `kustomize build` on the overlay path itself — the same command we
validate locally. No Argo-specific manifest format; the overlays are plain
Kustomize.

---

## 4. What Argo manages vs what stays manual

| Layer | Owner | How it's applied |
|---|---|---|
| **App workloads** (Deployments, Services, ConfigMaps, ESO-created Secrets in `overlays/*`) | Argo CD | synced from git |
| Argo CD itself | platform (the operator) | `helm install argocd` |
| ESO (`ClusterSecretStore`, `ExternalSecret`s) | platform | `kubectl apply -f k8s/external-secrets` |
| KEDA (`ScaledObject`, `TriggerAuthentication`) | platform | `kubectl apply -k k8s/keda` |
| NetworkPolicies | platform | `kubectl apply -k k8s/network-policies` |
| Kyverno + ClusterPolicies | platform | `kubectl apply -k k8s/kyverno` |

**Why the split:** Argo manages the *application*; the *platform* (the control
planes that make the cluster what it is, including Argo's own install) is owned by
the platform engineer. Argo shouldn't manage its own installation (chicken-and-egg),
and platform changes are infrequent, privileged, and not part of the app delivery
loop. (An "app-of-apps" pattern could later bring some platform pieces under Argo,
but that's deliberately out of scope here.)

---

## 5. dev vs prod sync behaviour

| | vidcast-dev | vidcast-prod |
|---|---|---|
| `syncPolicy.automated` | **present** (`prune: true`, `selfHeal: true`) | **absent** (manual only) |
| Trigger | every change to `overlays/dev` on main, auto | a human runs `argocd app sync vidcast-prod` |
| Drift (manual `kubectl edit`) | auto-reverted (selfHeal) | shown as OutOfSync until a human acts |
| Purpose | fast validation loop | the production approval gate |

**dev workflow:** `merge to main → CI builds image → image-tag bump in
overlays/dev → Argo auto-syncs within the poll interval (~3 min)`.

**prod workflow:** `merge image-tag-bump PR → vidcast-prod shows OutOfSync → human
syncs`. The **PR merge is the approval**; the manual Argo sync is the deploy action.

> ⚠️ **Single-cluster caveat.** Both Applications target the `default` namespace on
> the one demo cluster, so they manage the same-named resources. **Sync only one at
> a time.** In a real deployment, dev and prod Applications point at different
> clusters (`destination.server`). Syncing both here would make them fight over the
> same Deployments.

---

## 6. The approval-gate migration (the important part)

**Before (push model):** `.github/workflows/cd.yml` runs `kubectl set image`
straight against EKS after CI. The "approval" was an ephemeral Jenkins button; the
record of what's deployed lives only in the cluster.

**After (pull model):** CI builds+pushes the image, then **something updates the
image tag in the overlay**, and Argo syncs. The deploy becomes a **git change with
a diff, a reviewer, and a permanent audit trail** — you can see exactly which image
SHA went to prod, who approved it, and when, forever. Rollback is `git revert`.

The "something that updates the tag" is a **CD change the operator writes** (workflows are
the operator's per the execution split). Two options:

### Option A (recommended) — all-GitHub

After CI pushes the image, a CD job bumps the tag with `kustomize edit set image`
and opens a PR (prod) / commits to main (dev). Merging the PR is the approval.

- **dev:** commit the dev-overlay bump straight to main → Argo auto-syncs.
- **prod:** open a PR bumping the prod overlay → review+merge = approval → human
  runs `argocd app sync vidcast-prod`.

**Why recommended:** simplest, single system (GitHub), the PR diff *is* the
audit/approval, and it matches the in-repo Q3 decision.

### Option B — preserve the Jenkins Swarm smoke-test

Jenkins keeps building → deploys to Swarm staging → smoke-tests. **On success**,
Jenkins (instead of `kubectl set image`) bumps the overlay tag and opens the same
PR. Merge = approval.

**Why you might want it:** keeps the real pre-prod verification (Swarm smoke test)
as a gate on *opening* the PR — defence in depth. Cost: two systems to maintain.

**Recommendation: Option A.** The Swarm smoke-test is valuable but, for a solo
project, the marginal safety doesn't justify maintaining Jenkins + GitHub Actions.
If you keep Jenkins, do Option B and demote Jenkins to "smoke-test then open PR"
(its `kubectl`/rollback-undo stages go away — Argo owns deploy + rollback now).

### Exact diff for the operator — `cd.yml` (Option A)

Replace the `kubectl set image` deploy with a tag-bump-and-PR job. The OIDC/EKS
steps are no longer needed in CD (Argo deploys, not the workflow):

```diff
 name: VidCast CD — Deploy to EKS
 on:
   workflow_run:
     workflows: ["VidCast CI — Lint, Scan, Build, Push"]
     types: [completed]
     branches: [main]

-permissions:
-  id-token: write   # required to request the OIDC token
-  contents: read
+permissions:
+  contents: write        # commit the dev tag bump
+  pull-requests: write   # open the prod tag-bump PR

 jobs:
   deploy:
     if: ${{ github.event.workflow_run.conclusion == 'success' }}
     runs-on: ubuntu-latest
     steps:
       - uses: actions/checkout@v4
+        with: { ref: main, fetch-depth: 0 }

-      - name: Configure AWS credentials (OIDC)
-        uses: aws-actions/configure-aws-credentials@v4
-        with:
-          role-to-assume: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
-          aws-region: ${{ secrets.AWS_REGION }}
-      - name: Update kubeconfig for EKS
-        run: aws eks update-kubeconfig --name ${{ secrets.EKS_CLUSTER_NAME }} --region ${{ secrets.AWS_REGION }}

       - name: Set short SHA
         run: echo "SHORT_SHA=$(echo ${{ github.event.workflow_run.head_sha }} | cut -c1-7)" >> $GITHUB_ENV

-      - name: Deploy services to EKS
-        run: |
-          for svc in auth-service gateway-service converter-service notification-service; do
-            deploy_name="${svc%-service}"
-            kubectl set image deployment/${deploy_name} \
-              ${deploy_name}=${{ secrets.DOCKERHUB_USERNAME }}/${svc}:${{ env.SHORT_SHA }} || true
-            kubectl rollout status deployment/${deploy_name} --timeout=120s || true
-          done
-      - name: Verify all pods running
-        run: kubectl get pods -o wide
+      - name: Install kustomize
+        run: curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash && sudo mv kustomize /usr/local/bin/
+
+      # DEV: bump tags and push straight to main → Argo auto-syncs vidcast-dev.
+      - name: Bump dev overlay image tags
+        run: |
+          cd k8s/overlays/dev
+          for svc in auth gateway converter notification; do
+            kustomize edit set image <YOUR_DOCKERHUB_USER>/${svc}-service:${SHORT_SHA}
+          done
+      - name: Commit dev bump
+        run: |
+          git config user.name "vidcast-ci"; git config user.email "ci@vidcast"
+          git commit -am "ci(dev): bump images to ${SHORT_SHA}" && git push origin main || echo "no change"
+
+      # PROD: open a PR bumping the prod overlay. Merge = approval; then a human
+      # runs `argocd app sync vidcast-prod` (prod Application is manual-sync).
+      - name: Bump prod overlay image tags on a branch
+        run: |
+          git checkout -b "deploy/prod-${SHORT_SHA}"
+          cd k8s/overlays/prod
+          for svc in auth gateway converter notification; do
+            kustomize edit set image <YOUR_DOCKERHUB_USER>/${svc}-service:${SHORT_SHA}
+          done
+          git commit -am "deploy(prod): bump images to ${SHORT_SHA}"
+          git push origin "deploy/prod-${SHORT_SHA}"
+      - name: Open prod deploy PR
+        run: gh pr create --base main --head "deploy/prod-${SHORT_SHA}" --title "Deploy ${SHORT_SHA} to prod" --body "Review = approval. After merge: argocd app sync vidcast-prod"
+        env: { GH_TOKEN: "${{ github.token }}" }
```

> Notes for the operator: the `outbox-relay` image (A1) should be added to this loop and to
> the overlays' `images:` lists once CI builds it. The `kustomize edit set image`
> lines assume the overlay `images:` entries A10 created. The CD job no longer needs
> AWS/EKS secrets — drop `AWS_DEPLOY_ROLE_ARN` etc. from CD (CI still uses them only
> if it pushed to ECR; Docker Hub images don't need AWS at all).

---

## 7. Rollback

```bash
git revert <bad-commit>     # the image-tag bump (or any manifest change)
# dev: Argo auto-syncs back. prod: argocd app sync vidcast-prod
```

Rollback is now a **git operation with history**, not an invisible
`kubectl rollout undo`. You can see in `git log` exactly what was rolled back and
when.

---

## 8. The one rule: don't `kubectl edit` synced resources

Once Argo owns a resource, **git is the only way to change it.** A manual
`kubectl edit`/`apply` on a synced workload will be **reverted** by dev's
`selfHeal`, or show as **OutOfSync drift** on prod. This includes the converter's
replica count — KEDA owns that at runtime (A7), so the overlay `replicas:` is just
the bootstrap value and Argo won't fight KEDA over it as long as we don't also set
it by hand. To change something, change git.

---

## 9. Status / readiness

- B1 ships the GitOps **machinery** (Argo install values + two Applications + this
  doc). The CD tag-bump flow (§6) is the operator's to implement.
- Runtime verification (Argo UI showing the Application tree syncing) is deferred to
  the next live cluster re-apply — the cluster is currently torn down. The
  Application CRDs and Helm values are the reviewable artifacts now.
