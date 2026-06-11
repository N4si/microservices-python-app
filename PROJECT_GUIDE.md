# VidCast — The Complete Project Guide

> A plain-English walkthrough of the entire VidCast platform, written for anyone:
> a bootcamp assessor, an interviewer, a teammate joining on day one, or a curious
> friend who doesn't work in tech. No prior knowledge assumed. Where a technical
> term is unavoidable, it's explained in parentheses the first time it appears.
>
> If you read this end to end, you'll understand not just *what* VidCast does, but
> *why* every piece is built the way it is — enough to discuss it confidently in a
> 30-minute technical interview.

---

## 1. What VidCast Is

**VidCast turns a video recording into a podcast-ready audio file.** You upload an
MP4 (a video file), and a few moments later you get an email with a link to
download the MP3 (just the audio, extracted from the video). That's the whole
user-facing product: "drop in a video, get back the audio." Useful for turning a
recorded talk, webinar, or Zoom call into something you can publish as a podcast.

But here's the thing to understand before anything else: **the converter is the
demo; the platform is the project.** Extracting audio from a video is a few lines
of code — any developer could write it in an afternoon. That part is deliberately
simple, because it's not the point. The point is *everything around it*: how the
work is queued so it survives a crash, how the system scales itself down to zero
when nobody's using it and back up under load, how secrets are kept out of the
code, how a code change travels safely from a developer's laptop to a live server,
how the whole thing is monitored, cost-tracked, locked down, and rebuildable from
scratch in twenty minutes. VidCast is a small, easy-to-explain application wrapped
in a **production-grade platform** — the kind of infrastructure a real company runs
behind a much more complicated app.

So when you read this guide, think of the video-to-audio feature as a worked
example — a realistic but simple thing for the platform to *do* — and pay attention
to the machinery underneath. That machinery is what makes this a platform
engineering project rather than a coding exercise: event-driven messaging,
self-healing deployments, zero-trust networking, supply-chain security, autoscaling,
observability, and infrastructure-as-code, all running on Amazon's managed
Kubernetes service. Every one of those is a thing companies hire for, and each is
implemented here honestly — with its real-world trade-offs and limitations written
down rather than hidden.

---

## 2. Architecture Overview

VidCast is built as **microservices** — instead of one big program that does
everything, the work is split into several small programs, each with one job, that
talk to each other. Think of a restaurant: rather than one person taking orders,
cooking, and washing up, you have a host, waiters, chefs, and a dishwasher, each
specialised and each able to be added or replaced independently.

### The five services (the staff)

| Service | One-sentence job | Analogy |
|---|---|---|
| **Frontend** | The website you actually click on — login, upload, download, dashboard. | The **shopfront** — the only part customers see. |
| **Gateway** | The front door for all requests; checks you're logged in, takes your upload, hands back your download. | The **receptionist** — everyone goes through them; they direct traffic but don't do the heavy work. |
| **Auth** | Checks your email and password and issues a "you're logged in" token. | The **security guard** at the door checking ID and handing out a wristband. |
| **Converter** | Takes a video off the queue, extracts the audio with ffmpeg, saves the MP3. | The **workshop** out back — where the actual product gets made. |
| **Notification** | Watches for finished MP3s and emails the user a download link. | The **mailroom** that posts the "your order is ready" letter. |

A note on technology, for the technically minded: auth and gateway are **Flask**
(a Python web framework) apps run under **gunicorn** (a production web server);
converter and notification are Python programs using **Pika** (a RabbitMQ client
library) that sit and wait for messages rather than serving web pages; the frontend
is a **React** app (a popular JavaScript UI framework) served by **nginx** (a web
server). The converter does the audio extraction with **ffmpeg** (the standard
open-source media-processing tool), wrapped by a Python library.

### The four data stores (the storage rooms)

| Store | What it holds | Analogy |
|---|---|---|
| **PostgreSQL** | User accounts: email, hashed password, role (admin/user). | The **filing cabinet** of membership records — structured, one row per member. |
| **MongoDB / GridFS** | The actual video and audio files (which are big). | The **warehouse** — built to store large boxes, not index cards. (GridFS is MongoDB's way of storing files too big for a normal record, by splitting them into chunks.) |
| **RabbitMQ** | The to-do lists ("a video needs converting", "an MP3 needs emailing"). | The **internal mail system / pigeonholes** — one department drops a note, another picks it up later. |
| **Redis** | Short-lived "we already handled this job" tickets. | The **coat-check counter** — a tiny ticket that says "this one's taken," thrown away after a few minutes. |

PostgreSQL, MongoDB, and RabbitMQ are the "three datastores"; Redis is a small
fourth helper used only to prevent duplicate work (explained in §6).

### How data flows between them

The key idea is that VidCast is **event-driven and asynchronous** (jobs happen in
the background, not while you wait). When you upload a video, the gateway doesn't
make you sit there while it converts — it stores your file, drops a note in the
mail system, and immediately says "got it." The conversion happens later, and you
find out by email. This is exactly how big systems handle slow work: accept it
fast, do it in the background, notify when done.

Here's the whole picture as a text diagram. Read it top to bottom:

```
   YOU (browser)
      │  click "Login", "Upload", "Download"
      ▼
 ┌─────────────┐
 │  FRONTEND   │  React website (nginx)         NodePort :30006
 └─────┬───────┘
       │  /api/* proxied to ↓
       ▼
 ┌─────────────┐      check password      ┌──────────┐    ┌────────────┐
 │   GATEWAY   │ ───────────────────────► │   AUTH   │ ─► │ PostgreSQL │  (users)
 │  (Flask)    │ ◄─── "here's a token" ── │ (Flask)  │    └────────────┘
 └─────┬───────┘                          └──────────┘
       │  store the uploaded video
       ▼
 ┌────────────────────┐
 │ MongoDB / GridFS   │  (the video file)
 └────────────────────┘
       │  write a "job to do" note (the outbox)
       ▼
 ┌────────────────────┐   relay   ┌──────────────────────────┐
 │ outbox (in Mongo)  │ ────────► │  RabbitMQ  "video" queue │
 └────────────────────┘           └────────────┬─────────────┘
                                                │  picked up by
                                                ▼
                                        ┌─────────────┐    extract audio (ffmpeg)
                                        │  CONVERTER  │ ──────────────────────────►  MP3
                                        └──────┬──────┘                               │
                                               │  save MP3 to GridFS, then ◄──────────┘
                                               ▼
                                   ┌──────────────────────────┐
                                   │  RabbitMQ  "mp3" queue    │
                                   └────────────┬─────────────┘
                                                │  picked up by
                                                ▼
                                        ┌──────────────┐    sends email
                                        │ NOTIFICATION │ ─────────────────►  YOU 📧
                                        └──────────────┘   "your audio is ready"
       │
       ▼  later, you click the download link
 ┌─────────────┐
 │   GATEWAY   │ ── reads MP3 from GridFS ──►  streams the file back to your browser
 └─────────────┘
```

(Redis isn't drawn because it's a side-helper: the converter and notification each
quickly check Redis — "have I already done this exact job?" — before doing work, so
a job that somehow arrives twice isn't processed twice.)

---

## 3. The User Journey — What Happens When You Upload a Video

Let's walk the whole thing slowly, one step at a time. Each step names the service
responsible, so you can map it back to the diagram above.

**Step 1 — You log in.** You open the website (the **frontend**) and type your email
and password. The frontend sends those to the **gateway**, which forwards them to
the **auth** service. Auth looks up your email in **PostgreSQL** and checks your
password. Crucially, it doesn't store your actual password — it stores a **bcrypt
hash** (a scrambled, one-way version; explained in §6). It scrambles what you typed
the same way and compares the scrambles. If they match, you're in.

**Step 2 — You get a token (JWT).** On a successful login, auth issues a **JWT**
(JSON Web Token) — a small, digitally-signed string that proves "this person logged
in successfully and is an admin/user." Think of it as a **festival wristband**: the
guard checks your ID once at the gate and gives you a wristband; after that, you
flash the wristband instead of showing ID again. Your browser holds the token and
attaches it to every later request, so the gateway can trust you without
re-checking your password each time.

**Step 3 — You upload a video.** You pick an MP4 and hit upload. The browser sends
the file (with your token attached) to the **gateway**. The gateway checks the
token is valid, then needs to store the file. Videos are large, so it puts them in
**MongoDB GridFS** (the warehouse for big files). GridFS chops the file into chunks
and stores them; it hands back an ID (`video_fid`) — like a warehouse shelf
reference for "your video."

**Step 4 — The gateway records a job in the outbox.** Now the gateway needs to tell
the rest of the system "there's a video to convert." Instead of phoning the message
system directly (which might be down), it writes the job into an **outbox** — a
little to-do note saved *in the same database* as the video, marked "not sent yet."
Then it immediately replies to you: "success!" You're done waiting; the rest happens
in the background. (Why the outbox instead of messaging directly? See §6,
*Transactional outbox* — it's so an upload can never be silently lost.)

**Step 5 — The relay publishes the job to RabbitMQ.** A separate little program, the
**outbox-relay**, continuously reads the outbox looking for unsent notes. It finds
yours, publishes it as a message onto the **RabbitMQ "video" queue** (drops it in
the right pigeonhole), and marks the note "sent." The job is now officially in the
mail system, waiting for a worker.

**Step 6 — The converter picks it up.** The **converter** service is always watching
the "video" queue. It takes your message, reads the `video_fid`, and pulls the video
back out of GridFS. Before doing the work, it asks **Redis**: "have I already done
job `video_fid`?" If not, it claims the job and proceeds.

**Step 7 — ffmpeg extracts the audio.** The converter runs **ffmpeg** to strip the
audio out of the video and produce an MP3. This is the "actual product being made"
step — and the only genuinely CPU-heavy part of the whole system.

**Step 8 — The MP3 is stored and a new job is queued.** The converter saves the MP3
back into **MongoDB GridFS** (getting an `mp3_fid`), then publishes a new message
onto the **RabbitMQ "mp3" queue**: "an MP3 is ready, tell the user."

**Step 9 — Notification sends the email.** The **notification** service watches the
"mp3" queue. It picks up your message and uses **smtplib** (Python's email library)
to send you an email via Gmail, containing the file ID you'll need to download. Like
the converter, it first checks Redis so you never get two emails for one job.

**Step 10 — You download your audio.** You click the link in the email (or use the
download page). The request goes to the **gateway**, which reads the MP3 back out of
GridFS and streams it to your browser. You now have your podcast-ready audio file.

The beautiful part: steps 5–9 all happen on their own, in the background, each
service doing one job and handing off to the next via the queues. If any service is
briefly busy or restarting, the messages wait patiently in RabbitMQ until it's ready
— nothing is lost, nobody is kept waiting at the front desk.

---

## 4. Where It All Runs — Infrastructure

So we have these programs. Where do they actually *live*, and how do they stay
running? This is the infrastructure layer, and it's built from a handful of tools
that each solve one problem.

**Docker — the shipping container.** Before Docker, "it works on my machine" was a
real nightmare: code that ran on a developer's laptop would break on the server
because of slightly different versions of things. Docker fixes this by packing each
service — the code *and* everything it needs to run (Python, libraries, ffmpeg) —
into a **container**: a sealed, standardised box. Just like a shipping container can
go on any truck, train, or ship without anyone repacking it, a Docker container runs
identically on any machine. Each VidCast service is its own container image.

**Kubernetes — the harbour master.** Once you have lots of containers, something has
to decide where they run, restart them if they crash, replace them during updates,
and connect them to each other. **Kubernetes** (often "K8s") is that orchestrator —
the **harbour master** directing which container goes on which ship, making sure the
right number are running, and rerouting around problems. You tell Kubernetes "I want
two copies of the gateway running, always," and it makes that true and keeps it true,
even if a machine dies.

**EKS — renting the harbour from Amazon.** Running Kubernetes yourself is a lot of
work. **EKS** (Elastic Kubernetes Service) is Amazon's managed Kubernetes — AWS runs
the complicated "control plane" (the brain of Kubernetes) for you, and you just bring
the machines that run your containers. VidCast runs on EKS in Amazon's **London
region** (`eu-west-2`), on a **single machine** (an `m7i-flex.large`: 2 CPUs, 8 GB
of memory). One node keeps costs tiny; it's a deliberate constraint that shapes many
later decisions (you'll see "single-node" mentioned a lot — it's why we scale to
zero, why we skip some redundancy, etc.).

**Terraform — the self-building blueprint.** Here's the powerful part: none of the
AWS infrastructure (the network, the Kubernetes cluster, the machine, the
permissions, the container registry) is created by clicking around in the AWS
console. It's all described in code using **Terraform**. Terraform is like an
architect's blueprint that *builds itself*: you write "I want a network, a cluster,
one node, these permissions," run one command, and Terraform creates it all in the
right order. Run a different command and it tears it all back down. This means the
**entire infrastructure can be destroyed and recreated from scratch in about 20
minutes** — which is exactly what VidCast does to save money (destroy it overnight,
rebuild it when needed). Infrastructure-as-code also means the setup is versioned,
reviewable, and repeatable, instead of a pile of forgotten manual clicks.

**Helm — the app installer.** Some things you run on Kubernetes are standard,
off-the-shelf software (the databases, the monitoring stack). **Helm** is the
"app store" for Kubernetes — it packages complex software into installable
**charts** so you can install MongoDB or Prometheus with one command and some
settings, instead of hand-writing hundreds of lines of configuration. VidCast uses
Helm to install its datastores and most of its platform tools.

**Kustomize — one recipe, two kitchens.** VidCast runs in more than one environment
(a lighter "dev" setup and a heavier "prod" setup). Rather than duplicate all the
configuration, it uses **Kustomize**: a **base recipe** of the core setup, plus small
**overlays** that tweak it per environment ("dev runs one copy of each service; prod
runs more"). Same base, two variations — no copy-paste, no drift between them.

Put together: Terraform builds the AWS foundation and the Kubernetes cluster; Helm
installs the off-the-shelf software onto it; Kustomize lays down VidCast's own
services in the right shape for the environment; and Kubernetes keeps the whole thing
running and self-healing on top of Docker containers. Destroy it all, run two
commands, and twenty minutes later it's back.

---

## 5. How Code Gets to Production — CI/CD Pipeline

A developer changes some code on their laptop. How does that change safely become
part of the live, running system without anyone manually copying files onto a
server? That's **CI/CD** (Continuous Integration / Continuous Delivery), and
VidCast's pipeline is worth understanding step by step because each step catches a
specific kind of problem.

**Step 1 — Push to GitHub.** The developer commits their change and pushes it to
**GitHub** (where the code lives). This automatically triggers the pipeline — a
series of automated checks and actions defined in a file in the repo
(`.github/workflows/ci.yml`), run by **GitHub Actions** (GitHub's built-in automation
that runs your steps on fresh, throwaway machines).

**Step 2 — Lint.** First, the code is **linted** with a tool called `ruff` — an
automated style-and-correctness checker that catches obvious mistakes (unused
variables, syntax slips, bad imports) in seconds. This runs first and fast, so a
trivial typo fails the build before wasting time building anything. Think of it as
spell-check before you print.

**Step 3 — Build the images.** For each of the five backend services *in parallel*
(all at once, to save time), the pipeline runs `docker build` to package the code
into a container image, tagged with the short git commit hash (so every build is
uniquely traceable back to the exact code it came from).

**Step 4 — Scan for vulnerabilities (Trivy).** Each freshly-built image is scanned by
**Trivy**, a security scanner that checks every package inside the image against
databases of known vulnerabilities. If it finds anything rated **CRITICAL or HIGH**,
the build **fails** (`exit-code: 1`) — the bad image never ships. This is the
quality inspector on the assembly line who can stop the whole line. (`ignore-unfixed`
means it won't fail you for vulnerabilities that have no patch available yet — you
can't fix what the upstream maintainers haven't.)

**Step 5 — Push to Docker Hub.** If linting and scanning pass *and* this is the main
branch, the images are pushed to **Docker Hub** (a public registry of container
images), where the cluster can later pull them. Only main-branch pushes publish —
pull requests get tested but don't ship.

**Step 6 — OIDC federation: the day pass, not the permanent keycard.** When the
pipeline needs to talk to AWS, it faces a classic security problem: how do you give
an automated job AWS permissions without storing long-lived AWS keys somewhere they
could leak? The old way was to paste a permanent secret key into the pipeline — a
**permanent keycard** that, if stolen, works forever. VidCast uses **OIDC
federation** instead: GitHub vouches for the workflow's identity ("this really is the
`ci.yml` job on the main branch of this repo"), and AWS hands back a **temporary,
short-lived credential** — a **day pass** that expires in minutes and only works for
that specific job. There's no long-lived secret to steal. (The login email and
trust setup for this is the GitHub OIDC provider configured in Terraform.)

**Step 7 — Deployment, the GitOps way (Argo CD).** Now the new image exists — how
does it get onto the cluster? Here VidCast uses a modern, safer model called
**GitOps**, run by a tool called **Argo CD**. The old way ("push") had the pipeline
hold cluster credentials and shove changes in (`kubectl set image`). The new way
("pull") flips it: **Argo CD lives *inside* the cluster and continuously pulls the
desired setup from Git**, making the cluster match what's described in the repo. Git
becomes the single source of truth for "what should be running."

Picture Argo CD as a **diligent gardener** who has a copy of the garden's master
plan (Git) and constantly walks the garden making the real plants match the plan. If
someone sneaks in and moves a plant (a manual change to the cluster), the gardener
quietly puts it back. If the plan changes (you merge a new image tag), the gardener
plants the new thing. The benefits are real: the pipeline no longer needs cluster
keys (smaller blast radius if it's ever compromised), every deployment is a
reviewable Git commit (full audit trail; roll back with `git revert`), and any drift
between "what's running" and "what should be running" is detected and corrected
automatically.

**Step 8 — Dev auto-sync vs prod manual gate.** VidCast has two Argo CD
"Applications": **dev** and **prod**. Dev is set to **auto-sync** — the moment the
plan changes in Git, the gardener applies it automatically. Prod is deliberately
**not** auto-sync — Argo CD notices the change and shows "out of sync," but it
**waits for a human to click Sync**. That pause *is* the production approval gate.
The clever detail: the gate isn't a special "if approved" step in the code — it's the
*absence* of the auto-sync setting on the prod Application. The most important line
in the prod config is the one that isn't there.

There's also a **Jenkinsfile** in the repo, which expresses the same pipeline in a
different tool (Jenkins) and adds a Docker Swarm staging environment plus an explicit
"Deploy to Production?" approval button — demonstrating that the same CI/CD concepts
translate across tools, and connecting the Docker Swarm learning module to the
Kubernetes production deployment.

---

## 6. Platform Capabilities

This is the heart of the project — the production-grade features that turn a simple
app into a real platform. They were built across four "sprints" and are grouped here
by what problem they solve. For each, here's *what it does, what problem it solves,
and why it matters* (with the interview-relevant detail).

### Reliability & Messaging

**Transactional outbox (A1) — never lose an upload.**
The problem: when you upload a video, two things must both happen — store the file,
*and* tell the system to convert it. If the message system (RabbitMQ) is down for the
split second between those two steps, you'd have a stored video that nobody knows to
convert: a silently lost upload. The outbox pattern fixes this by writing the "please
convert this" instruction as a row *in the same database as the video*, marked "not
sent." A separate program (the relay) reads those rows and publishes them to RabbitMQ
later, retrying until it succeeds. The instruction can't be lost because it's sitting
durably in the database until it's confirmed sent. The analogy: instead of phoning in
an order the instant a customer walks out (and losing it if the line's busy), you
write every order in your own ledger first, then work through the ledger calling them
in — the ledger is the safety net.

Why it matters / the interview detail: the relay runs as a **separate deployment with
exactly one copy**, *not* as a background thread inside the gateway. Why? The gateway
runs as multiple processes (under gunicorn — see A4), so a thread inside it would run
once *per process*, and you'd get several relays all publishing the same row multiple
times — the exact duplicate-send bug the outbox exists to prevent. Making it a
single-replica deployment makes "exactly one publisher" a structural guarantee rather
than something you have to police. Honest limitation worth stating: the file-write and
the outbox-write aren't a single atomic transaction (true atomicity needs a MongoDB
replica set, which the single in-cluster Mongo isn't), so a crash in the tiny window
between them could still orphan a file — but that's the *same* small window the
original code had, and the outbox eliminates the much *larger* "broker down = lost
event" window.

**Retry / Dead-Letter Queue topology (A3) — handle poison messages.**
The problem: what if a message can *never* succeed — a corrupt video ffmpeg can't
read, or a permanently invalid email address? The naïve approach (put it back on the
queue and try again) loops it **forever**, pinning a worker and blocking everyone
behind it (a "poison message"). The fix is **bounded retries plus a dead-letter
queue**: try a few times with a delay, and if it still fails, move it to a special
**dead-letter queue** (the "problem pile") where a human can inspect it later, and get
on with the rest of the work. VidCast builds three queues per pipeline — the main
queue, a `.retry` queue, and a terminal `.dlq` queue — plus a shared dead-letter
exchange.

Why it matters / the interview detail: the *delay* between retries has no timer in the
code at all — the `.retry` queue is given a **time-to-live** and *no consumer*, so a
message simply expires after the delay, and RabbitMQ's expiry machinery routes it back
to the main queue for another attempt. The broker's own TTL-and-dead-letter feature
*is* the delay mechanism. An explicit `x-retry-count` header (rather than RabbitMQ's
built-in `x-death`) tracks attempts, so the behaviour is identical across broker
versions. After the retry limit (default 3, so 4 total attempts), the message goes to
the terminal dead-letter queue, which nothing consumes — it stops and waits for a
human. This also fixed a real crash: a bad video used to throw an error that killed
the converter pod; now it's caught and dead-lettered.

**Idempotent consumers (A2) — duplicates become no-ops.**
The problem: the outbox and the retry system both deliberately deliver "at least
once" — meaning a message could occasionally arrive twice (e.g. the relay publishes,
then crashes before marking it sent, so it publishes again on restart). Without a
guard, a duplicate means converting the same video twice and sending two emails.
**Idempotency** makes "process this job twice" have the same effect as processing it
once. The mechanism is a single atomic Redis command (`SET NX EX`): the first
delivery sets a key for that job ID and proceeds; any later delivery finds the key
already there and skips. The key auto-expires after a few minutes (so a crashed worker
can't wedge a job forever). The analogy: a coat-check ticket — the first person to
claim a job gets the ticket; anyone else who shows up with the same job sees it's
already taken and walks away.

Why it matters / the interview detail: there's a subtle, much-tested rule about *when
to release the ticket*. On **success**, keep the key (so a genuine duplicate is
suppressed). On a **retryable failure**, *delete* the key — because the retry will
redeliver the same job, and if the key were still there the retry would be skipped
forever and the job would silently never complete. On a **permanent (dead-letter)
failure**, keep the key (the job is unfixable; don't reprocess it). Getting this
backwards turns a transient error into a permanent silent loss. Also: if Redis itself
is down, the system **fails open** (processes anyway) — the worst case is a rare
duplicate, which is far better than halting the whole pipeline every time Redis blips.

**Gunicorn production server (A4) — a real web server, not the toy one.**
The problem: Flask ships with a built-in development web server that even *prints a
warning telling you not to use it in production* — it handles one request at a time
and has no worker model. VidCast swaps it for **gunicorn**, a proper production web
server that runs the app as several worker processes, so one slow request no longer
blocks everyone. No application code changed — gunicorn just imports the existing app
and serves it better.

Why it matters / the interview detail: gunicorn running the gateway as *multiple
processes* is precisely why the outbox relay (A1) had to become a separate single-copy
deployment — this is the dependency that orders the whole reliability sprint. The
worker count is deliberately kept low (2, not the textbook "2×cores+1") because on a
single 2-CPU node already running a dozen pods, the textbook number would
oversubscribe the machine — and the CPU-heavy work lives in the converters, not the
web tier. Horizontal scaling is handled by adding *pods* (HPA, below), not cramming
in more workers.

**KEDA autoscaling + HPA (A7) — right-size automatically, even to zero.**
The problem: the converter is idle most of the time (nobody's uploading), but bursts
hard when work arrives. Keeping it always-on wastes resources; keeping it too small
makes uploads slow. VidCast uses **two autoscalers, each matched to its workload**.
The converter is scaled by **KEDA** (Kubernetes Event-Driven Autoscaler) on **queue
depth** — how many videos are waiting — and KEDA can scale it all the way to **zero**
when the queue's empty, then back up to 3 as work piles in. The gateway is scaled by
the standard **HPA** (Horizontal Pod Autoscaler) on **CPU usage**, staying at least 1
(it's user-facing and must always answer).

Why it matters / the interview detail: match the signal to the workload — a queue
worker should scale on *how much work is queued* (a leading signal; you know work is
coming before CPU even rises), and a web server on *how busy it is*. A plain HPA
*can't* scale to zero (minimum 1) and reacts to CPU only *after* the backlog builds.
The footgun avoided: if KEDA and an HPA both target the *same* deployment they fight
over the replica count and oscillate — so they're kept on *different* deployments
(converter vs gateway), which never conflict. (One real-world wrinkle that bit us:
because KEDA now owns the converter's replica count, the GitOps tool Argo CD must be
told to *ignore* that field, or the two controllers tug-of-war over it.)

### Security & Access Control

**External Secrets Operator + Parameter Store (A9) — no secrets in the code.**
The problem: passwords, API keys, and database URIs must never sit in the Git repo
(public, forever, searchable). VidCast stores them in **AWS Parameter Store** (a
secure, encrypted key-value store) and uses the **External Secrets Operator (ESO)** —
a cluster add-on that pulls those secrets into Kubernetes at runtime, authenticating
via the cluster's own AWS identity (no long-lived keys). The analogy: Parameter Store
is a **safe-deposit box at the bank** — the app has a key that lets it retrieve the
contents at runtime, but the contents are never written down in the code.

Why it matters / the interview detail: it's **Parameter Store, not Secrets Manager**,
deliberately — Secrets Manager charges $0.40 per secret per month and *keeps billing
even after the cluster is destroyed*, while standard Parameter Store entries (and the
AWS-managed encryption key) are **free**. For seven secrets that's ~$3/month saved,
and it preserves the project's "$0 when the cluster is off" rule. One honest exception:
the RabbitMQ password is still created by RabbitMQ's own Helm chart (because that same
secret sets up the broker), so it isn't ESO-managed — that's documented, not hidden.

**NetworkPolicy default-deny (A6) — zero-trust networking.**
The problem: by default, every pod in a Kubernetes namespace can talk to every other
pod — a flat, open office where anyone can walk into any room. If one service is
compromised, the attacker can reach everything. VidCast flips this to **default-deny**:
every pod is blocked from all network traffic *except* the specific connections
explicitly allowed (gateway→auth, gateway→Mongo, converter→RabbitMQ, etc.). The
analogy: an office where **every door is locked by default** and you only get
key-card access to the specific rooms your job needs.

Why it matters / the interview detail: the **number-one mistake** here is that a
NetworkPolicy is *just a piece of paper* — something has to *enforce* it. On EKS the
default network plugin doesn't enforce policies unless you explicitly turn on the
enforcement agent (done in Terraform). Apply a default-deny without it and the API
accepts the policy, it *looks* applied, and nothing actually changes — you think
you're secure and you're not. The **second** classic mistake: the very first thing you
must allow is **DNS** (name lookups), because every service is reached by name; block
DNS and the whole app dies in a way that looks like total breakage rather than "DNS is
blocked." A real-world wrinkle we hit live: the policy for Kyverno's namespace had to
allow it to reach the cloud metadata service on port 80 to authenticate to the private
image registry — miss that and image-verification calls time out and block deployments.
Networking lockdowns are full of these "you forgot one allow" lessons, and they're
documented honestly.

**Kyverno policy-as-code (B2) — rules that enforce themselves.**
The problem: you can *write* rules like "no container may run as root" or "every
image must have a real version tag, not `latest`," but humans forget. **Kyverno** is
an **admission controller** — it sits in front of the Kubernetes API and inspects
every deployment *before* it's allowed to run, checking it against policies written as
code (YAML in Git). The analogy: a **building inspector** who checks every new
structure against the code before it's allowed to open. VidCast ships seven policies:
no `:latest` tags, must declare resource limits, must run non-root, must use a seccomp
profile (restricts dangerous system calls), must carry standard labels, no privileged
containers, and verify image signatures (the last one ties into supply chain, §6.5).

Why it matters / the interview detail: every policy starts in **Audit** mode, not
**Enforce**. Audit *records* violations without blocking; Enforce *rejects* them. If
you ship Enforce on day one, the first existing resource that violates a rule (and
several do) blocks deployments immediately — possibly including the very fix you're
trying to deploy. The disciplined path is Audit → read the violation reports → fix
everything → promote to Enforce only when clean. One honest residual: MongoDB and
PostgreSQL *can't* run fully non-root (their official startup scripts need root to
initialise, then drop privileges), so that one policy keeps a documented exception
for the two databases.

**Bcrypt password hashing + RBAC.**
The problem: storing passwords as plain text is catastrophic — one database leak and
every account is compromised. VidCast hashes passwords with **bcrypt**, a one-way
scrambling function deliberately designed to be *slow* (so attackers can't rapidly
guess billions of passwords) and salted (so identical passwords don't produce
identical hashes). At login, the typed password is hashed and compared to the stored
hash; the real password is never stored or recoverable. On top of this, **RBAC**
(Role-Based Access Control) gives each user a role (`admin` or `user`) carried in their
JWT, so admin-only pages and actions can be gated. The analogy: bcrypt is a **one-way
blender** — you can blend the fruit but never un-blend the smoothie back into fruit;
you just blend the next fruit and check if the smoothies match. Interview-relevant
gotcha we hit: the database and the auth *image* must be upgraded together — a
bcrypt-storing database with an old plain-text-comparing app (or vice versa) rejects
every login, because it's comparing a typed password against a scrambled hash.

**Pod security contexts (read-only rootfs, non-root, seccomp).**
The problem: if an attacker breaks into a container, you want them to find as little
power as possible. VidCast hardens every pod with a **security context**: run as a
**non-root** user (so a breakout doesn't own the host), a **read-only root filesystem**
(the attacker can't modify the running container or drop in tools), **drop all Linux
capabilities** (no special kernel powers), and a **seccomp profile** (block dangerous
system calls). This is **least privilege** applied to the container. Interview detail:
read-only-rootfs interacts with gunicorn, which needs to write a couple of temp files —
so exactly *one* writable scratch directory (`/tmp`) is mounted while everything else
stays read-only. Least privilege means "exactly the access needed, nothing more."

### GitOps & Deployment

**Kustomize overlays (A10) — one base, environment variations.**
The problem: dev and prod need *almost* the same configuration, differing only in a few
places (replica counts, image tags). Copy-pasting two full sets of config guarantees
they'll drift apart. **Kustomize** keeps a single **base** definition and small
**overlays** that patch it per environment. Dev runs one replica of each backend; prod
runs more — expressed as a tiny diff on top of the shared base, not a fork. The
analogy: a base recipe with "for the spicy version, add chilli" written in the margin,
rather than two entire cookbooks.

**Argo CD (B1) — the cluster pulls from Git.**
Covered in §5, but to restate as a capability: Argo CD is the engine that makes
**Git the source of truth** for what runs in the cluster. It continuously reconciles
the live cluster to match the repo, auto-correcting drift. **Dev auto-syncs**
(every merged change deploys itself); **prod waits for a human to click Sync** (the
approval gate). This replaces the old, riskier model where the CI pipeline held
cluster keys and pushed changes in. Every deployment becomes a reviewable, revertible
Git commit.

**The approval-gate migration story.**
Worth telling as a narrative: VidCast *started* with a "push" pipeline (CI ran
`kubectl set image` against the cluster using stored credentials). Moving to Argo CD
meant retiring that push step and replacing it with "merge a tag-bump commit, then
sync." Dev's gate became fully automatic; prod's gate became the deliberate *absence*
of auto-sync — a human reviews the diff in the Argo CD UI and clicks Sync. The lesson
for interviews: the safest production gate isn't a clever pipeline step you can
accidentally bypass; it's a structural property (no auto-sync) that *requires* a human
by construction.

### Observability & Cost

**SLO burn-rate alerting (B4) — alert on what users feel, not noise.**
The problem: naïve alerts are either too noisy (page someone at 3 a.m. for a harmless
30-second blip) or too slow (a steady tiny error leak silently drains reliability for
weeks without ever crossing a threshold). VidCast uses **SLOs** (Service Level
Objectives — explicit reliability targets like "99.9% of requests succeed") and the
matching idea of an **error budget**: the allowed amount of failure (for 99.9%, that's
0.1%, which over 30 days is about **43 minutes** of badness you're permitted to spend).
The mental flip: reliability isn't "100% or bust," it's a *budget* you deliberately
spend on shipping features — budget left, ship; budget gone, stop and stabilise.

The alerting technique is **multi-window, multi-burn-rate**, which sounds scary but is
intuitive. **Burn rate** = how fast you're spending the budget relative to
sustainable: burn rate 1 means you'll spend exactly 100% of the month's budget right
at month-end; burn rate 14 means you'll be empty in about a fourteenth of the time —
something is badly wrong *now*. **Multi-window** means an alert only fires if *both* a
**long** window (say 1 hour — confirms it's a real, sustained problem, not a blip) and
a **short** window (say 5 minutes — so the alert clears quickly once the problem ends)
are burning fast. The result: pages only on real, ongoing problems, and they
self-clear soon after recovery. Interview detail: one tricky bit is measuring an SLI
across the gateway's *two* gunicorn worker processes — each keeps its own counters, so
a scrape would read a random half; the fix is Prometheus "multiprocess mode" where the
workers write to a shared directory and the metrics endpoint sums across them.

**Prometheus + Grafana dashboards.**
**Prometheus** is the monitoring system that continuously collects numbers (metrics)
from every service — request counts, queue depths, conversion times, CPU. **Grafana**
turns those numbers into **dashboards** — live graphs of the system's health. VidCast
ships three custom dashboards (operations, SLO, cost), and the frontend's Dashboard
page even embeds the Grafana operations view directly. The analogy: Prometheus is the
**car's sensors** constantly reading speed, fuel, temperature; Grafana is the
**dashboard** that displays them so the driver can see at a glance.

**Kubecost FinOps (B3) — what does a conversion actually cost?**
The problem: the cloud makes it trivially easy to spend money and very hard to see
*who or what inside your cluster* caused the bill. AWS bills you for a *machine*; it
has no idea that machine ran twelve pods for four different features. **Kubecost**
reads how much CPU and memory each pod uses and multiplies by the machine's price to
**attribute** cost down to individual services — turning "the cluster costs ~$150/mo"
into the unit-economics number a business actually cares about: **"each conversion
costs $X."** That number literally joins a Kubecost metric (node hourly cost) with a
monitoring metric (conversions per hour) — a neat demonstration that the cost
instrumentation and the reliability instrumentation reinforce each other.

Why it matters / the interview detail: there's a lovely irony — on a tiny 2-CPU node,
Kubecost's *default* install (which bundles its own monitoring stack) would burn
roughly a whole CPU just to *measure* cost. The fix — point it at the Prometheus
already running and strip it to one small pod — is *itself* a FinOps decision: the cost
of measuring cost must be smaller than what it saves. Also worth knowing: Kubecost is
an *estimate* (list prices, can't see your Reserved-Instance discounts), so you use it
for *relative* answers ("the converter costs 3× the gateway", "cost per conversion rose
20% this week") and the actual AWS bill for *absolute* answers.

**The dangling-alert fix (M-2).**
A small but honest detail worth mentioning: an early version had alert rules that
referenced metrics the app didn't actually emit yet (the gateway's `/metrics` endpoint
had been removed during an earlier cleanup) — "dangling" alerts that could never fire
correctly. The fix was to re-add the proper metrics instrumentation so the SLO rules
have real data to evaluate. It's the kind of subtle gap that only shows up when you
wire monitoring end-to-end, and it's recorded rather than quietly papered over.

### Supply Chain

The overarching question this whole category answers: *"You pulled an image and ran
it. Prove it's really your code, built by your CI, and not tampered with."* Without
controls you can't — a tag is mutable and the contents are opaque. VidCast adds four
independent proofs.

**SBOM generation (A8).** An **SBOM** (Software Bill of Materials) is a complete,
machine-readable **ingredients list** of everything inside an image — every OS package
and library, with versions. Why it matters: when the next big vulnerability drops (the
next Log4Shell), "are we affected?" becomes a quick *lookup* against stored SBOMs
instead of a frantic rebuild-and-rescan of everything. It's the difference between
"what's in production?" being a guess versus a query.

**Trivy scanning + SARIF (A8).** Trivy (the vulnerability scanner from the CI pipeline)
can output its findings in **SARIF**, a standard format GitHub understands natively —
so the results show up right in the repo's *Security ▸ Code scanning* tab, inline and
deduplicated with history, instead of being buried in build logs. The pattern is two
Trivy runs: one **gate** that fails the build on CRITICAL/HIGH, and one **report** that
always uploads the SARIF (even when the gate fails) so you can see *why* it failed.

**Cosign image signing (A8/B5).** **Cosign** cryptographically **signs** each image so
its integrity and origin can be verified — like a **tamper-evident wax seal**. VidCast
uses **keyless** signing, which is elegant: instead of a long-lived private key you
must guard, the CI job presents its short-lived OIDC identity ("I am the `ci.yml`
workflow on main"), a service called **Fulcio** issues a certificate valid for ~10
minutes binding *that identity* to the signature, and the signature is recorded in
**Rekor**, a public append-only **transparency log** (tamper-evident forever). The key
expires in minutes — **there's no long-lived secret to leak**. The trust is rooted in
*identity*, not a stored key.

**Kyverno verify-images (B5).** This closes the loop: the Kyverno policy from §6.2 can
**verify those signatures at deploy time** — "is there a signature whose certificate
says it was made by *our* CI workflow, recorded in Rekor? If not, don't admit the pod."
Currently it runs in Audit mode and honestly reports our images as "not yet signed,"
because the signing step isn't wired into CI yet — that's the expected "supply chain
not yet closed" signal, flipped to enforcing the moment CI starts signing.

**The full chain: commit → build → sign → verify → admit.** Putting it together, every
hop adds a verifiable property: a developer **commits** code → CI **builds** the image
and the Trivy gate blocks CRITICAL/HIGH while an SBOM and SARIF are generated → the
image is **pushed by digest** to an immutable, scan-on-push registry → cosign
**keyless-signs** the digest and logs the signature in Rekor, attaching the SBOM as a
signed attestation → at deploy, Kyverno **verifies** the signature and the exact CI
identity before **admitting** the pod. From commit to running container, every step is
provable. (There's also **SLSA provenance**, a graded standard for how trustworthy the
*build* itself is — a signed statement of "image X was built from commit Y by workflow
Z" — documented with a recommendation to use the hardened reusable builder for the
highest level.)

---

## 7. Cost Story

A recurring theme you've seen throughout: VidCast is obsessive about cost, on purpose.
The whole platform is engineered so its **standing cost is $0 when the cluster is
off**, and the decisions reflect real, defensible trade-offs rather than reflexively
reaching for the most "production" option.

**Why managed datastores were skipped.** The biggest single cost decision. The
"proper production" move is to replace the in-cluster databases with AWS-managed ones
(RDS for PostgreSQL, MongoDB Atlas, Amazon MQ for RabbitMQ, ElastiCache for Redis).
VidCast deliberately **didn't**, and the deciding number is **Amazon MQ for RabbitMQ**:
its *smallest possible* broker is ~**$183/month** (there is no cheap tier, and no
"pause"). That single service costs more than the entire rest of the platform combined,
and more than the EKS control plane itself — on a project whose whole point is $0
when off. The all-managed version would run ~$262–273/month standing. So the managed
path is **documented and costed as the production migration story**, but the
in-cluster Helm charts stay — and critically, the *reliability patterns* that managed
services usually provide (no lost events, idempotent retries, dead-lettering) are
delivered **in code** (A1/A2/A3) against the in-cluster brokers instead. You get the
reliability story without the bill.

**Why Parameter Store over Secrets Manager.** As covered in §6: Secrets Manager bills
$0.40 per secret per month and persists after teardown; Parameter Store (standard tier,
AWS-managed encryption key) is **free**. Same security outcome, ~$3/month saved, $0
standing cost.

**The "$0 when off" target.** The cluster is genuinely **torn down to save money** and
rebuilt on demand in ~20 minutes via Terraform — preserving only free-to-keep things
(the Terraform state, the configuration file, the container images). This is why so
much of the design (infrastructure-as-code, scale-to-zero, no managed datastores) bends
toward "destroy and recreate cheaply."

**Node-budget tracking discipline.** Because everything runs on a *single* 2-CPU node,
there's a running discipline of tracking how much of that node each tool consumes — and
a self-imposed "~90% idle budget" gate. This is why the converter scales to zero (frees
the node when idle), why gunicorn uses few workers, why Kubecost is stripped to one
small pod and run on the lighter dev footprint, and why the monitoring stack is tuned
down. Every add-on has to justify its slice of two CPUs.

**What it costs when running.** While up, the dominant costs are the **EKS control
plane** (~$0.10/hour ≈ ~$73/month if left on, often cited alongside the ~$150/month
all-in figure for a continuously-running small cluster) and the **node itself**
(`m7i-flex.large` ≈ **$0.11/hour**). Run it for a demo and destroy it, and the bill is
a few cents to a couple of dollars. Leave it on all month and it's roughly $150. The
discipline is to treat "is the cluster on?" as the main cost lever.

---

## 8. Honest Gaps

A core value of this project is **honesty about what's incomplete** — the same standard
applied throughout the docs. Nothing below is hidden; each is a deliberate,
understood trade-off appropriate to a single-node portfolio cluster, with the
"proper" fix noted.

- **MongoDB and PostgreSQL require root to start.** Their official container
  entrypoints need root to initialise the database and fix file ownership, then drop
  privileges. So they can't satisfy the "run as non-root" policy, which keeps a
  *documented exception* for those two pods. Everything else runs non-root.

- **The single-node constraint shapes everything.** One `m7i-flex.large` is the whole
  cluster. That caps how much can run at once (there's even a hard ~29-pods-per-node
  limit from the networking layer that we hit when adding the monitoring stack — the
  fix was a temporary second node), means no real high-availability (the node *is* the
  failure boundary), and is why a single-instance in-cluster database is "acceptable
  here" — because nothing else is redundant either. Real HA needs multiple nodes and
  managed datastores, which is the documented (costed) production path.

- **The frontend's Grafana embed is IP-dependent.** The Dashboard page embeds the live
  Grafana view, but the Grafana address is baked into the frontend *at build time*
  (it's a `VITE_` variable). Because the node's public IP changes when the
  infrastructure is recreated, the frontend image has to be rebuilt with the new
  address each time the cluster is rebuilt. A more robust fix (runtime configuration or
  an ingress with a stable hostname) is noted but not built — fine for a demo, a real
  gap for a permanently-running site.

- **Metrics don't survive a pod restart.** The monitoring stack (Prometheus, Grafana)
  runs on **emptyDir** storage — ephemeral scratch space — because the cluster has no
  dynamic disk-provisioning driver installed and the design avoids billable, orphan-
  prone EBS volumes. The trade-off: if the Prometheus pod restarts, its history is
  gone. Acceptable on a transient demo cluster that's torn down nightly; a real
  deployment would use persistent volumes (or remote storage like Thanos/Mimir, which
  is also what true 30-day error-budget accounting would need — Prometheus here keeps
  only 7 days, so the *alerts* are fully correct but the dashboard's "budget remaining"
  panels are labelled as a 7-day view).

- **The SLO targets are demonstrative, not battle-tested.** The 99.9%-style objectives
  are reasonable and the burn-rate math is the standard Google SRE approach, but on a
  single-node demo cluster with synthetic traffic they're there to *demonstrate the
  technique* rather than to reflect hard-won production numbers. The end-to-end success
  SLI in particular spans two services minutes apart, so it's only trustworthy over
  long windows — which is documented.

- **Supply-chain signing isn't wired into CI yet.** The verification policy (B5) and
  all the signing concepts are in place, but the cosign-signing *step* isn't in the CI
  pipeline yet, so images are honestly reported as "not yet signed" (in Audit mode, so
  it never blocks). It flips to fully enforced the moment CI signs — by design, not by
  omission.

---

> **In one breath:** VidCast is a simple video-to-audio app deliberately wrapped in a
> production-grade platform — event-driven and crash-safe (outbox, retries,
> dead-letter queues, idempotency), self-scaling (KEDA to zero, HPA on load),
> locked-down (default-deny networking, policy-as-code, non-root hardened pods,
> secrets out of code), GitOps-deployed (Argo CD pulls from Git; prod gated by a
> human), fully observed (SLO burn-rate alerts, Grafana, per-conversion cost), and
> supply-chain-aware (SBOM, scanning, keyless signing, admission verification) — all
> on a single cheap EKS node that costs $0 when off and rebuilds from code in twenty
> minutes, with every limitation written down rather than hidden. The converter is
> the demo; the platform is the project.
