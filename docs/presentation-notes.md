# VidCast — Presentation Notes

## Timing Guide (12–15 minutes total)

| Section | Time | What to show |
|---------|------|--------------|
| Open with the product | 2 min | Live demo via web interface |
| Architecture walkthrough | 3 min | Architecture page in the frontend |
| Platform engineering | 5 min | Terraform, CI/CD pipeline, Grafana |
| What I'd do next | 2 min | Whiteboard / verbal |
| Real-world connection | 1 min | Verbal close |

---

## Opening (2 minutes)

**Don't start with "I built a Kubernetes cluster." Start with the problem.**

"Content creators record videos — Zoom calls, webinars, conference talks. They need the audio as a standalone podcast. Right now they have to download the video, find a converter tool, wait, re-upload. VidCast does it in one step: upload the video, we email you when the MP3 is ready."

Then open the web interface and do the upload live.

---

## Architecture Walkthrough (3 minutes)

Switch to the Architecture page in the frontend.

**Microservices → Restaurant analogy:**
"In a traditional monolith, one chef does everything — takes the order, cooks, plates, brings it to you. That chef gets overwhelmed at rush hour. VidCast uses specialised roles: the gateway is the host taking orders, the converter is the kitchen, the notification service is the runner bringing the food. Each role can be scaled independently — we run 4 converter workers because conversion is the slow part."

**Message queue → Post office analogy:**
"When you drop a letter at the post office, you don't wait at the counter for it to be delivered. You hand it over and walk away. RabbitMQ is our post office sorting room. You upload a video, it goes into the queue, and you get on with your day. The converter workers process it on their own schedule."

**JWT authentication → Security badge analogy:**
"You show your ID at reception once — that's the login. You get a badge — that's the JWT token. You swipe the badge at each door — that's the authorization header on every request. The auth service is reception; the gateway is the building with all the doors."

---

## Platform Engineering Walkthrough (5 minutes)

### Terraform (~1 minute)
Show the `terraform/` directory structure.

"Before this project, if someone deleted the cluster, I'd spend an hour clicking through the AWS console trying to remember every setting. Now: `terraform apply` recreates the entire platform in 20 minutes from version-controlled code. VPC, subnets, IAM roles, EKS cluster, security groups — all defined as code, reviewable, reproducible. This is the difference between an experiment and a production system."

**One important detail:** On this AWS account, T-type instances fail during EKS node group creation because EKS auto-generates a `CreditSpecification: unlimited` parameter that the account's SCP rejects. The Terraform EKS module includes a validation block that catches this immediately rather than failing after 15 minutes. That's a lesson in defensive infrastructure — encoding known constraints in the code rather than the documentation.

### CI/CD Pipeline (~2 minutes)
Show the GitHub Actions UI (or the `.github/workflows/ci.yml` file).

"Every push to main runs this pipeline automatically. Ruff lints all four Python services. Docker builds all four images in parallel. Trivy scans each image for critical vulnerabilities before any image reaches the registry. If Trivy fails, the pipeline stops — nothing gets pushed to Docker Hub, nothing gets deployed to the cluster.

This is called shift-left security — catching problems early in development rather than discovering them in production.

After CI passes, the CD pipeline runs automatically: configures kubectl for EKS, and deploys the new images with `kubectl set image`. Rolling deployment, zero downtime.

I also wrote a Jenkinsfile for teams using Jenkins — same stages, different syntax. It adds a Docker Swarm staging environment and a manual approval gate before production. A CI/CD pipeline is tool-agnostic; the concepts are the same whether you're using GitHub Actions, Jenkins, or GitLab CI."

### Grafana Dashboard (~2 minutes)
Open Grafana, navigate to VidCast Operations.

"This is what the on-call engineer sees. Pod status — are all 4 converters running? Restart count — has anything crashed in the last hour? Node CPU and memory — is the node being saturated? And this is the one I find most interesting for a demo: RabbitMQ queue depth. Watch what happens when I upload a video..."

[Upload a video and watch the video queue tick up, then back down as the converters process it.]

"That spike is real. You can see the video enter the queue, the converters pick it up, and the queue drain. This is what observability looks like — not just 'is it running,' but 'is it doing what it's supposed to do.'"

---

## Security Hardening (if time permits)

"Every pod runs as a non-root user — even nginx runs as uid 1001. The root filesystem is read-only, so even if an attacker compromises the converter, they can't modify the application binaries. We mount a writable `/tmp` directory as a separate volume so the ffmpeg conversion has somewhere to write temporary files without compromising the rest of the filesystem.

Every capability is dropped — no raw sockets, no sys_admin, no process injection. This is the principle of least privilege applied at the kernel level."

---

## What I'd Do Next (2 minutes)

"Three things I'd add with more time:

**KEDA — queue-based autoscaling.** Right now I have 4 converter replicas. With KEDA, the converter would watch the RabbitMQ queue depth and scale automatically — 4 replicas for 4 videos waiting, 20 replicas for 20 videos. You pay for compute only when there's work to do.

**Service mesh for mTLS.** Docker Swarm gives you mutual TLS between services built-in — every connection is encrypted and authenticated. In Kubernetes, you need a service mesh like Istio or Linkerd to get the same thing. For a demo, it's not worth the operational overhead. For production handling sensitive content, it's non-negotiable.

**External Secrets Operator.** Right now credentials are in Kubernetes Secrets — which are base64-encoded, not encrypted. The right approach is to store them in AWS Secrets Manager and fetch them at runtime via IRSA. The secrets never exist in the cluster YAML files at all."

---

## Closing (1 minute)

"Every media processing platform uses this pattern. YouTube when you upload a video. Spotify when they transcode your podcast. Companies processing mortgage documents, medical images, satellite data. The scale is different, but the architecture is the same: upload, queue, process, store, notify. VidCast is a production-quality implementation of that pattern on real AWS infrastructure."

---

## Common Interview Questions — With Answers

**"Why microservices instead of a monolith?"**
"For this use case, the converter is the bottleneck — ffmpeg is CPU-intensive and variable in duration. By separating it into its own service, we can scale it independently (4 replicas) without scaling the gateway or auth service. A monolith would require scaling everything together."

**"Why RabbitMQ instead of SQS or Kafka?"**
"RabbitMQ fits our scale — durable queues, simple consumer model, built-in management UI. SQS would be equally valid and easier to operate in AWS (no StatefulSet needed). Kafka would be overkill for this throughput; it shines at millions of messages per second with multiple consumer groups. For a production system I'd use SQS to reduce operational overhead."

**"What happens if a converter pod crashes mid-conversion?"**
"The RabbitMQ `basic_ack` is sent only after successful conversion. If the converter crashes before acknowledging, RabbitMQ redelivers the message to another converter. The video gets processed exactly once (at-least-once delivery). The MP3 might be stored twice if the pod crashes after storing but before acking — in production I'd add idempotency via a unique conversion ID."

**"Why Docker Swarm for staging instead of a second EKS cluster?"**
"A second EKS cluster costs ~$290/month. A Swarm EC2 instance costs ~$8/month. 97% cost reduction for functionally equivalent pre-production testing. The Jenkins pipeline deploys to Swarm first, runs a smoke test against the /healthz endpoint, waits for human approval, then deploys to EKS."

**"How would you handle secrets in production?"**
"Currently they're in Kubernetes Secrets — base64, not encrypted. In production: AWS Secrets Manager + External Secrets Operator + IRSA. Secrets are stored in Secrets Manager, fetched at runtime by the pod's service account, never in any YAML file. If EKS envelope encryption is enabled, the Secret objects in etcd are also encrypted at rest."

**"What is Trivy and why is it in the pipeline?"**
"Trivy is an open-source vulnerability scanner by Aqua Security. It scans container images for known CVEs in OS packages and application dependencies. In our pipeline, it runs after Docker build but before Docker push. If Trivy finds a CRITICAL or HIGH vulnerability that has a fix available, the pipeline fails — the image never reaches the registry. This is shift-left security: catching problems in CI rather than discovering them in production."
