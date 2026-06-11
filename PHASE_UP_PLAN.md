# PHASE_UP_PLAN.md — VidCast Hardening & Differentiation

> **Status: Sprint 0 deliverable. PLAN ONLY. No code has been written.**
> This document is the sign-off gate for everything that follows. Nothing in
> Sprints 1–5 starts until the operator explicitly approves (and answers the open
> questions in §6). Honest dissent is in §7 — read it before signing.

> **Author's framing note.** I read `TECHNICAL_ANALYSIS.md`, the two project
> memories, the live source (`gateway storage/util.py`, `converter consumer.py`,
> `terraform/environments/dev/main.tf`), and CLAUDE.md before writing this. The
> plan is grounded in the *actual* current state, not the idealised one:
> **the EKS cluster is currently TORN DOWN** (destroyed 2026-06-03 for cost
> savings; state backend + tfvars + ECR images preserved for a ~20-min
> re-apply). The app is feature-complete and was E2E-verified on `main` at
> `c36b319`. That teardown fact materially changes the cost calculus of Part A5
> and is the spine of my pushback in §7.

---

## 0. How to read this document

| Section | What it answers |
|---|---|
| §1 Executive summary | The non-technical "why" and "what" |
| §2 Scope, sequencing, dependency graph | What we build, in what order, and why that order |
| §3 Trade-off matrices | Every non-obvious decision, scored |
| §4 Risk register (per sprint) | What breaks and how we prevent/detect it |
| §5 Rollback strategy (per sprint) | How we undo each change if staging breaks |
| §6 Open questions | What I need from the operator **before** Sprint 1 |
| §7 What I would push back on | Where I think the prompt is wrong/over-scoped |
| §8 Revised readiness table | Where each capability moves, sprint by sprint |
| §9 Per-sprint review-gate checklist | The one-page sign-off ritual |

---

## 1. Executive summary (for a non-technical stakeholder)

VidCast already works: a user uploads a video, the system pulls the audio out,
and emails them a download link. It already runs on professional cloud
infrastructure (AWS), with automated security scanning, monitoring, and a login
system with user roles. An independent technical review rated it "well above
average" for a portfolio project.

This phase does two things.

**First, it closes the known gaps** that separate "great demo" from "could run
a real business." Today, if the messaging system hiccups at the wrong moment, a
user's upload could be silently lost; the databases run *inside* the cluster
(so they vanish if the cluster is rebuilt); and secrets are managed by hand. We
fix all of that by adopting the same managed, durable services a real company
would use, and by adding a "transactional outbox" — a safety ledger that
guarantees no upload event is ever dropped, even during an outage.

**Second, it adds five capabilities that make VidCast genuinely stand out** from
peer projects: automated "GitOps" deployments (the system deploys itself from
git, with an approval gate); automated policy enforcement (the cluster refuses
to run insecure containers); a live cost dashboard answering "what does this
cost to run?"; reliability targets with automatic alerting when we're at risk of
missing them; and cryptographic proof that every running container was built by
us and not tampered with.

**The honesty commitment:** every feature we claim in the README will be backed
by code that actually does it. Anything partial is labelled "Partial" with the
reason. This matches the standard the project already sets.

**The one thing the stakeholder must understand about cost:** the "managed
services" upgrade (managed databases, managed message broker) takes the running
cost from roughly **$10/month to a few hundred dollars/month** if left on
permanently. Because this is a portfolio project, the recommended posture is to
build all of it as *code that can be turned on in ~20 minutes for a demo and
turned off again* — not to leave it running. See §7.1.

---

## 2. Scope, sequencing, and dependency graph

### 2.1 What's in (mapped to the prompt)

Part A (import from peer): A1 outbox · A2 idempotency · A3 retry/DLQ · A4
gunicorn (+ FastAPI decision) · A5 managed datastores · A6 NetworkPolicy
default-deny · A7 KEDA+HPA · A8 SBOM/SARIF/ECR hardening · A9 External Secrets
Operator · A10 Kustomize overlays.

Part B (differentiation): B1 Argo CD GitOps · B2 Kyverno policy-as-code · B3
Kubecost FinOps · B4 SLO burn-rate alerting · B5 cosign + Kyverno verify.

### 2.2 What's explicitly out (per prompt §"NOT asking for") — restated so it's on the record

- **Service mesh** (Linkerd/Istio) — parked. NetworkPolicy + Kyverno cover the
  80%. Documented as a deliberate omission in `SUPPLY_CHAIN.md` / README.
- **Multi-region** — out of scope; documented as deliberate with the trade-off
  (single-region eu-west-2 SPOF accepted for a demo; HA would need RDS
  cross-region read replica + Route53 failover + DocumentDB global cluster, all
  cost-prohibitive here).
- **Switching IaC tool** — Terraform stays.
- **Single-CI consolidation** — both GitHub Actions and Jenkins stay; the
  Jenkins manual approval gate is a strength. The Argo CD migration (B1)
  *relocates* the gate to a manifest-repo PR rather than removing it (see §2.5).

### 2.3 Execution split (non-negotiable per prompt §4)

| I implement directly | the operator writes (I provide diffs + explanation only) |
|---|---|
| Terraform modules (RDS, DocumentDB/Atlas, Amazon MQ, ElastiCache, ECR, ESO IRSA) | `.github/workflows/ci.yml` changes (SBOM, SARIF, cosign sign) |
| Helm values / installs (ESO, Kyverno, Argo CD, Kubecost, KEDA) | `.github/workflows/cd.yml` changes (open-PR-to-manifest-repo flow) |
| Kustomize `base/`+`overlays/` | `Jenkinsfile` changes (gate relocation, smoke-test additions) |
| Kyverno ClusterPolicies, Argo CD `Application` CRDs, PrometheusRules, Grafana dashboards | — |
| Application *code* changes (outbox writer, relay, idempotency lock, DLQ topology, gunicorn entrypoint) | — |
| `ExternalSecret`/`SecretStore` CRDs, NetworkPolicies, KEDA `ScaledObject`, HPA | — |

**Coupling this creates** (flagged early because it bites in Sprint 4): Kyverno
`verify-images` (mine, B5) is inert until CI actually signs images (the operator's,
B5/A8). We ship the policy in **Audit** mode first so it can't block deploys
before signing exists, then promote to Enforce only after the operator's signing job is
merged and producing signatures. Sequencing is in §2.5.

### 2.4 Dependency graph (why the sprint order is what it is)

```
A10 Kustomize ───────────────► B1 Argo CD        (Argo needs overlays to sync)
A9  ESO ─────────────────────► A5 cutover         (managed DBs need creds in SM)
A5  managed DB Terraform ────► Sprint 5 cutover   (build before flip)
A1 outbox ──► A3 DLQ ──► A2 idempotency           (outbox feeds queues; idempotency
                                                    guards redelivery from DLQ)
A8 SBOM/cosign (CI) ─────────► B5 Kyverno verify  (policy verifies what CI signs)
B2 Kyverno (Audit) ──────────► B2 Kyverno (Enforce)
A6 NetworkPolicy ◄── needs VPC CNI network-policy add-on enabled (Terraform, Sprint 1)
B4 SLO alerts ◄── needs RabbitMQ exporter + real /metrics (fixes M-2 first)
```

The prompt's Sprint 1→5 ordering respects this graph. I am keeping it. The only
re-ordering I propose: **enable the VPC CNI network-policy agent in the EKS
add-on config in Sprint 1** (Terraform), even though the NetworkPolicies
themselves land in Sprint 2 — because that add-on flag is `ForceNew`-adjacent
(changing add-on config can recycle the agent) and is cheapest to set while the
cluster is being re-applied from scratch anyway.

### 2.5 The approval-gate migration (B1) — explicit, because the prompt demands honesty here

Today: Jenkins builds → deploys to Swarm staging → smoke test → **human clicks
"approve"** → `kubectl set image` to EKS.

After B1: GitHub Actions builds + pushes image → **opens a PR** against the
manifest repo (or `apps/` dir) bumping the image tag in `overlays/prod`. Argo CD
watches that path with **auto-sync OFF for prod**. The deploy *is* the merge of
that PR.

**Why this is stronger, not weaker:**
- The gate moves from an ephemeral Jenkins button (no durable record, tied to
  one CI server's uptime) to a **git PR with reviewers, diff, CI checks, and an
  immutable audit trail**. You can see exactly which image SHA went to prod,
  who approved it, and when — forever.
- Rollback becomes `git revert` of the tag bump (Argo re-syncs to the previous
  SHA), instead of `kubectl rollout undo` (which is correct but invisible in
  git history).
- The Jenkins Swarm smoke-test stage **stays** — it just gates *opening the PR*
  rather than gating the kubectl call. Defence in depth, not replacement.

**Honest caveat:** running two gates (Jenkins smoke-test AND manifest PR) is
arguably redundant for a solo project. I keep both because the prompt says keep
both and because it's a legitimate "I understand the difference between staging
verification and prod authorisation" talking point. If the operator wants to simplify
later, the cleaner end-state is Jenkins→Swarm smoke-test→auto-open-PR, GitHub
review = the single human gate.

---

## 3. Trade-off matrices

Scoring: **1 = worst, 5 = best** on each axis (higher is always better — e.g. a
high "cost" score means *cheaper*). "Team-fit" = fit for a solo
portfolio/learning context. Weighted columns aren't summed blindly; the
recommendation paragraph states what actually drove the choice.

### 3.1 MongoDB managed choice (GridFS is the hard constraint)

| Option | Cost (mo) | Impl time | Ops complexity | Scale ceiling | Team-fit | Compliance | Learning | Notes |
|---|---|---|---|---|---|---|---|---|
| **MongoDB Atlas (M10)** | 3 (~$57/mo) | 5 | 5 | 4 | 5 | 4 | 4 | Real MongoDB → **GridFS works unchanged**. Off-AWS (PrivateLink to VPC). Free M0 tier exists for dev. |
| **Amazon DocumentDB** | 2 (~$200/mo min, t3.medium) | 3 | 3 | 4 | 2 | 5 | 4 | **GridFS partially supported** — DocumentDB emulates the Mongo API and historically had gaps around some GridFS/`fs.chunks` operations. **Must be functionally tested before trusting.** Pricey minimum. |
| **In-cluster StatefulSet (keep, gate dev-only)** | 5 (~$0, on node) | 5 | 2 | 2 | 5 | 1 | 3 | Zero new cost; no durability beyond the PVC; what we have today. |

**Recommendation: Atlas for the managed path (default per prompt), in-cluster
StatefulSet retained as `dev-only` behind `var.use_managed_datastores=false`.**
Driver: GridFS is load-bearing in VidCast (videos *and* mp3s live in GridFS) and
Atlas is genuine MongoDB, so it's zero application risk. DocumentDB's GridFS
support is the single biggest sleeper risk in Part A5 — **I will write an
explicit GridFS smoke test** (put a >255KB file so it chunks, read it back, byte
-compare) and the plan does **not** assume DocumentDB until that test passes. If
the operator prefers all-AWS for the compliance/narrative story, we run that test in
Sprint 1 and only then commit to DocumentDB. Atlas M0 (free) covers dev.

### 3.2 Broker choice

| Option | Cost (mo) | Impl time | Ops complexity | Scale ceiling | Team-fit | Compliance | Learning | Notes |
|---|---|---|---|---|---|---|---|---|
| **Amazon MQ for RabbitMQ** | 3 (~$25–30/mo single-instance; more for cluster) | 5 | 4 | 3 | 5 | 5 | 4 | **Drop-in** — same AMQP, Pika unchanged, same management API. Our DLQ/retry topology (A3) ports verbatim. |
| **Amazon MSK (Kafka)** | 1 (~$130+/mo min) | 1 | 2 | 5 | 1 | 5 | 5 | Would require **rewriting every producer/consumer** from Pika→Kafka. Massive scope creep. Huge learning value, wrong phase. |
| **Clustered Helm RabbitMQ (in-cluster)** | 5 (~$0) | 4 | 2 | 3 | 4 | 1 | 3 | Free; clustering on a single node is theatre (no real HA on one node). |

**Recommendation: Amazon MQ for RabbitMQ (default per prompt), in-cluster Helm
RabbitMQ retained dev-only behind the toggle.** Driver: it's the only managed
option that doesn't force an application rewrite — A1/A2/A3 are designed against
AMQP semantics and Amazon MQ preserves them. MSK is explicitly rejected as
out-of-scope scope-creep (the prompt asks for reliability patterns, not a
messaging-platform migration); I document it as the "if this were event-sourced
at scale" path. **Single-instance Amazon MQ for cost**; note that
single-instance is not HA — documented honestly, cluster mode is a one-flag
change if needed for a demo.

### 3.3 Outbox relay mechanism ⚠️ (the prompt's default is, I believe, wrong — see §7.2)

> **Terminology fix:** the prompt says "goroutine" — that's Go. VidCast is
> Python. The in-process equivalent is a background **thread** (or
> `APScheduler`). This matters for the conclusion.

| Option | Cost (mo) | Impl time | Ops complexity | Scale ceiling | Team-fit | Compliance | Learning | Correctness under our topology |
|---|---|---|---|---|---|---|---|---|
| **In-process thread in gateway** | 5 | 5 | 4 | 2 | 4 | 3 | 3 | ❌ **Broken by default.** Gateway runs `gunicorn -w 4` (A4) → 4 worker processes → **4 relay threads** all scanning `outbox` and double/quadruple-publishing. Needs a Mongo-level claim/lock or single-worker carve-out. |
| **Sidecar container in gateway pod** | 5 | 4 | 3 | 2 | 4 | 3 | 4 | Scales with gateway replicas → N relays → same multi-publisher problem unless leader-elected. Shares pod lifecycle. |
| **Separate single-replica Deployment** | 5 (~$0, tiny) | 3 | 4 | 4 | 5 | 4 | 5 | ✅ **Correct by construction.** One replica = one publisher = no double-send. Scales/restarts independently. Idempotent consumers (A2) make even an occasional double-publish during rollover harmless. |

**Recommendation: separate single-replica Deployment (`outbox-relay`),
overriding the prompt's "default in-process".** Driver: correctness. The outbox
pattern's entire value is "exactly-this-event, eventually." Running the relay
inside a multi-worker gunicorn process re-introduces the duplicate-publish
problem the pattern exists to prevent. A single-replica deployment makes the
invariant structural rather than something we have to defend with a distributed
lock. It also reads better in an interview ("I separated the relay because the
app server is multi-process") than explaining a Mongo lock retrofitted onto a
thread. Cost is negligible (it's a 50m/64Mi pod). **Belt-and-braces:** the relay
marks rows `published_at` and the consumers are idempotent (A2), so a duplicate
during a relay pod restart is a no-op, not a double-email. See §7.2.

### 3.4 Flask → FastAPI (the prompt asks me to propose, with default = stay on Flask + gunicorn now)

| Option | Cost | Impl time | Ops complexity | Scale ceiling | Team-fit | Compliance | Learning | Notes |
|---|---|---|---|---|---|---|---|---|
| **gunicorn now, FastAPI never** | 5 | 5 | 5 | 3 | 4 | 3 | 2 | Fixes M-1 immediately. Sync framework caps the streaming-upload concurrency story. |
| **gunicorn now, FastAPI as a follow-on phase** | 5 | 4 | 4 | 4 | 5 | 3 | 5 | Get the prod-server win this phase; bank async migration as a clean, self-contained future phase with real before/after load numbers. |
| **FastAPI migration now** | 4 | 1 | 2 | 5 | 2 | 3 | 5 | Rewrites both web services mid-reliability-sprint. High delivery risk; competes for attention with outbox/DLQ which matter more. |

**Recommendation: gunicorn now (Sprint 2), FastAPI as an explicitly-scoped
follow-on phase (NOT this phase).** Driver: delivery risk vs. value timing. The
production-server fix (gunicorn `-w` workers + a proper WSGI entrypoint) is a
one-file change that closes M-1 today. A Flask→FastAPI rewrite is genuinely
valuable for the upload-streaming path (`async` + `UploadFile` streaming beats
Werkzeug's buffer-to-`/tmp`), and it's a strong learning artifact — but doing it
*during* the reliability sprint dilutes both. I'll write the gunicorn entrypoint
so the eventual FastAPI swap is a contained blast radius (keep `server` importable,
keep route handlers thin). The follow-on phase should produce a load-test
before/after (locust/k6) so the async benefit is *measured*, not asserted.

### 3.5 Argo CD vs Flux

| Option | Cost | Impl time | Ops complexity | Scale ceiling | Team-fit | Compliance | Learning | Notes |
|---|---|---|---|---|---|---|---|---|
| **Argo CD** | 5 | 4 | 3 | 4 | 5 | 4 | 5 | Has a UI (huge for demos/screenshots), `Application` CRD model is intuitive, sync-waves, manual-sync gate maps perfectly to the prod approval requirement. Heavier footprint. |
| **Flux** | 5 | 3 | 4 | 4 | 3 | 4 | 4 | Lighter, more "pure GitOps", no first-party UI (needs Weave GUI/CLI). Kustomize-native. Less visual for a portfolio. |
| **Both / neither (keep kubectl CD)** | 5 | 5 | 5 | 2 | 2 | 2 | 1 | Status quo; no GitOps story. |

**Recommendation: Argo CD (default per prompt).** Driver: it's a *portfolio*
project — the Argo UI gives screenshottable, demoable evidence of sync state,
drift detection, and the manual-sync prod gate, which is exactly the
differentiation B1 is for. Flux is arguably more elegant but invisible. The
manual-sync-for-prod / auto-sync-for-dev split is a built-in first-class concept
in Argo (`syncPolicy.automated` present vs absent).

### 3.6 Kubecost OSS vs OpenCost vs AWS Cost Explorer + custom exporter

| Option | Cost | Impl time | Ops complexity | Scale ceiling | Team-fit | Compliance | Learning | Notes |
|---|---|---|---|---|---|---|---|---|
| **Kubecost (free OSS)** | 4 | 4 | 3 | 3 | 5 | 3 | 4 | Turnkey UI + Grafana data source, allocation by namespace/label, AWS spot/on-demand split. Free tier limits: 15-day metric retention, single cluster — fine here. |
| **OpenCost** | 5 | 3 | 2 | 3 | 4 | 3 | 4 | The CNCF core Kubecost is built on; more DIY for dashboards, no polished UI. More "I built it from primitives" cred, more work. |
| **AWS Cost Explorer + custom exporter** | 4 | 2 | 2 | 4 | 2 | 4 | 5 | Billing-accurate (real invoice data) but no per-pod/per-namespace granularity without heavy custom tagging+ETL. Most work. |
| **Hybrid (chosen): Kubecost for in-cluster allocation + CE/CUR for ground-truth $** | 4 | 3 | 3 | 4 | 5 | 4 | 5 | Use Kubecost for "cost-per-minute-converted" and per-service breakdown; reconcile the total against the real AWS bill so the README number is *honest*. |

**Recommendation: Kubecost OSS as the primary (default per prompt), reconciled
against AWS Cost Explorer for the headline number.** Driver: Kubecost gives the
per-service / cost-per-conversion granularity B3 needs out of the box, but its
node-cost model is an *estimate*. To honour the honesty principle, the README's
"What does VidCast cost?" number will be cross-checked against the actual AWS
bill, and the dashboard will label estimated vs. billed. OpenCost is the same
engine with more assembly; not worth it here.

### 3.7 Cosign keyless vs key-based vs Notary v2

| Option | Cost | Impl time | Ops complexity | Scale ceiling | Team-fit | Compliance | Learning | Notes |
|---|---|---|---|---|---|---|---|---|
| **Cosign keyless (GitHub OIDC + Fulcio/Rekor)** | 5 | 4 | 4 | 5 | 5 | 5 | 5 | **No private key to manage** — identity = the GitHub Actions OIDC token, logged in the Rekor transparency log. Kyverno `verify-images` matches on the repo-scoped identity. Modern SLSA-aligned story. |
| **Cosign key-based** | 5 | 4 | 3 | 4 | 3 | 4 | 4 | A keypair you must store (KMS/secret) and rotate — reintroduces the secret-management problem A9 just solved. |
| **Notary v2 / notation** | 5 | 2 | 2 | 4 | 2 | 4 | 3 | Less ubiquitous tooling/docs, weaker Kyverno integration story than cosign. |

**Recommendation: cosign keyless (default per prompt) using GitHub Actions OIDC.**
Driver: it's the strongest *and* the simplest here — no key to store (consistent
with A9's "get secrets out of files" thesis), and the verifiable chain (Fulcio
cert → Rekor log → Kyverno policy scoped to
`repo:<YOUR_GITHUB_ORG>/vidcast`) is exactly the SLSA narrative B5/
`SUPPLY_CHAIN.md` is meant to demonstrate. **Prerequisite I'll flag loudly:**
keyless verification at admission requires the cluster to reach Fulcio/Rekor
(public sigstore) — fine on EKS with egress; would need the NetworkPolicy DNS/
egress carve-out (A6) to not block it.

---

## 4. Risk register (per sprint)

Severity: 🔴 high · 🟠 medium · 🟢 low. Each row: risk → mitigation → detection.

### Sprint 1 — Foundation (A5 Terraform, A9 ESO, A10 Kustomize)

| # | Sev | Risk | Mitigation | Detection |
|---|---|---|---|---|
| 1.1 | 🔴 | Managed-datastore Terraform applied → **surprise AWS bill** (RDS Multi-AZ + DocumentDB + Amazon MQ + ElastiCache ≈ hundreds/mo) | Build behind `var.use_managed_datastores`, **default false**; do NOT `apply` the managed modules in Sprint 1 — `terraform plan` only, reviewed for cost; a `terraform-cost` note in the review gate | AWS Budgets alert at $50; review the plan's resource list before any apply |
| 1.2 | 🔴 | DocumentDB GridFS incompatibility discovered late | Sprint 1 spike: stand up smallest DocumentDB, run the GridFS chunk test, decide DocumentDB vs Atlas *before* writing the rest of A5 | Test fails → fall back to Atlas (already the default) |
| 1.3 | 🟠 | A10 Kustomize refactor silently changes a rendered manifest (drops a securityContext, env, probe) | `kubectl kustomize overlays/dev > rendered.yaml` and **diff against the current raw manifests**; CI `kustomize build` check | Pre/post render diff must be empty except intended changes |
| 1.4 | 🟠 | ESO misconfig → pods can't get secrets → CrashLoop on next rebuild | Keep gitignored `secret.yaml` working in parallel until ESO is proven; flip per-service | `kubectl describe externalsecret` status `SecretSynced` |
| 1.5 | 🟢 | IRSA role for ESO over-scoped | Scope the Secrets Manager IAM policy to `vidcast/*` ARNs only | `terraform plan` policy review |

### Sprint 2 — Reliability core (A1, A2, A3, A4, A6, A7)

| # | Sev | Risk | Mitigation | Detection |
|---|---|---|---|---|
| 2.1 | 🔴 | Outbox relay double-publishes (multi-worker) | Separate single-replica relay (§3.3) + idempotent consumers (A2) + `published_at` marker | Duplicate-email count; outbox rows stuck `unpublished` |
| 2.2 | 🔴 | A6 default-deny NetworkPolicy **without** the VPC CNI network-policy agent → policies silently do nothing (declarative-only) | Enable the add-on in Sprint 1 Terraform; **verify enforcement** with a deny test (exec into a pod, `curl auth:5000`, expect timeout) | Negative test: blocked call must hang/fail |
| 2.3 | 🔴 | Default-deny breaks DNS / the app entirely | Land NetworkPolicies in **Audit mindset**: apply allow-rules first, default-deny last; explicit DNS egress carve-out to kube-dns; per-service allow matrix written before deny | Smoke test after each policy; rollback = delete the deny policy |
| 2.4 | 🟠 | KEDA scale-to-zero + HPA both target the **same** Deployment → fighting controllers | Prompt already mandates the fix: KEDA→converter, HPA→gateway (different Deployments). Verify no overlap in `scaleTargetRef` | `kubectl get hpa,scaledobject` — distinct targets |
| 2.5 | 🟠 | DLQ topology misconfigured → messages loop forever (poison) or vanish | Bounded `MAX_RETRIES`; retry queue TTL dead-letters *back* to main; terminal DLQ via `vidcast.dlx`; consumers do **not** consume retry queues | Inspect queue depths; a message with retry-count > MAX lands in DLQ, not main |
| 2.6 | 🟠 | gunicorn worker count starves the 2-vCPU node (converter already at 2 replicas for CPU) | Conservative `-w 2` for gateway/auth; set against resource limits already tuned in U3 | Pod OOM/CPU throttle metrics |
| 2.7 | 🟢 | Redis (A2) becomes a new SPOF | Dev: in-cluster Redis; prod: ElastiCache single-AZ acceptable per prompt; lock TTL short so a Redis outage degrades to "occasional duplicate", not "stuck" | Redis up/down alert |

### Sprint 3 — Differentiation core (B1 Argo CD, B2 Kyverno)

| # | Sev | Risk | Mitigation | Detection |
|---|---|---|---|---|
| 3.1 | 🔴 | Argo CD auto-sync (dev) fights manual `kubectl` changes → drift war / surprise reverts | Declare Argo the owner of app manifests once cutover; stop hand-`kubectl apply` for synced apps; document the new workflow in GITOPS.md | Argo "OutOfSync" / unexpected self-heal events |
| 3.2 | 🔴 | Kyverno in **Enforce** too early blocks all deploys (e.g. require-non-root catches a stray pod) | Prompt-mandated: **Audit mode for one PR cycle**, fix violations, *then* Enforce; verify-images stays Audit until cosign signing exists | `kubectl get policyreport` shows violations before promotion |
| 3.3 | 🟠 | Argo prod app auto-syncs by accident (gate bypassed) | `syncPolicy.automated` **absent** on prod Application; codify in review checklist; RBAC who can click "Sync" | Inspect prod Application spec; sync history |
| 3.4 | 🟠 | Manifest-repo PR flow (CD change, the operator's) not ready → Argo has nothing to sync | Argo can point at the same repo's `overlays/prod` initially (in-repo), defer separate manifest repo if the operator prefers; decision in §6 | — |
| 3.5 | 🟢 | Kyverno admission webhook latency / availability affects all pod creates | Kyverno HA not needed at this scale; `failurePolicy: Ignore` during Audit, revisit for Enforce | Webhook latency metric |

### Sprint 4 — Differentiation polish (B3 Kubecost, B4 SLO alerts, B5 cosign, A8 SBOM/SARIF)

| # | Sev | Risk | Mitigation | Detection |
|---|---|---|---|---|
| 4.1 | 🔴 | Kyverno `verify-images` Enforce blocks deploys because not all images are signed (esp. **frontend**, which CI doesn't build) | Add frontend to signing scope (or exempt it explicitly in policy with a documented reason); promote verify-images to Enforce **only** after every deployed image is signed | Audit policyreport: any unsigned deployed image |
| 4.2 | 🟠 | SLO numbers are meaningless on a single-node, frequently-torn-down cluster (teardowns instantly blow a 99.9% budget) | Label SLOs **"demonstrative"** in SLO.md; compute burn rate over *uptime windows*, document the single-node caveat honestly | n/a — documentation honesty |
| 4.3 | 🟠 | B4 requires real metrics; M-2 says gateway has **no /metrics** and **no RabbitMQ exporter** | Fix M-2 first in Sprint 4: re-add a `/metrics` endpoint (request + queue gauges) and deploy the RabbitMQ Prometheus plugin; only then write the burn-rate rules | Prometheus targets all `up`; the old dangling alerts replaced |
| 4.4 | 🟠 | cosign keyless verify can't reach Fulcio/Rekor (egress blocked by A6) | A6 egress carve-out includes sigstore endpoints; test verify in Audit first | Kyverno verify failures with network errors |
| 4.5 | 🟢 | SBOM/SARIF upload needs `security-events: write` + GHAS enabled on the repo | Confirm GitHub Advanced Security availability (public repo = free) in §6 | SARIF tab populates |

### Sprint 5 — Cutover + README

| # | Sev | Risk | Mitigation | Detection |
|---|---|---|---|---|
| 5.1 | 🔴 | Flipping `use_managed_datastores=true` in prod = **the big bill** + a real data migration (GridFS dump/restore, Postgres `pg_dump`, queue drain) | See §7.1 — recommend **NOT** leaving it on; cutover only inside a timed demo window then destroy. Migration runbook with dump/restore + GridFS chunk verify; bcrypt seed must precede auth image (known hazard from memory) | Post-cutover E2E smoke (login→upload→convert→email→download) |
| 5.2 | 🔴 | Decommissioning in-cluster stateful Helm charts in prod overlay before data is migrated = data loss | Migrate-then-decommission ordering; decommission only in `overlays/prod`, dev keeps Helm charts; snapshot before delete | Data byte-compare post-migration |
| 5.3 | 🟠 | README rewrite over-claims (violates honesty principle) | Every claim cross-checked against shipped code; readiness table audited; "Partial" where partial | Self-review + the §9 gate |

---

## 5. Rollback strategy (per sprint)

The governing principle: **every change is reversible without touching prod data
until Sprint 5.** Sprints 1–4 add capabilities behind toggles/Audit modes; the
only destructive sprint is 5, which gets a snapshot-first runbook.

| Sprint | Change | How to undo if staging breaks |
|---|---|---|
| **1** | A5 managed Terraform | It's `plan`-only / behind a `false` toggle — nothing applied, nothing to roll back. If a managed module *was* applied for the GridFS spike: `terraform destroy -target=module.documentdb` (and friends). State backend untouched. |
| **1** | A9 ESO | Per-service flip; the gitignored `secret.yaml` is kept until ESO proven. Roll back = `kubectl apply` the old secret + remove the `ExternalSecret`. `helm uninstall external-secrets`. |
| **1** | A10 Kustomize | The raw manifests stay in git history; `git revert` the overlay commit and `kubectl apply -f src/*/manifest/` as before. Rendered-diff gate means dev knows it's equivalent. |
| **2** | A1 outbox | Feature-flag `OUTBOX_ENABLED`; off = gateway publishes directly (today's path) and the compensating `fs.delete` stays as the fallback. Relay deployment scaled to 0. |
| **2** | A2 idempotency | `IDEMPOTENCY_ENABLED` flag; off = consumers behave as today. Redis outage is already a graceful-degrade, not a hard dep. |
| **2** | A3 DLQ | Topology is additive (new exchanges/queues). Roll back = consumers point back at plain `video`/`mp3`; delete the `vidcast.dlx` exchange. Existing messages drain normally. |
| **2** | A4 gunicorn | Dockerfile `CMD` revert to `python server.py`; one-line, one-image rebuild. |
| **2** | A6 NetworkPolicy | `kubectl delete networkpolicy --all -n <ns>` instantly restores open networking (default-allow). This is *the* fastest rollback in the plan — and why default-deny is applied last. |
| **2** | A7 KEDA/HPA | `kubectl delete scaledobject/hpa`; replicas return to the static manifest count. |
| **3** | B1 Argo CD | Disable auto-sync (`syncPolicy: {}`); Argo stops reconciling; fall back to `kubectl`/CD-as-before. `helm uninstall argocd` removes it entirely (apps keep running — Argo is control-plane only). |
| **3** | B2 Kyverno | Set policy `validationFailureAction: Audit` (un-enforce) or `helm uninstall kyverno`. Audit mode means there's nothing to roll back during the trial cycle. |
| **4** | B3 Kubecost | `helm uninstall kubecost`; pure observability, zero app impact. |
| **4** | B4 SLO alerts | `kubectl delete prometheusrule`; restores prior alerting. The M-2 metrics fixes are additive (new `/metrics`, new exporter) — revert the gateway image + `helm uninstall` the exporter. |
| **4** | B5 cosign verify | Kyverno `verify-images` → Audit or delete; CI signing job is the operator's (revert the workflow commit). |
| **4** | A8 SBOM/SARIF | CI-only (the operator); revert the workflow commit. No cluster impact. |
| **5** | Cutover to managed | **Snapshot first** (RDS snapshot, GridFS `mongodump`, `pg_dump`). Roll back = flip `use_managed_datastores=false`, re-point services at in-cluster charts, restore from dump if needed, `terraform destroy` the managed modules to stop the bill. The in-cluster charts are *not deleted* until a post-cutover soak passes. |

---

## 6. Open questions for the operator (need answers before Sprint 1)

1. **Cost posture (blocking — see §7.1).** Do you want managed datastores left
   *running* (steady ~$300–400/mo all-in), or built-as-code and only spun up for
   timed demos then destroyed? My strong recommendation is the latter. This
   changes Sprint 5's "flip to true in prod" from "permanent" to "demo-window."
2. **MongoDB target:** Atlas (default, zero GridFS risk, off-AWS) or DocumentDB
   (all-AWS narrative, but gated on the Sprint-1 GridFS compatibility test)?
3. **Manifest repo for B1:** separate dedicated repo (`vidcast-manifests`) or an
   `apps/` directory *in this repo*? Separate repo is the textbook GitOps
   pattern; same-repo is simpler for a solo project. Affects A10's layout.
4. **GitHub Advanced Security / SARIF:** is the repo public (free GHAS) or
   private (needs a license for code-scanning SARIF upload)?
5. **Cluster availability for testing:** the cluster is torn down. Do you want me
   to (a) develop everything against a local kind/k3d cluster and only validate
   on EKS in batches, or (b) re-apply EKS for the duration of this phase? (a) is
   far cheaper; (b) is higher-fidelity. I lean (a) for Sprints 1–4 code/config,
   (b) for the Sprint-5 cutover validation only.
6. **Redis for dev (A2):** in-cluster Redis Helm chart, or skip dev Redis and
   make idempotency a no-op locally (flag off)?
7. **Amazon MQ sizing:** single-instance (cheap, not HA) or cluster (HA, ~3×
   cost)? I default to single-instance with an honest "not HA" note.
8. **Do you want the Jenkins gate to stay as a *second* gate** after B1, or
   collapse to Jenkins-smoke-test → auto-open-PR → GitHub-review-as-single-gate
   (my preferred simplification, §2.5)?
9. **FastAPI:** confirm you're happy parking it as a *named follow-on phase*
   (with a load-test deliverable) rather than doing it now?

---

## 7. What I would push back on (honest dissent — required, not optional)

### 7.1 🔴 The biggest one: managed datastores contradict the project's own cost decision

The memories record that the **cluster was deliberately torn down on 2026-06-03
to save money**, preserving everything for a ~20-minute re-apply. That is a
*good* instinct for a portfolio project. Part A5 then proposes RDS **Multi-AZ**,
DocumentDB (or Atlas M10), **Amazon MQ**, and ElastiCache — and Sprint 5 says
"flip `use_managed_datastores` to true in prod." Left running, that's roughly:

| Service | Cheapest realistic prod-ish | ~$/mo |
|---|---|---|
| RDS PostgreSQL Multi-AZ (db.t3.micro) | Multi-AZ doubles the instance | ~$30–60 |
| DocumentDB (t3.medium min) **or** Atlas M10 | — | ~$200 / ~$57 |
| Amazon MQ RabbitMQ (single mq.t3.micro) | cluster ≈ 3× | ~$25–30 |
| ElastiCache Redis (cache.t3.micro) | — | ~$12–15 |
| **Plus the EKS cluster itself** | already ~$150 | ~$150 |

That's a **15–40× jump** over today's ~$10 staging cost, on a project that was
just torn down *for $10*.

**My recommendation:** build A5 in full as Terraform behind the toggle (it's
genuinely valuable code and a strong portfolio artifact — "I can stand up the
managed-services version on demand"), but **do not leave it running, and reframe
Sprint 5** from "permanently flip prod to managed" to "demo-window cutover:
`apply` → migrate → record the screenshots/numbers → `destroy`." This keeps the
honesty (the managed path *works* and is *demonstrated*) without a standing bill.
RDS Multi-AZ specifically: use single-AZ for the demo and *document* that
Multi-AZ is a one-flag change — Multi-AZ on a demo you tear down nightly is pure
cost for zero observed benefit. **This is question 6.1 and I'd like an explicit
decision.**

### 7.2 🟠 The outbox relay default ("in-process goroutine") is wrong for this stack

Covered in §3.3. Two concrete problems with the prompt's stated default: (1)
"goroutine" is Go — VidCast is Python; (2) more importantly, the gateway will run
multi-process under gunicorn (A4), so an in-process relay = N concurrent
publishers = the duplicate-publish bug the outbox exists to kill. I'm
overriding the default to a **separate single-replica deployment**. If you
specifically want the in-process variant for learning reasons, we *must* add a
Mongo-level claim (findAndModify lease) — say so and I'll do that instead, but
I'd be building a distributed lock to work around a self-inflicted problem.

### 7.3 🟠 The scope is ~2–4 months of senior work, not a sprint or two

A1–A10 + B1–B5 is **15 substantial workstreams**, each with code + Terraform/
Helm + an `_EXPLAINED.md`. Realistically each sprint here is 1–3 weeks of
focused work. That's fine if the goal is a sustained portfolio build — but if
there's a deadline (job application, course submission), I'd **prioritise for
signal-per-effort**:
- **Highest signal, do first:** A1/A2/A3 (reliability story), A6 (security
  story), B1 (GitOps story), B2 (policy story). These four are what make
  reviewers say "this person operates production systems."
- **High signal, moderate effort:** A9 ESO, A8 supply-chain, B5 cosign.
- **Lower signal-per-effort for a *demo*:** A5 managed datastores (expensive,
  and "I used RDS" is less differentiating than "I built a verified supply
  chain"), B3 Kubecost (nice, but the number is small and a bit theatrical on a
  single node), B4 SLOs (great concept, but the numbers are demonstrative on a
  torn-down single node — §4.2).
- If forced to cut: I'd cut **A5's permanent cutover** (keep it as on-demand
  code) before anything else.

I'm not refusing any of it — the prompt is the prompt — but a senior engineer
should tell you where the marginal hour pays off most. If you want the full set,
we do the full set in the given order.

### 7.4 🟢 SLO targets are aspirational on this topology — say so

99.9% availability / 5-min conversion / 99% email-success are good *definitions*,
but on a **single-node cluster that gets torn down for cost**, the measured
error budget is fiction (every teardown = 100% of the budget gone). B4 is still
worth doing — the *machinery* (multi-window multi-burn-rate PrometheusRules, the
error-budget dashboard) is the portfolio artifact. SLO.md will label the targets
"demonstrative" and explain the single-node caveat rather than pretending the
numbers are an operated reality. That's the honesty principle applied to SLOs.

### 7.5 🟢 "Replace the compensating-GridFS-delete with the outbox" — keep both, briefly

A1 says the outbox "replaces the current compensating-GridFS-delete pattern
(which is good but only half the solution)." I'd **keep the compensating delete
as a belt-and-braces fallback during the transition** (behind the same flag),
not rip it out. Once the outbox is proven in staging over a soak period, then
remove the now-dead compensation path in a clean follow-up commit. Ripping it out
in the same change that introduces the outbox means a single outbox bug can
orphan GridFS objects with no safety net.

### 7.6 🟢 Two CD gates (Jenkins + Argo manual-sync) is redundant for a solo repo

Flagged in §2.5/§6.8. I'll keep both because you asked, but the genuinely clean
end-state is one human gate (the manifest PR), with Jenkins demoted to "run the
Swarm smoke test and open the PR on success." Happy either way — just noting the
redundancy so it's a *choice*, not an accident.

---

## 8. Revised readiness table (movement per sprint)

Legend: ❌ absent · 🟡 Partial · ✅ Complete (**only marked ✅ when demonstrably
shipped + verified — in this PLAN everything is a *target*, written as the
status we intend to reach by the end of that sprint**). Baseline column = today,
per `TECHNICAL_ANALYSIS.md`.

| Capability | Today | S1 | S2 | S3 | S4 | S5 | Refs |
|---|---|---|---|---|---|---|---|
| Event durability (no lost uploads) | 🟡 compensating-delete only | 🟡 | ✅ outbox+relay | ✅ | ✅ | ✅ | A1 |
| Idempotent / retry-safe consumers | ❌ | ❌ | ✅ claim-once+release | ✅ | ✅ | ✅ | A2 |
| Retry/DLQ topology | ❌ NACK-requeue loop | ❌ | ✅ retry+DLQ+max | ✅ | ✅ | ✅ | A3, fixes L-4/poison |
| Production app server | ❌ Werkzeug dev | ❌ | ✅ gunicorn | ✅ | ✅ | ✅ | A4, M-1 |
| Async framework (FastAPI) | ❌ | ❌ | ❌ (deferred) | ❌ | ❌ | ❌ → *named follow-on* | A4 |
| Durable Postgres | ❌ Deployment no-PVC | 🟡 RDS coded (off) | 🟡 | 🟡 | 🟡 | ✅ RDS (demo-window) | A5, M-3 |
| Managed Mongo/GridFS | ❌ in-cluster | 🟡 Atlas/DocDB coded+tested | 🟡 | 🟡 | 🟡 | ✅ (demo-window) | A5 |
| Managed broker | ❌ in-cluster | 🟡 Amazon MQ coded | 🟡 | 🟡 | 🟡 | ✅ (demo-window) | A5 |
| Managed Redis | ❌ none | 🟡 ElastiCache coded | 🟡 | 🟡 | 🟡 | ✅ (demo-window) | A5, A2 |
| NetworkPolicy default-deny (enforced) | ❌ | 🟡 CNI agent on | ✅ deny+allow+DNS | ✅ | ✅ | ✅ | A6, M-5 |
| Autoscaling (KEDA+HPA) | ❌ manual | ❌ | ✅ KEDA(conv)+HPA(gw) | ✅ | ✅ | ✅ | A7, L-1 |
| Supply chain: SBOM + SARIF | 🟡 Trivy gate only | 🟡 | 🟡 | 🟡 | ✅ SBOM+SARIF | ✅ | A8 |
| ECR hardening (immutable/scan/CMK/lifecycle) | 🟡 basic ECR | 🟡 coded | 🟡 | 🟡 | ✅ | ✅ | A8 |
| External secret management | ❌ gitignored files | 🟢 ESO+Parameter Store (strong-partial: app secrets done $0 standing; broker creds pending) | 🟢 | 🟢 | 🟢 | 🟢 | A9, H-4 |
| App manifests as Kustomize | ❌ raw per-svc | ✅ base+overlays | ✅ | ✅ | ✅ | ✅ | A10 |
| GitOps (Argo CD) | ❌ kubectl CD | ❌ | ❌ | ✅ Argo+gate | ✅ | ✅ | B1 |
| Policy-as-code (Kyverno) | ❌ | ❌ | ❌ | ✅ Audit→Enforce | ✅ | ✅ | B2 |
| FinOps cost dashboard | ❌ | ❌ | ❌ | ❌ | ✅ Kubecost+panel | ✅ | B3 |
| SLO burn-rate alerting | ❌ (dangling alerts) | ❌ | ❌ | ❌ | ✅ (demonstrative) | ✅ | B4, M-2 |
| Image signing + admission verify | ❌ | ❌ | ❌ | ❌ | ✅ cosign+Kyverno | ✅ | B5 |
| Monitoring reflects reality (no dead alerts) | ❌ M-2 dead scrape/alerts | ❌ | ❌ | ❌ | ✅ /metrics+rabbit exporter | ✅ | M-2 |
| Frontend built+signed by CI | ❌ manual ECR push | ❌ | ❌ | ❌ | 🟡/✅ (q.4.1) | ✅ | M-6 |
| Multi-region | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ *deliberate omission* | out-of-scope |
| Service mesh | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ *deliberately parked* | out-of-scope |

> **Ratchet rule (honesty principle):** I will only move a cell to ✅ in the
> living version of this table when the capability is shipped *and* I've run the
> verification named in §4/§5. Until then it stays 🟡. Nothing is ✅ on the
> strength of "the code exists."

---

## 9. Per-sprint review-gate checklist (the sign-off ritual)

After each sprint I produce a **one-page review note** containing exactly:

1. **What shipped** (files touched, separated into "I implemented" vs "diffs for
   the operator to apply to CI/CD/Jenkins").
2. **Proof it works** — the specific verification command(s) from §4/§5 and
   their output (e.g. the NetworkPolicy deny-test hanging; the duplicate-email
   count being zero; `kubectl get policyreport`).
3. **Readiness-table delta** — which cells moved and the evidence.
4. **New `_EXPLAINED.md` files** created (one per new code/config file —
   line-by-line + 3 interview questions + dependency map, per the existing
   convention; kept gitignored as local study material per the project's
   established `.gitignore:64` decision).
5. **Cost impact** of anything applied (should be ~$0 until Sprint 5).
6. **Open risks carried forward.**

the operator signs off → next sprint starts. No sprint starts on an unsigned predecessor.

---

## 10. Documentation deliverables tracking

| Doc | Produced in | Status |
|---|---|---|
| `PHASE_UP_PLAN.md` | Sprint 0 | ✅ this document |
| `_EXPLAINED.md` per new file | every sprint | pending |
| `SUPPLY_CHAIN.md` | Sprint 4 (B5/A8) | pending |
| `SLO.md` | Sprint 4 (B4) | pending |
| `GITOPS.md` | Sprint 3 (B1) | pending |
| Updated `TECHNICAL_ANALYSIS.md` / project summary + "Differentiation" section | Sprint 5 | pending |
| README rewrite (platform-story-first) | Sprint 5 | pending |

---

## 11. Sign-off

**This plan is complete and awaiting the operator's review.** I have **not** written any
implementation code, Terraform, Helm values, manifests, or workflow changes.

**Before Sprint 1 begins I need answers to §6 (especially 6.1 cost posture and
6.2 Mongo target), and acknowledgement of the §7 pushbacks — in particular that
Sprint 5 is reframed to a demo-window cutover rather than a permanent
managed-prod, and that the outbox relay is a separate deployment, not
in-process.**

Stop. Awaiting sign-off.
