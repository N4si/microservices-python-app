# VidCast — The Complete Project Guide

**Last updated:** 2026-06-03

> **How to read this:** you do not need a technical background. Every piece of
> jargon is explained in plain English *in the same breath* as it's introduced,
> usually with a real-world comparison. A non-technical reader should never have to
> look anything up; an engineer should still find it substantive.

---

## Table of contents

1. [What VidCast does](#1-what-vidcast-does)
2. [The big picture — architecture overview](#2-the-big-picture--architecture-overview)
3. [The microservices in detail](#3-the-microservices-in-detail)
4. [The data layer](#4-the-data-layer)
5. [The upload-to-download journey](#5-the-upload-to-download-journey)
6. [Authentication and authorisation — the deep dive](#6-authentication-and-authorisation--the-deep-dive)
7. [Infrastructure — what we provisioned and why](#7-infrastructure--what-we-provisioned-and-why)
8. [The CI pipeline](#8-the-ci-pipeline-github-actions)
9. [The CD pipeline](#9-the-cd-pipeline-github-actions)
10. [How Docker Hub connects to Git](#10-how-docker-hub-connects-to-git)
11. [Dev vs Prod — two pipeline systems](#11-dev-vs-prod--two-pipeline-systems)
12. [Observability](#12-observability)
13. [The journey — problems faced and how we solved them](#13-the-journey--problems-faced-and-how-we-solved-them)
14. [Decisions and trade-offs](#14-decisions-and-trade-offs)
15. [Known limitations and the next iteration](#15-known-limitations-and-the-next-iteration)
16. [Glossary](#16-glossary)

---

## 1. What VidCast does

*VidCast turns a video into a downloadable audio file. You upload a recording, it
strips out the sound, and emails you a link to the MP3 — useful for turning a
recorded talk or Zoom call into a podcast.*

The problem it solves is mundane but real: people record video but often only want
the **audio** — a lecturer turning a recorded class into a podcast, a journalist
pulling a clip for radio, a student who wants to listen to a webinar on the bus.
Doing that by hand means installing fiddly software. VidCast does it in a few clicks.

The experience, end to end: you open the website, **sign up or log in**, **upload**
an MP4 video, and carry on with your day. Behind the scenes the system extracts the
audio, and within seconds a small red **badge** appears on the site (and an **email**
lands in your inbox) saying your file is ready. You click **Download** — or open
**My Conversions** to see your whole history — and get your MP3. If you're an
**administrator**, you also see a control panel to manage other users. That's the
whole product. The interesting part — and what this guide is really about — is the
engineering that makes it reliable, secure, and reproducible.

---

## 2. The big picture — architecture overview

*VidCast is built as **microservices**: instead of one big program, several small
programs each do exactly one job and talk to each other through well-defined
channels. They run on Kubernetes (an automated "shift manager" for software) on
Amazon's cloud.*

> **The metaphor we'll use throughout:** imagine a company where every employee has
> exactly one job — a **receptionist** who greets every visitor, a **bouncer** who
> checks IDs, a **chef** who does the actual work, a **courier** who delivers the
> result, a **librarian** who files things away. Crucially, they never reach into
> each other's desks; they pass **formal memos** down a conveyor belt. That
> discipline is what makes the company easy to reason about, fix, and scale — and
> it's exactly how VidCast is built.

Here's the cast and how a request flows:

```
        You (browser)
            │
            ▼
   ┌──────────────────┐
   │  Frontend        │  React website served by nginx  (the dining room + waiter)
   └──────────────────┘
            │  /api/...
            ▼
   ┌──────────────────┐
   │  Gateway         │  the front desk — checks your wristband, routes everything
   └──────────────────┘
       │        │          │
   login│   upload│   download│
       ▼        ▼          ▼
 ┌─────────┐  ┌─────────────┐   stream MP3 back
 │  Auth   │  │  MongoDB    │◄──────────────────
 │ service │  │  (files)    │
 └─────────┘  └─────────────┘
   │  checks       │ drop a "convert this" memo
   ▼               ▼
 ┌─────────┐   ┌──────────────┐  "video" mailbox   ┌────────────┐
 │Postgres │   │  RabbitMQ    │───────────────────►│ Converter  │ (the chef: MoviePy/ffmpeg)
 │ (users) │   │  (conveyor)  │◄───────────────────│            │
 └─────────┘   └──────────────┘  "mp3" mailbox     └────────────┘
                      │  "it's ready" memo
                      ▼
              ┌────────────────┐
              │ Notification   │  the courier — emails YOU the link (Gmail SMTP)
              └────────────────┘
```

The **four backend microservices** are *auth* (identity), *gateway* (front door),
*converter* (the chef), and *notification* (the courier). The **frontend** is a
separate React app. Behind them sit **three data services**: *MongoDB* (stores the
big video/audio files), *PostgreSQL* (stores the list of users), and *RabbitMQ* (the
conveyor belt that lets the gateway hand a job to the converter without making you
wait).

All of this runs inside **Kubernetes** (often "K8s") on **AWS EKS** (Amazon's
managed Kubernetes). Kubernetes is a **shift manager for software**: it keeps the
right number of each "employee" on duty, restarts anyone who collapses, and can
clone busy ones. Each running copy of a service is a **pod** — think of a *sealed
glass jar* with the program and everything it needs inside, so it behaves
identically wherever it runs. The outside world reaches specific services through
numbered **doors** punched in the cluster wall (called **NodePorts**): the website
is door `30006`, the gateway `30002`.

---

## 3. The microservices in detail

Each service is a small Python (or, for the frontend, JavaScript) program. The rule
they all obey: **do one job, trust nobody by accident, and talk through defined
channels.**

### 3.1 auth-service — the bouncer

- **Job:** prove *who you are*. It handles `login`, `signup` (`/register`), token
  issuing, and — added in this project — telling the rest of the system your **role**
  (admin or ordinary user).
- **Built with:** Python + Flask (a lightweight web framework), `PyJWT` (for the
  wristband), `bcrypt` (for password scrambling), and `psycopg2` (to talk to
  PostgreSQL).
- **Talks to:** PostgreSQL (the user list) downstream. Upstream, only the *gateway*
  calls it — it sits on an internal-only address.
- **If it disappeared:** nobody could log in or sign up. Existing wristbands would
  keep working until they expired (it's *stateless* — see Section 6), but no new
  ones could be issued.
- **Interesting code:** `src/auth-service/server.py`. The heart is `CreateJWT`, which
  stamps your details onto the wristband, and `/login`, which checks your password
  against a scrambled fingerprint:

  ```python
  # The wristband carries BOTH a simple admin flag (for older code that reads it)
  # AND a richer role string (so we can add more roles later without breaking things).
  "admin": role == "admin",
  "role":  role,
  ```

### 3.2 gateway-service — the front desk

- **Job:** the single front door. *Every* request from the website hits the gateway
  first. It checks your wristband, then routes you: logins go to auth, uploads go to
  storage + the conveyor belt, downloads stream files back, and admin requests are
  gated to admins only. It also exposes `/my-files` (your history) and `/admin/users`
  (the admin panel).
- **Built with:** Python + Flask, `PyMongo`/`gridfs` (file storage), `pika` (RabbitMQ),
  `requests` (to call auth), and `flask-cors` (so the browser is allowed to call it).
- **Talks to:** auth (to validate wristbands), MongoDB (files), RabbitMQ (jobs).
  Everything the browser does flows through here.
- **If it disappeared:** the whole app would go dark — it's the only public entrance.
- **Interesting code:** `src/gateway-service/server.py`. Note how upload was changed
  from "admins only" to "any logged-in user" — a one-word change with big meaning
  (Section 6):

  ```python
  # Uploading is a core action for ANY authenticated user — not just admins.
  if not access:
      return "not authorized", 401
  ```

### 3.3 converter-service — the chef

- **Job:** do the actual work. It waits at the **"video" mailbox**, and whenever a
  job appears, it fetches the video, extracts the audio, saves the MP3, and drops a
  **"it's ready" memo** in the "mp3" mailbox.
- **Built with:** Python, `pika` (RabbitMQ), `pymongo`/`gridfs`, and **MoviePy** —
  a library that drives **ffmpeg** (the industry-standard audio/video tool) under
  the hood. The actual conversion is essentially one line:

  ```python
  audio = moviepy.editor.VideoFileClip(tf.name).audio   # pull the audio track out
  ```
- **Talks to:** RabbitMQ (in and out) and MongoDB (read the video, write the MP3).
- **If it disappeared:** uploads would still succeed and pile up in the "video"
  mailbox, but nothing would get converted — the queue would grow until a converter
  came back to drain it. (This is a *feature* of the conveyor-belt design: a backlog
  waits patiently instead of being lost.)
- **It runs 2 copies** so two videos can convert at once.

### 3.4 notification-service — the courier

- **Job:** wait at the **"mp3" mailbox**, and whenever a "ready" memo appears, email
  the person who uploaded the video, using Gmail.
- **Built with:** Python, `pika`, and Python's built-in email/`smtplib` (the postal
  system for *sending* mail).
- **Talks to:** RabbitMQ (in) and Gmail's outgoing mail server (out).
- **If it disappeared:** conversions would still complete and be downloadable — users
  just wouldn't get the courtesy email.
- **The "never-raise" contract:** this service was rewritten so that a single bad
  email *can never crash it* (the story is in Section 13). It now returns one of two
  answers — "done, remove the memo" or "couldn't, try later" — and handles every odd
  case gracefully:

  ```python
  if not receiver_address:           # an old memo with no recipient
      return None                    # skip it, don't crash, carry on
  ```

### 3.5 frontend — the dining room

- **Job:** everything you see. Login, sign-up, upload, download, the **My
  Conversions** history page, the **admin user-management** page, and a navbar that
  shows different tabs depending on your role.
- **Built with:** React (a popular UI library) + Vite (a build tool) + Tailwind CSS
  (styling), packaged behind **nginx** (a fast web server that also forwards `/api`
  calls to the gateway).
- **Talks to:** only the gateway, via `/api/...`.
- **If it disappeared:** power users could still poke the gateway directly with
  command-line tools, but normal people would have no way in.
- **Interesting detail:** the website reads your wristband to decide which tabs to
  show. But hiding a tab is just tidiness — the *real* lock is on the gateway, so
  even typing the admin URL directly bounces a non-admin away.

---

## 4. The data layer

Three different storage systems, each chosen because it's the right tool for a
different shape of data.

### 4.1 MongoDB + GridFS — the file room

MongoDB stores big files (the videos and MP3s). **GridFS** is the part of MongoDB
designed for large objects: it *tears each file into manageable chunks* and shelves
them, reassembling on demand. > **Analogy:** a librarian who tears a thick book into
chapters before shelving, so no single shelf has to hold the whole tome — and can
hand you back the reassembled book when you ask. We also attach a small label to
every file — `owner_email` — so the system can answer "which files are *yours*?"

### 4.2 PostgreSQL — the staff roster

PostgreSQL is a classic table-shaped database, perfect for the **user list**: one
row per user, with columns `email`, `password` (a scrambled fingerprint, never the
real password), `role` (admin/user), and `created_at`. > **Analogy:** the staff
roster binder with a role badge next to each name. It's the single source of truth
for *who exists and what they're allowed to do*.

### 4.3 RabbitMQ — the post office

RabbitMQ holds two durable **queues** (mailboxes): **`video`** (jobs going in) and
**`mp3`** (results coming out). Its whole purpose is **decoupling**: the gateway can
drop a job and immediately tell you "we're on it" without waiting for the slow
conversion, and the converter picks jobs up whenever it's free. > **Analogy:** a
post office with two mailboxes — *videos in, audio out*. "Durable" means the mail
survives even if the post office briefly closes (a pod restart) — letters aren't lost.

---

## 5. The upload-to-download journey

*Here's exactly what happens, step by step, the moment you upload a video. Follow
the numbers — no technical background needed.*

1. **You click Upload.** The website (frontend) sends your video to the gateway at
   `/api/upload`, attaching your **wristband** (the token proving who you are).
2. **The gateway checks your wristband** by asking the auth service "is this real and
   not expired?" If yes, it learns your email. If no, you're turned away (`401`).
3. **The gateway stores the video** in MongoDB, stapling your email to it as the
   `owner_email` label — like a coat-check ticket that stays on through the whole
   process.
4. **The gateway drops a memo** in the RabbitMQ **"video" mailbox**: *"convert file
   X; it belongs to you@example.com."* Then it immediately replies to the website
   **"success!"** — you're free to go. *(This is the magic of the conveyor belt: you
   never wait for the slow part.)*
5. **A converter picks up the memo** (whenever one is free), fetches the video from
   MongoDB, and runs **MoviePy/ffmpeg** to extract the audio — a few seconds for a
   short clip.
6. **The converter saves the MP3** back into MongoDB, copying the same `owner_email`
   label onto it, and drops a new memo in the **"mp3" mailbox**: *"file X is ready
   for you@example.com."*
7. **The notification service picks up that memo** and **emails you** a download
   reference, using Gmail. The email goes to *the address you uploaded with* — never
   a hard-coded one.
8. **Meanwhile, the website is quietly polling** the gateway every few seconds:
   "any new files for me?" The moment your MP3 exists, the count comes back as 1 and
   a **red badge** appears on the Download tab.
9. **You click Download** (or open **My Conversions**). The gateway confirms your
   wristband, fetches the MP3 from MongoDB, and **streams it back** to your browser
   as a file. Done.

From your point of view it felt instant and you got an email. Underneath, five
independent services collaborated through two mailboxes and two databases — and any
one of them could have been restarted mid-flight without losing your job.

---

## 6. Authentication and authorisation — the deep dive

*This is the area assessors probe hardest, so we go deep. Two ideas that sound alike
but are completely different: **authentication** (proving who you are) and
**authorisation** (what you're allowed to do).*

### 6.1 Authn vs authz — the core distinction

- **Authentication ("authn") = "are you who you say you are?"** Showing ID at the
  door. In VidCast that's `/login`: email + password → if correct, you get a
  wristband.
- **Authorisation ("authz") = "are you allowed to do this?"** Which doors your
  keycard opens *once you're inside*.

> **The hotel analogy:** authentication is the photo ID proving you're a guest;
> authorisation is the keycard saying which doors open. Every guest can ride the lift
> and enter their own room (upload/download); only staff keycards open the back
> office (the admin panel). VidCast's original bug was handing **every** guest a
> *master keycard* — more on that below.

This distinction drove a concrete fix: uploading a video only requires
**authentication** (any logged-in user). Seeing the admin panel requires
**authorisation** (the admin role specifically). The old code confused the two and
demanded "admin" just to upload — which only "worked" because everyone was secretly
admin.

### 6.2 The JWT lifecycle — a wristband, not a logbook

A **JWT** (JSON Web Token) is a **festival wristband**. When you log in, the auth
service issues one stamped with your details and sealed so it can't be forged. You
show it on every request; the gateway reads it. Crucially this is **stateless** —
the server keeps **no logbook** of who's logged in. Everything needed is *on the
wristband*, and a cryptographic seal proves it's genuine. (Why that matters: any
copy of the gateway can serve you without sharing a central session list — it scales
effortlessly.)

The wristband carries four things:

| Claim | Meaning | Plain English |
|---|---|---|
| `username` | your email | who you are |
| `admin` | true/false | the simple "are you staff?" flag |
| `role` | `"admin"` or `"user"` | the richer role (room to add more later) |
| `exp` | expiry timestamp | the wristband stops working after 1 day |

Validation: when a request arrives, the gateway hands the wristband back to the auth
service, which re-checks the seal and the expiry. Tamper with it and the seal breaks;
wait too long and `exp` rejects it.

### 6.3 bcrypt — the one-way blender

Passwords are never stored as readable text. They're put through **bcrypt**, a
**one-way blender**: you can turn a strawberry into a smoothie, but you can't turn the
smoothie back into a strawberry. At login we blend what you typed and compare
*smoothies* (`bcrypt.checkpw`), never the original fruit.

```python
if not bcrypt.checkpw(typed_password.encode(), stored_hash.encode()):
    return "Could not verify", 401      # the smoothies don't match
```

Two properties make bcrypt the right choice:
- **One-way:** a thief who steals the database gets smoothies, not passwords.
- **Salted and slow:** a pinch of randomness (**salt**) means two people with the
  same password get *different* smoothies, and the blender is deliberately slow so
  an attacker can't try billions of guesses per second.

### 6.4 RBAC and the three guardrails

**Role-Based Access Control (RBAC)** is the formal name for "what you can do depends
on your role." Enforcement lives at the **gateway**: it reads the `admin` claim from
the (verified) wristband and rejects non-admins from admin endpoints with a `403`
("forbidden"). The admin panel can promote/demote users, protected by three rails:

- **Self-demotion → `403`.** You cannot change *your own* role. Stops an admin
  accidentally locking themselves out.
- **Last-admin demotion → `409`.** The system refuses a change that would leave
  **zero** admins — nobody could ever get back in.
- **Unknown user → `404`.** Changing someone who doesn't exist fails cleanly.

> **A subtle, clever point assessors love:** the `409` "last admin" rule looks
> redundant next to the `403` "not yourself" rule — if you're the only admin,
> demoting yourself is already blocked. But the `409` catches a sneakier case:
> someone whose admin rights were *just revoked* but who still holds a valid
> wristband from a minute ago could otherwise demote the last *real* admin. The two
> rules guard different things — your **identity** versus the **system's health** —
> so they're complementary, not duplicate.

Every promote/demote also writes an **audit line** to the logs: *who* changed *whom*,
to *what*. (Making that line actually appear was its own small saga — Section 13.8.)

### 6.5 The "everyone was an admin" story

When we opened the original code, we found the wristband-stamping function had
`admin: True` **hard-coded** — *every* login, and worse, every *sign-up*, minted an
admin. RBAC was effectively switched off, and a stranger could create an account and
own the system (a **privilege-escalation hole**). We rebuilt it: real roles in the
database, the wristband carrying your *true* role, sign-ups locked to ordinary
"user," and the gateway enforcing the difference. That rebuild is the foundation
everything else in this project sits on.

---

## 7. Infrastructure — what we provisioned and why

*Everything VidCast runs on is defined as code and created on Amazon's cloud. Nothing
was clicked together by hand — which is why we can destroy it to save money and
rebuild it identically in 20 minutes.*

- **AWS, one region (`eu-west-2`, London).** AWS is the cloud provider — rented
  computers, networks, and storage. We use a **single region** deliberately: it's a
  learning/dev project, and one region is cheaper and simpler. A bank would spread
  across regions for disaster recovery; we don't need to.

- **EKS — managed Kubernetes.** Running Kubernetes yourself means babysitting its
  "brain" (the *control plane*). **EKS** is Amazon running that brain for you, so we
  only manage the *workers*. > **Analogy:** EKS is hiring a managed building with the
  security and plumbing already run; we just furnish the offices.

- **Terraform — Infrastructure as Code.** Instead of clicking buttons in a console,
  we *write down* the infrastructure we want in files, and Terraform makes reality
  match. `terraform plan` shows the diff ("here's what I'll change"); `terraform
  apply` does it; `terraform destroy` removes it. The state — Terraform's memory of
  what exists — lives in an **S3 bucket** (Amazon's file store), locked by a
  **DynamoDB** table so two people can't change it at once. > **Why local state is
  forbidden:** if that memory lived on one laptop, a teammate (or the CI robot)
  would have no idea what already exists and could create duplicates or clobber
  things. A shared, locked memory keeps everyone honest.

- **VPC, subnets, security groups, IAM roles — the walls and keys.** The **VPC** is
  a private network — VidCast's own fenced compound. **Subnets** are rooms within it
  (we use two, in two availability zones, for the cluster). **Security groups** are
  doormen on each door, allowing only specific traffic (e.g. the website port from
  the public, the admin ports only from the operator's home IP). **IAM roles** are
  job-specific keyrings — the cluster's keyring, the worker nodes' keyring — each
  holding only the permissions that job needs and no more.

- **The node group — one `m7i-flex.large`.** The worker machine where the pods
  actually run: 2 CPUs, 8 GB RAM, Kubernetes 1.31. We run **one** node for dev
  (auto-scaling allowed between 1 and 2). > **Why this size and not a tiny one:** the
  cluster runs ~12 pods at once; a smaller machine couldn't fit them. > **Why not a
  cheaper "burstable" T-type machine:** this AWS account rejects a setting EKS forces
  on T-type machines — we lost 40 minutes to that in May before switching. For
  production you'd run several larger nodes across zones for resilience.

- **OIDC — temporary visitor badges for the robot.** The CI/CD robot needs
  permission to deploy to AWS. The naïve way is to hand it a permanent AWS key — a
  master key that, if leaked, is a disaster. Instead we use **OIDC federation**:
  GitHub vouches for the robot, and AWS issues a **short-lived visitor badge** valid
  for one job. The trust policy says, in effect, *"only accept badges from GitHub
  workflows in **this specific repo**"*:

  ```
  token.actions.githubusercontent.com:sub  StringLike  "repo:<YOUR_GITHUB_ORG>/vidcast:*"
  ```
  No long-lived secret ever touches the robot. If GitHub were compromised the badge
  still only works for our one repo, and only for the moment a job runs.

---

## 8. The CI pipeline (GitHub Actions)

*"CI" (Continuous Integration) is the **quality gate**: every time code changes, an
automated assembly line checks it and packs it into shippable containers. Ours runs
on GitHub's servers, defined in `.github/workflows/ci.yml`.*

It triggers on pull requests and on pushes to `main`, but only when files under
`src/**` change (no point rebuilding for a docs-only edit).

| Stage | What runs | When | Why it's there |
|---|---|---|---|
| **Checkout** | `actions/checkout` | every run | copies the code onto the robot's workbench |
| **Lint** | `ruff check src/ --exclude src/frontend` | PR + push | catches sloppy or broken Python *before* a human reviews it — like spell-check for code |
| **Build** | `docker build` per service (4 in parallel) | PR + push | proves each service's container actually builds; a typo in the recipe fails here |
| **Security scan** | Trivy (`severity CRITICAL,HIGH`, `exit-code 1`, `ignore-unfixed`) | PR + push | scans each container for known vulnerabilities and **blocks the build** if it finds a serious, fixable one |
| **Push** | `docker push` to Docker Hub | **`main` push only** | publishes the finished containers to the warehouse — but *only* once code is merged |

A few things worth understanding:

- **What "lint" actually catches.** `ruff` is a Python linter — it flags unused
  imports, undefined names, risky patterns. It's fast and cheap and catches a whole
  class of "oops" before review. When it fails, the fix is usually a one-liner.

- **What Trivy actually does, and why it can fail.** **Trivy** is a security scanner.
  It reads everything baked into a container — the operating-system packages, the
  Python libraries — and cross-references a public database of known
  vulnerabilities. If it finds a **CRITICAL** or **HIGH** issue that *has a fix
  available* (`ignore-unfixed` skips ones nobody can fix yet), it stops the line
  (`exit-code 1`). Earlier in the project this gate failed repeatedly, and fixing it
  meant upgrading library versions until the scan came back clean — a real, instructive
  battle (Section 13 references it).

- **The deliberate choice: PR builds *don't* push images.** On a pull request, CI
  builds and scans the containers but does **not** publish them — publishing only
  happens on a push to `main`. *Why:* it keeps the warehouse free of half-baked
  experiment images and enforces "nothing ships until it's merged." *The trade-off:*
  it means you can't do a true pre-merge test on the real cluster (the images don't
  exist yet) — which bit us once and is documented honestly in
  `docs/DECISIONS_MADE.md`.

> **Honest note:** there is **no automated unit-test stage** yet — CI is lint, build,
> scan, push. Adding tests is named as a gap in Section 15. We're not pretending it's
> there.

---

## 9. The CD pipeline (GitHub Actions)

*"CD" (Continuous Deployment) is the **delivery line**: once CI has approved and
published the containers, CD ships them to the live cluster — automatically, with no
human running commands. Defined in `.github/workflows/cd.yml`.*

| Stage | What runs | Why |
|---|---|---|
| **Trigger** | when CI finishes successfully on `main` | only deploy code that *passed* the quality gate |
| **Get a visitor badge** | `aws-actions/configure-aws-credentials` via the **OIDC role** | short-lived AWS access, no stored keys (Section 7) |
| **Point kubectl at the cluster** | `aws eks update-kubeconfig` | so the robot can issue cluster commands |
| **Deploy** | `kubectl set image` on each of the 4 backend deployments | swaps in the new container version |
| **Verify** | `kubectl rollout status` | waits and confirms the new version came up healthy |

The key concept here is the **rolling restart**. When `kubectl set image` runs,
Kubernetes doesn't yank the old version down and leave a gap — it **brings new pods
up first, waits for them to be healthy, then drains the old ones**. > **Analogy:**
swapping the engine on a moving train by attaching a new carriage, moving everyone
across, then detaching the old one — the passengers never stop moving. The app is
never offline during a deploy.

CD also gives a free **audit trail**: GitHub records *who* triggered each run, *which
commit* it deployed, and the *outcome* — so there's always a record of what went
live and when.

> **Note:** CD updates the **four backend** services. The **frontend** is deployed
> separately (Section 10) because building it needs Node.js, which this pipeline's
> setup doesn't include.

---

## 10. How Docker Hub connects to Git

*This is the "trust chain" from a developer's keyboard to a running container — how a
saved code change becomes a live service.*

A **Docker image** is a **vacuum-sealed package** containing a program and everything
it needs; a **registry** is the warehouse that stores those packages. The chain:

1. **A developer commits** code to Git and **pushes** to GitHub.
2. **GitHub Actions wakes up**, clones the repo onto a fresh robot, and **builds** the
   Docker image for each changed service.
3. **On a `main` push, the robot logs in to Docker Hub** as `<YOUR_DOCKERHUB_USER>`, using a
   **token** kept in GitHub's encrypted **Secrets** (`DOCKERHUB_USERNAME` +
   `DOCKERHUB_TOKEN`), and **pushes** each image.
4. Images are tagged with the exact **commit ID** (e.g. `…/auth-service:c36b319`) —
   *not* a moving `:latest` tag. > **Why the commit ID and not `:latest`:** "latest"
   is ambiguous — it means something different every day. A commit ID is precise and
   permanent, so you always know *exactly* which code is running and can reproduce or
   roll back to it. (This is a deliberate choice; many projects use `:latest` for
   convenience and regret it.)
5. **On deploy, the cluster pulls** that exact image from Docker Hub by its commit ID.

> **Why a token, not the account password:** the token is **revocable and scoped** —
> like giving a contractor a key that only opens the supply closet and can be
> cancelled, rather than your house key. If it leaks, you revoke that one token; the
> Docker Hub account itself is never exposed.

**The frontend exception.** The four backend services go to **Docker Hub**. The
**frontend** goes to **ECR** (Amazon's private registry) and is **built by hand**,
because compiling the React app needs Node.js, which the current backend-focused CI
doesn't set up. The cluster's worker machine has built-in permission to pull from the
account's own ECR, so no extra password is needed. (Folding the frontend into CI is a
named next step.)

---

## 11. Dev vs Prod — two pipeline systems

*VidCast carries two delivery systems on purpose, because the bootcamp curriculum
covers both and they're good at different things.*

| | **GitHub Actions** (dev — in use today) | **Jenkins** (prod — pipeline written, server not yet running) |
|---|---|---|
| **Runs on** | GitHub's servers | infrastructure *you* control (your own VMs/pods) |
| **Best for** | fast setup, open-source, tight repo integration | heavy custom logic, internal corporate systems, multi-stage approvals |
| **Where it lives** | `.github/workflows/*.yml` | `Jenkinsfile` |

To be precise about status: the **dev pipeline (GitHub Actions) is mature and in
daily use** — it's what built and deployed everything in this guide. The **Jenkins
pipeline is fully *written*** — `Jenkinsfile` is a complete 122-line, 8-stage
pipeline — but there is **no running Jenkins server executing it yet**. The
*pipeline-as-code* exists; the *machine to run it* is the next iteration.

What that Jenkinsfile already describes is notably more production-shaped than the
GitHub flow:

1. **Checkout** → 2. **Lint** → 3. **Build** all four images (in parallel) →
4. **Security scan** (Trivy) → 5. **Push** to the registry → 6. **Deploy to
staging** (a cheap **Docker Swarm** environment via `docker stack deploy`) →
7. **Smoke-test staging** (`curl -f .../healthz` — fail the build if the health
check fails) → 8. **Manual approval gate** (*"Staging passed. Deploy to
Production?"* — a human must click) → 9. **Deploy to production** (EKS).

> **Why Docker Swarm for staging:** a second full EKS cluster for testing would cost
> roughly as much as production. A tiny Docker Swarm setup on a small machine costs a
> fraction and is functionally close enough to catch problems before they reach the
> real cluster. The bootcamp deliberately connects its "Docker Swarm" module to its
> "Kubernetes" module this way.

The production-grade extras a finished Jenkins setup would add: explicit
staging→production promotion with the **manual approval gate** (already in the file),
automated **rollback** if a health check fails after deploy, **blue-green or canary**
releases (ship to a slice of users first), and hooks into on-call alerting. Those are
the road map, not today's reality — and we say so plainly.

---

## 12. Observability

*"Observability" answers the question: when something goes wrong at 2 a.m., can you
tell **what** and **why**? VidCast has three complementary layers, because they
answer different questions.*

- **Logs — the diary.** Every service prints what it's doing to its output, captured
  by `kubectl logs`. Logs answer *"what happened, in order?"* This is where the
  **admin audit trail** lives — every promote/demote prints `AUDIT admin_role_change
  admin=… target=… new_role=…`. (Getting those lines to actually appear took a
  one-line fix — Section 13.8.)

- **Metrics — the dashboard gauges.** We install **kube-prometheus-stack**, a bundle
  of **Prometheus** (which collects numbers over time — CPU, memory, pod restarts,
  node health) and **Grafana** (which draws them as live dashboards, on door `30007`,
  with a custom "VidCast Operations" dashboard and alert rules for crash-loops and
  high CPU/memory). Metrics answer *"is the system healthy right now, and what's the
  trend?"*

  > **Honest scope:** Prometheus here scrapes **cluster- and node-level** metrics —
  > it does *not* yet collect custom per-service business metrics (e.g. "conversions
  > per minute"). The app code doesn't expose them (a `prometheus-client` library was
  > declared early but left unused and dropped). Per-service metrics are a named gap
  > in Section 15.

- **Traces — the journey map.** *(Not implemented.)* Tracing follows a single request
  across every service to find where time was spent. We don't have it; for a system
  this size, logs + metrics suffice, and we note tracing as a "if this grew" item.

> **Why three layers matter:** a metric tells you *the kitchen is on fire* (CPU is
> pegged); a log tells you *which dish caused it* (the error message); a trace would
> tell you *which step in that dish's recipe was slow*. Different questions, different
> tools.

---

## 13. The journey — problems faced and how we solved them

*Every real project is a sequence of problems. Here are the eight that mattered most,
told as stories, roughly in order. The recurring lesson: discipline — small honest
checks, written-down recovery plans — pays off exactly when things break.*

### 13.1 The May crash loop — workers stuck in a reboot spiral

The first deployment looked alive but wasn't working. Two services — the converter
and the courier — were in a **crash loop**: starting, falling over, restarting,
forever. The root cause was mundane and two-fold: the RabbitMQ **mailboxes hadn't
been created**, so the workers panicked trying to listen at a mailbox that didn't
exist; and the Gmail login was misconfigured. We created the queues up front and
fixed the mail settings, and the workers settled. **Lesson:** a service that depends
on something must fail *loudly and early* if that something is missing — which led
directly to the health-check and startup fixes that followed.

### 13.2 "Everyone is an admin" — the hidden master key

While planning the roles feature, we read the token code and found `admin: True`
*hard-coded* into every wristband. The system had been handing out master keys to
everyone, and nobody had noticed because nothing visibly broke — the door was
unlocked, so every push opened it. This single discovery reframed the whole piece of
work: it wasn't "add roles," it was "the access control has never actually been on."
**Lesson:** "it works" is not the same as "it's correct" — a security control that's
silently disabled looks identical to one that's working, until someone checks.

### 13.3 The sign-up that made strangers into admins

Worse than 13.2: the brand-new self-service sign-up handed each new account an
**admin** wristband. Anyone on the internet could create an account and own the
system — a textbook **privilege-escalation hole**. The fix was a few lines (new
accounts are always ordinary "user"), but the *finding* mattered: it was caught by
reading the code adversarially before shipping, not by a user exploiting it.
**Lesson:** review your own work as if you were trying to break it.

### 13.4 The login that cried "fire" — the psycopg2 `None` bug

A subtle one. The database library's `execute()` command always returns *nothing*
(`None`), but the login code was written as if that nothing meant "no user found."
The result: when an **unknown** person tried to log in, instead of a clean "you're
not on the list" (`401`), the system threw a confusing internal error (`500`) — the
equivalent of setting off the fire alarm when a stranger knocks. We rewrote it to
decide based on the *actual database result*. **Lesson:** if your front door can't
reliably say "no," every lock you build on top of it is theatre.

### 13.5 The runbook hiding in a private notebook

During our own pre-ship review, we caught something easy to miss: the **recovery
recipe** for the risky database upgrade was written inside a file that was
*deliberately excluded from the shared repository* (it was personal study material).
Had a teammate cloned the project fresh, the single most important operational
document would have been missing. We moved it into the official, shared docs —
carefully stripping out a password first. **Lesson:** the value of a runbook is zero
if it isn't where the next person will look.

### 13.6 The pipeline that wouldn't pre-test

Planning the integration test, we hit a wall: we wanted to test the new code on the
real cluster *before* merging — but the CI pipeline only publishes containers on a
push to `main`, so the pre-merge containers simply didn't exist to deploy. This is a
genuine consequence of a sensible policy (don't pollute the registry with experiments).
We documented the constraint, chose a "merge then verify with a fast rollback ready"
approach, and wrote down the trade-off. **Lesson:** sometimes the right move is to
name a limitation honestly rather than bolt on a hack to route around it.

### 13.7 The deployment that broke every login — and the runbook that saved it

This is the one worth telling in full. Our new login uses scrambled (bcrypt)
passwords, which requires the **database** to be upgraded in lockstep — a
bcrypt-expecting login against an old plain-text database is *a new lock fitted to a
door whose keys everyone still holds in the old shape*: nothing opens. When the work
was merged, the automated pipeline did its job and **instantly deployed the new login
code** — but the database upgrade is a deliberate manual step that hadn't run yet. For
a few minutes, **every login on the live site returned an error.** No panic, though:
we'd *written the recovery recipe in advance* (the very runbook from 13.5). We ran the
database upgrade, and logins came back to life immediately; then we shipped the new
frontend and ran a full top-to-bottom test. **Lesson — the whole project in
miniature:** the failure was real, but because the recovery was documented and
rehearsed, it was a five-minute fix, not an outage. We also learned a permanent rule:
once the database is upgraded, you can't roll *back* the login code (the old code
can't read the new scrambled passwords) — recovery is always *forward*. That's now
written into the decision log.

### 13.8 The audit log that wrote to nowhere

The final test passed but for one oddity: the admin **audit lines** (who promoted
whom) weren't showing up in the logs — even though the code was clearly writing them.
The cause was a classic gotcha: programs **buffer** their output, jotting notes on a
pad and only handing the pad over when it's full, to save effort. For a long-running
service, that pad might not be handed over for ages — so the audit notes sat in
memory, invisible. (Confusingly, the routine request logs *did* show, because they're
written a different, immediate way.) The fix was a single standard setting —
`PYTHONUNBUFFERED=1` — telling the program "hand over every note immediately." We
applied it, watched an audit line appear the instant a role changed, and confirmed it
survived the next automated deploy. **Lesson:** "the code is correct" and "the output
is visible" are two different claims — verify the second, not just the first.

---

## 14. Decisions and trade-offs

*Good engineering is making deliberate choices and being able to defend them. Each of
these follows the same shape: **what we chose, the alternatives, why we rejected them,
and the trade-off we accepted.** (The full versions live in `docs/DECISIONS_MADE.md`.)*

- **Scramble passwords now, not "later."** *Alternatives:* add roles now and hash
  passwords in a future pass. *Rejected because* doing access-control on unprotected
  passwords is a half-measure an assessor would immediately question, and the login
  image had to be rebuilt anyway. *Trade-off accepted:* a one-time, carefully
  sequenced database upgrade (the one that briefly broke logins in 13.7).

- **Polling, not live-push, for the "ready" badge.** *Alternatives:* Server-Sent
  Events or WebSockets (instant push). *Rejected because* for a single-user demo a
  few seconds' lag is invisible (the conversion itself takes longer), and push adds
  real complexity. *Trade-off accepted:* a few seconds of latency, and a known
  upgrade path if usage ever grew to thousands of concurrent users.

- **No in-app admin stats panel.** *Alternatives:* build a stats screen of uploads,
  bytes, queue depth. *Rejected because* the Grafana dashboard already shows system
  metrics properly; a second, weaker copy inside the app duplicates it. *Trade-off:*
  admins read operational numbers in Grafana, not the app.

- **Admin checks at the gateway only.** *Alternatives:* have every service
  independently verify the wristband ("defence in depth"). *Rejected (for now)
  because* the back-end services are sealed inside the cluster and only the gateway
  is exposed. *Trade-off accepted:* a real but contained gap — a malicious pod
  *inside* the cluster could call the auth service directly. Documented, with the
  proper fix named (service-to-service identity / a mesh).

- **Audit trail to stdout, not a tamper-proof ledger.** *Alternatives:* a dedicated,
  append-only audit table. *Rejected because* it's a whole subsystem for a demo.
  *Trade-off:* the audit answers who/whom/what but isn't tamper-evident — fine for a
  dev system, named as a gap for a real one.

- **Conservative admin guardrails.** *Alternatives:* let admins demote themselves
  once another admin exists. *Rejected because* admin lockout is a self-inflicted
  outage with no in-app recovery. *Trade-off:* slightly less flexibility for far more
  safety.

- **PR builds don't push images.** *Alternatives:* publish every PR's images.
  *Rejected because* it clutters the registry and weakens merge discipline.
  *Trade-off:* genuine pre-merge cluster testing needs manual image building — which
  bit us once (13.6) and is documented.

---

## 15. Known limitations and the next iteration

*Honest about what isn't built. For each, the "real fix."*

- **PostgreSQL has no persistent disk.** If its pod restarts, the user table is lost
  and must be re-seeded. *Fine for dev; the real fix* is attaching a persistent
  volume or using a managed database (AWS RDS).
- **Services trust each other inside the cluster.** The auth service's user-management
  endpoints trust any in-cluster caller; only the gateway's outer wall enforces
  "admins only." *Real fix:* cryptographic service-to-service identity (mutual TLS or
  a service mesh) so every hop re-checks.
- **Audit log is plain stdout.** Visible but not tamper-evident. *Real fix:* an
  append-only audit store written in the same transaction as the change.
- **No automated tests.** CI lints, builds, and scans, but runs no unit/integration
  tests. *Real fix:* a `pytest` stage gating every PR.
- **No per-service business metrics.** Monitoring is cluster/node level only. *Real
  fix:* expose Prometheus metrics from each service (conversions, queue depth, error
  rates).
- **Single region, one worker node.** No failover. *Real fix:* multiple nodes across
  availability zones, and multi-region for true disaster recovery.
- **No automated rollback on a bad deploy.** *Real fix:* a health-gated deploy that
  auto-reverts (the Jenkins pipeline is designed for this; the server isn't running).
- **The production Jenkins server isn't provisioned** (the pipeline-as-code is fully
  written). *Real fix:* stand up a Jenkins instance and connect it.
- **Two features deferred:** in-browser **audio preview** (play before downloading)
  and **email verification** on sign-up. Both are scoped and waiting, neither needed
  for the core demo.

---

## 16. Glossary

- **API / endpoint** — a specific "service window" a program offers, like the
  different windows at a post office. `/login` and `/upload` are endpoints.
- **JWT (token)** — a tamper-proof festival wristband proving who you are; shown on
  every request so you don't re-log-in each time.
- **bcrypt** — a one-way blender for passwords; you can check a match but can't
  reverse it.
- **Microservice** — one small program doing exactly one job, talking to others
  through defined channels (vs. one giant do-everything program).
- **Queue (RabbitMQ)** — a mailbox/conveyor belt that lets one service hand work to
  another without waiting.
- **Container** — a running program sealed with everything it needs, so it behaves
  the same everywhere.
- **Image** — the vacuum-sealed package a container is started from; the recipe.
- **Registry (Docker Hub / ECR)** — the warehouse storing images.
- **Pod** — a sealed glass jar holding a running container, the unit Kubernetes
  manages.
- **Kubernetes (K8s)** — the automated "shift manager" that keeps the right software
  running and restarts what fails.
- **EKS** — Amazon running Kubernetes' "brain" for you, so you only manage the
  workers.
- **Helm** — a package manager for Kubernetes; installs ready-made bundles (we use it
  for MongoDB, PostgreSQL, RabbitMQ, and the monitoring stack). Think "app store for
  cluster components."
- **Terraform** — Infrastructure as Code: you write down the cloud you want, it makes
  reality match.
- **OIDC** — a way to issue short-lived "visitor badges" so the CI robot never holds a
  permanent cloud key.
- **IAM** — Amazon's permission system; job-specific keyrings that grant only what's
  needed.
- **GridFS** — MongoDB's way of storing big files by tearing them into chunks.
- **CI/CD** — the automated assembly line (CI checks + packs code) and delivery line
  (CD ships it).
- **Trivy** — a scanner that blocks containers carrying known serious vulnerabilities.
- **ffmpeg** — the industry-standard audio/video tool; MoviePy drives it to extract
  the audio.
- **Rolling restart** — deploying a new version by bringing it up before taking the
  old one down, so the app is never offline.

---

*This guide is self-contained: a group member can read it cover to cover and have
full context, a guest can follow the upload-to-download story without prior
knowledge, and an assessor can see the reasoning behind every decision. For the
line-by-line code companions, see the `*_EXPLAINED.md` files alongside each service;
for the formal trade-off log, `docs/DECISIONS_MADE.md`; for bringing the cluster back,
`DEPLOYMENT_GUIDE.md`.*
