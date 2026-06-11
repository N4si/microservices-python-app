# MANAGED_SERVICES.md — A5 Datastore Trade-off Record

> **What this document is.** Part A5 of `PHASE_UP_PLAN.md` proposed replacing
> every in-cluster stateful service (PostgreSQL, MongoDB/GridFS, RabbitMQ, Redis)
> with an AWS-managed equivalent, and Sprint 5 proposed *cutting over to them in
> prod*. After costing it honestly (§ below), that cutover was **cancelled**. This
> file is what replaces it: a decision record explaining, for each datastore,
> **what** the managed service would be, **what it replaces**, **when** you would
> actually adopt it, **why**, and **what it costs**.
>
> **Status:** in-cluster Helm charts remain the production datastore layer. A5 is
> documented-and-deferred, not built-and-running. No managed-datastore Terraform
> is applied; none is left running. Standing AWS cost of this decision: **$0**.

---

## 0. TL;DR

| Datastore | Today (kept) | Managed candidate | Adopt when | Standing cost if left on |
|---|---|---|---|---|
| PostgreSQL (auth) | `postgres` Deployment, **no PVC** | **RDS PostgreSQL** db.t3.micro | First real users / any data you can't lose | ~$15 (Single-AZ) / ~$31 (Multi-AZ) /mo |
| MongoDB + GridFS (video/mp3 blobs) | `mongo:4.0.8` StatefulSet | **MongoDB Atlas** (M0 dev / M10 prod) | When blob durability + backups matter | $0 (M0) / ~$57 (M10, ~$1–2 paused) /mo |
| RabbitMQ (pipeline) | `rabbitmq:3-management` StatefulSet | **Amazon MQ for RabbitMQ** mq.m5.large | When the broker must outlive the node | **~$183/mo** (no cheaper instance exists) |
| Redis (A2 idempotency) | in-cluster Redis pod | **ElastiCache** cache.t3.micro | When the lock store must be HA/managed | ~$12/mo |
| **A5 all-managed, left running** | — | RDS + Atlas M10 + Amazon MQ + ElastiCache | — | **~$262–273/mo** |

**The decision:** keep all four in-cluster. They are durable enough for a
single-node portfolio cluster, they cost $0 when the cluster is off, and the
reliability *patterns* that managed services are usually adopted for (no lost
events, idempotent retries, dead-lettering) are delivered in code by A1/A2/A3
against the in-cluster brokers instead. See §6.

---

## 1. Why the cutover was cancelled (the cost reality)

The EKS cluster was deliberately **torn down on 2026-06-03** to save money,
preserving everything for a ~20-minute re-apply. The whole point was to get the
standing bill toward zero. A5-as-specified pulls in the opposite direction:

| Managed service | Cheapest realistic prod-ish | ~$/mo (eu-west-2, 24/7) | Stops billing when… |
|---|---|---|---|
| RDS PostgreSQL (db.t3.micro, Single-AZ) | smallest usable | ~$15 | `terraform destroy` |
| RDS PostgreSQL (db.t3.micro, **Multi-AZ**) | standby doubles it | ~$31 | `terraform destroy` |
| MongoDB Atlas **M10** (2 vCPU, 2 GB) | smallest *dedicated* | ~$57 (paused ~$1–2) | pause or delete cluster |
| **Amazon MQ for RabbitMQ (mq.m5.large)** | **smallest type that exists** | **~$183** | delete broker (no pause) |
| ElastiCache Redis (cache.t3.micro) | single node | ~$12 | delete (no pause) |
| **A5 total, all managed, left running** | — | **~$262–273** | — |

> **The Amazon MQ correction.** An earlier version of the plan quoted Amazon MQ
> at "~$25–30/mo (mq.t3.micro)." **That instance type does not exist for
> RabbitMQ on Amazon MQ** — the smallest supported broker is **mq.m5.large**, at
> roughly $0.25/hr ≈ **$183/mo** in eu-west-2. There is no T-type and no pause.
> This single correction makes the managed broker the **largest standing cost in
> the entire plan** — bigger than the EKS control plane (~$150/mo) and ~3× the
> rest of A5 combined. It is the main reason the all-managed cutover was dropped.

That is a **15–40× jump** over the ~$10/mo the cluster was torn down to save, on
a project where the explicit goal is $0-when-off. So A5 is documented here as the
*production migration path*, not adopted as the running architecture.

---

## 2. PostgreSQL → Amazon RDS

**Today.** `postgres` runs as a single Deployment with **no PersistentVolume**
(`TECHNICAL_ANALYSIS.md` M-3). If the pod is rescheduled, the auth database — and
every user account — is gone. It is re-seeded from `Helm_charts/Postgres/init.sql`
(with the bcrypt-hashed admin user) on each fresh deploy. Acceptable for a demo
that is re-seeded anyway; **unacceptable the moment a real user account matters.**

**Managed candidate.** RDS PostgreSQL, `db.t3.micro`, Single-AZ for a demo
window. Multi-AZ (~$31/mo) is a one-flag change (`multi_az = true`) and is *pure
cost for zero observed benefit on a demo torn down nightly* — documented as
available, not enabled.

**What changes in the app:** almost nothing. `DATABASE_HOST`/`PSQL_*` already come
from config + the (now ESO-managed) secret. Point the host at the RDS endpoint,
run `init.sql` once against RDS, done. **Order hazard (from memory):** the bcrypt
admin seed must land **before** the auth image starts, or login fails — see the
merge runbook in `RBAC_EXPLAINED.md`.

**Adopt when:** you onboard any user whose account you can't cheerfully drop, or
you want point-in-time recovery / automated backups / a restart that doesn't wipe
auth. **Cost:** ~$15/mo Single-AZ, ~$31 Multi-AZ. Destroyable to $0.

---

## 3. MongoDB + GridFS → MongoDB Atlas

**Today.** `mongo:4.0.8` StatefulSet. GridFS is **load-bearing**: both the raw
videos (`fs_videos`) and the converted MP3s live in GridFS, chunked. Durability
is whatever the PVC gives you; backups are manual.

**Managed candidate — Atlas, not DocumentDB.** This is the single most important
A5 choice and it is deliberate:

| Option | GridFS | Cost | Verdict |
|---|---|---|---|
| **MongoDB Atlas** (M0 free dev / M10 prod) | **Real MongoDB → GridFS works unchanged** | $0 / ~$57 | ✅ chosen path |
| Amazon DocumentDB | **Emulates** the Mongo API; historic gaps around `fs.chunks`/GridFS ops — *must be functionally tested before trusting* | ~$200/mo (t3.medium floor) | ❌ rejected: GridFS risk + price |
| In-cluster StatefulSet | native, but PVC-only durability | $0 | ✅ kept today |

DocumentDB is the **biggest sleeper risk** in A5: it is not MongoDB, it emulates
it, and GridFS is exactly the kind of feature that has had gaps. It is also the
priciest minimum. **Atlas is genuine MongoDB**, so it is zero application risk,
and the **M0 free tier** covers dev/demo at $0. M10 (dedicated) supports
pause/resume — paused is ~$1–2/mo storage-only.

**Migration when adopted:** `mongodump` → `mongorestore` to Atlas, then a
**GridFS chunk verification test** (write a >255 KB file so it chunks, read it
back, byte-compare) before trusting it. PrivateLink from the VPC for prod.

**Adopt when:** blob durability, automated backups, or off-cluster persistence
matter. **Cost:** $0 (M0) / ~$57 (M10). Atlas bills outside AWS, so it survives a
`terraform destroy` — pause or delete it explicitly at teardown.

---

## 4. RabbitMQ → Amazon MQ for RabbitMQ

**Today.** `rabbitmq:3-management` StatefulSet, single node. The A3 retry/DLQ
topology (retry queues with TTL, terminal `vidcast.dlx`, bounded `MAX_RETRIES`)
is built **against this in-cluster broker** and works there.

**Managed candidate.** Amazon MQ for RabbitMQ, **mq.m5.large single-instance**.
It is a genuine drop-in: same AMQP, Pika unchanged, same management API, and the
A3 topology ports **verbatim**. Single-instance is **not HA** (cluster mode is a
one-flag change at ~3× cost) — documented honestly.

**The blocker is cost, not compatibility.** As in §1: mq.m5.large ≈ **$183/mo**,
no T-type, no pause. For a project that exists to demonstrate the *patterns*, the
patterns already run for $0 in-cluster. Amazon MQ buys broker-survives-the-node
durability — which on a **single-node** cluster is moot, because the node *is* the
availability boundary for everything else too.

**Why MSK (Kafka) is explicitly rejected:** it would require rewriting every
producer/consumer from Pika→Kafka (~$130+/mo minimum *and* a messaging-platform
migration). That is scope creep, not reliability work. Documented as the "if this
were event-sourced at scale" path, not adopted.

**Adopt when:** the broker genuinely must outlive the node (i.e. you move off
single-node), and the $183/mo is justified by real traffic. **Cost:** ~$183/mo,
destroy to stop. **Recommendation: do not adopt for a portfolio cluster.** The
honest production posture for a single-node deployment is: "single-node RabbitMQ
without external HA is acceptable here because the EKS node itself is the HA
boundary, and broker *durability* is handled by A1 (outbox) + A3 (DLQ)." This is
what most small teams actually do before they hit scale.

---

## 5. Redis (A2 idempotency) → ElastiCache

**Today / chosen.** A2 (idempotency + distributed lock) runs against an
**in-cluster Redis pod** (~50m/128Mi). The lock TTL is short, so a Redis outage
degrades to "occasional duplicate" (which the idempotent consumers absorb), not
"stuck." Cost: $0, dies with the cluster.

**Managed candidate.** ElastiCache `cache.t3.micro`, single node, ~$12/mo. No
pause; destroy to stop. It buys a managed, monitored, optionally-HA lock store.

**Adopt when:** the lock store must be HA and survive node loss, in tandem with
the rest of the managed stack. On its own it is the least compelling A5 item —
the in-cluster Redis already gives correct idempotency semantics; ElastiCache
mainly adds operational polish. **Confirmed decision: keep Redis in-cluster.**

---

## 6. The actual architecture decision

**All four datastores stay in-cluster.** A5's value is captured two ways without
the bill:

1. **As code-on-demand (optional).** The managed modules can be written behind
   `var.use_managed_datastores` (default `false`) so the all-managed version can
   be stood up for a *timed demo window* — `apply` → migrate → screenshot the
   RDS/Atlas/MQ consoles → `destroy` — proving "I can run the managed version on
   demand" at ~$0 standing cost. *(Not yet written; see §7.)*

2. **As reliability patterns, already delivered in-cluster.** The reason teams
   reach for managed datastores is usually durability and not-losing-data. A5 is
   *not* the only way to get that, and on this topology it is the expensive way:

   | Concern managed services usually address | How VidCast addresses it without A5 |
   |---|---|
   | Lost events if the broker hiccups | **A1 transactional outbox** + single-replica relay — no upload event dropped |
   | Duplicate processing on redelivery | **A2 idempotency** (claim-once + Redis lock) — duplicates are no-ops |
   | Poison messages / infinite requeue | **A3 retry + DLQ** (bounded retries, terminal `vidcast.dlx`) |
   | Broker config durability | persistent messages + durable queues on the in-cluster broker |

The result: the **reliability story is real and demonstrable**, the **managed
migration path is documented and costed**, and the **standing bill stays $0** —
which is the entire reason the cluster was torn down in the first place.

---

## 7. What is and isn't built

| Item | State |
|---|---|
| This trade-off record (`MANAGED_SERVICES.md`) | ✅ this file |
| In-cluster Helm charts (Mongo/Postgres/RabbitMQ) | ✅ unchanged, remain the datastore layer |
| In-cluster Redis for A2 | planned in Sprint 2 (in-cluster, not ElastiCache) |
| A5 managed-datastore Terraform (RDS/Atlas/MQ/ElastiCache, behind `use_managed_datastores=false`) | ⏳ **not written** — optional, build only if a demo-window cutover is wanted |
| Sprint 5 permanent cutover | ❌ **cancelled** — replaced by this document |

> If you want the on-demand managed version (§6.1) for a portfolio screenshot,
> say so and I'll write the Terraform behind the default-`false` toggle —
> `plan`-only, never applied without an explicit decision, with an AWS Budgets
> alarm in front of it.

---

## 8. Standing-cost summary

| Posture | Standing cost (cluster off) |
|---|---|
| **Chosen: all in-cluster** | **$0** |
| A9 ESO secrets (Parameter Store, standard tier) | **$0** (not Secrets Manager — see note) |
| A5 all-managed, left running | ~$262–273/mo |
| A5 demo-window (apply → demo → destroy) | ~$0 (delete Atlas M0 / everything at teardown) |

> **A9 cost note.** A9 reads secrets from **SSM Parameter Store**, not Secrets
> Manager. Standard-tier parameters are free and SecureString uses the
> AWS-managed `alias/aws/ssm` key (also free), so A9's standing cost is **$0** —
> not the $0.40/secret/mo that Secrets Manager would charge. (Any cost table
> showing A9 at ~$3–5/mo predates the Parameter Store decision and is stale.)
