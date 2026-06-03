# Architectural Decisions — RBAC / Notifications / Admin branch

Trade-off documentation for the `feature/rbac-and-notifications` branch. Each
decision follows the same shape: **what we chose → the alternatives → the
trade-off we accepted → where it breaks → the real fix at scale.**

---

## 1. bcrypt now, alongside RBAC (not deferred)

We added bcrypt password hashing in the same change as the role model, rather than
shipping RBAC on the existing plaintext passwords and hashing "later."

The alternative was to defer: keep the plaintext comparison, add only the `role`
column and JWT claim now. It's less code and avoids a coordinated DB+image
migration.

The trade-off we accepted is a one-time migration cost: bcrypt seeds in `init.sql`,
a `checkpw` path in `/login`, and a merge-time reseed of live Postgres — all of
which must land together or logins break.

This would be the wrong call if the password store were large and live (re-hashing
millions of users needs a dual-read "verify-then-upgrade-on-login" strategy, not a
reseed). Here the user set is two seeded admins plus dev sign-ups on a disposable
cluster, so a reseed is trivial.

The deciding reason: "you added role-based access but didn't hash the passwords" is
the first thing an assessor asks. Doing RBAC on plaintext is a half-measure that
invites the question; doing both closes it, and the image rebuilds anyway.

## 2. Polling, not SSE/WebSockets, for the download bubble

The "your file is ready" badge polls `GET /notifications/unseen-count` every 5
seconds rather than holding a server-push channel open.

The alternatives were Server-Sent Events (one-way push, <1s latency) or WebSockets
(bidirectional). Both eliminate the poll and feel instant.

The trade-off we accepted is up to ~5s of latency before the badge updates — which
is invisible when the conversion it's reporting on takes 5–30s anyway.

This would be wrong at scale: thousands of concurrent browsers polling every 5s is
load the server feels, and at that point a push transport earns its complexity.

For a single-user demo, polling is one endpoint, debuggable with `curl`, and
firewall-proof. The honest scaling note for the presentation is "we'd move to SSE
before WebSockets if push became necessary" — SSE is the right next rung, not WS.

## 3. Skipping the admin stats panel (Grafana already covers it)

Feature 4 ships the user table + role management but **not** the aggregate stats
panel (uploads today, bytes converted, queue depth) the spec sketched.

The alternative was a `GET /admin/stats` endpoint aggregating Mongo + RabbitMQ and
a stats card on the page.

The trade-off we accepted is that an admin reads operational metrics in Grafana
(already deployed on NodePort 30007), not inside the app.

This would be wrong if the audience for the metrics were non-operators who never
open Grafana — then in-app stats earn their place. Our admin is also the cluster
operator, who already lives in Grafana.

The deciding reason: building a second, thinner metrics surface duplicates what the
monitoring stack does properly (retention, alerting, dashboards). Don't rebuild
Grafana badly inside the app.

## 4. Admin enforcement in the gateway only (in-cluster trust gap)

Authorization for the admin endpoints is checked in the **gateway**; the
auth-service `/users` endpoints have no role check of their own and trust
in-cluster callers — the same trust model as the pre-existing `/login`/`/validate`.

The alternative is defence in depth: every service validates the JWT and authorizes
independently, so no service is trusted purely by its network position.

The trade-off we accepted is a real privilege boundary that sits at the **network**
layer (ClusterIP + "only the gateway should call auth") rather than the
**application** layer — an in-cluster pod could call `auth/users` directly.

This is wrong the moment the cluster is multi-tenant or runs untrusted workloads:
network position is not identity, and "internal" is not "trusted."

The real fix is one of: mTLS / a shared secret between gateway and auth; the auth
service validating the JWT itself; or a service mesh enforcing "only the gateway
may call auth" via NetworkPolicy + workload identity. Out of scope for a
single-tenant demo, but that's the next step.

## 5. Audit trail to stdout (not an append-only store)

Every role change prints `AUDIT admin_role_change admin=<caller> target=<email>
new_role=<role> result=<status>` to the gateway's stdout, captured by `kubectl
logs` and the monitoring stack.

The alternative is a dedicated `audit_log` table (or an external SIEM sink) written
transactionally with the change.

The trade-off we accepted is that the record is **mutable and ephemeral**: logs
rotate, pods are replaced, and the line vanishes if the code path changes. It
answers who/whom/what, but it is not tamper-evident.

This is wrong anywhere with compliance or forensic requirements: "the logs say so"
is not an audit trail if the logs can be edited or lost.

The real fix is an append-only store written in the **same transaction** as the
role change — immutable timestamps, ideally hash-chained so tampering is
detectable — or shipping to a write-once external system. A whole subsystem;
deliberately out of scope.

## 6. Admin guardrails: self-demote (403) and last-admin (409)

The `PATCH /admin/users/<email>` endpoint refuses to let an admin change their own
role (403) or demote the last remaining admin (409), in addition to 404 on an
unknown email and 400 on an invalid role.

The alternative is to trust admins to not lock themselves out, or to handle lockout
reactively (a manual DB edit to restore an admin).

The trade-off we accepted is a little extra server-side logic and one pre-check
query (counting admins) before a demotion — negligible cost.

This is rarely wrong, but the guard is conservative: in a large org you might
legitimately want to demote yourself once another admin exists, which our blanket
self-demote block forbids. We chose the safe default over the flexible one.

The deciding reason: admin lockout is a self-inflicted outage with no in-app
recovery path. Two cheap guards (plus disabling the self-row button in the UI)
remove the most common ways to cause it, and the 409 last-admin check catches the
case where demoting *someone else* would still empty the admin set.
