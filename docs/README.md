# VidCast Documentation

This folder holds the project's documentation. Pick the document that matches what
you're trying to do.

## Where to start

| If you want to… | Read this |
|------------------|-----------|
| **Run the project yourself**, from cloning to teardown | [`GETTING_STARTED.md`](GETTING_STARTED.md) |
| **Understand the whole project** — for assessors, teammates, or non-technical guests | [`PROJECT_GUIDE.md`](PROJECT_GUIDE.md) |
| **Look up a specific component**, port, or data flow | [`architecture.md`](architecture.md) |
| **Operate or destroy** an existing deployment in detail | [`deployment-guide.md`](deployment-guide.md) |
| **Present or demo** the project | [`presentation-notes.md`](presentation-notes.md) |
| Know **why** a design choice was made (RBAC, bcrypt, notifications) | [`DECISIONS_MADE.md`](DECISIONS_MADE.md) |
| **Merge the RBAC/bcrypt branch** without breaking logins | [`MERGE_RUNBOOK_RBAC.md`](MERGE_RUNBOOK_RBAC.md) |

A typical first read: **`PROJECT_GUIDE.md`** to understand it, then **`GETTING_STARTED.md`**
to stand it up.

## Each document

- **`GETTING_STARTED.md`** — The complete end-to-end walkthrough: prerequisites, clone,
  configure, Terraform infra, Helm data services, seeding, deploying the microservices,
  the end-to-end test, CI/CD secrets, monitoring, and teardown. Start here to run it.

- **`PROJECT_GUIDE.md`** — The single comprehensive guide to VidCast, written so a
  non-technical reader and an engineer both get value from it. Covers what the product
  does, the architecture, every microservice, the data layer, the platform engineering
  (Terraform, CI/CD, monitoring), and the decisions behind it all.

- **`architecture.md`** — Architecture reference. Service inventory (technology, image,
  ports, replicas, security posture per service), the event-driven data flow, and the
  port map. Use it as a lookup, not a tutorial.

- **`deployment-guide.md`** — Phase-by-phase operations reference: one-time state-bucket
  bootstrap, Terraform, Helm, deploy, operate, and destroy. More granular than
  `GETTING_STARTED.md` and aimed at someone already comfortable with the stack.

- **`presentation-notes.md`** — A timed (12–15 min) script for demoing the project:
  what to show, in what order, and how to frame it for an audience.

- **`DECISIONS_MADE.md`** — Architectural decision records for the RBAC / notifications /
  admin work. Each entry: what we chose, the alternatives, the trade-off accepted, where
  it breaks, and the real fix at scale.

- **`MERGE_RUNBOOK_RBAC.md`** — Operational runbook for the moment the RBAC + bcrypt
  branch merges to `main`: the new auth image and the DB seed must land together or every
  login fails. Contains no credentials.

## Conventions

Documentation contains **no real secrets**. Anything account-specific appears as a
placeholder you fill in — `<AWS_ACCOUNT_ID>`, `YOUR_STATE_BUCKET`, `admin@example.com`,
`<BCRYPT_HASH_HERE>`, `YOUR_POSTGRES_PASSWORD`, and so on.

Project-level instructions for AI assistants live in [`../CLAUDE.md`](../CLAUDE.md); the
public overview is the root [`../README.md`](../README.md).
