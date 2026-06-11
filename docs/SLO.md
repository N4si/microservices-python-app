# SLO.md — VidCast Service Level Objectives (B4)

> ## ⚠️ These targets are **demonstrative**, not a production guarantee
>
> VidCast runs on a **single-node EKS cluster that is deliberately torn down
> between sessions** to save cost (see the project memory / `MANAGED_SERVICES.md`).
> Every teardown is, by definition, 100% unavailability — so the **availability
> budget is exhausted the moment the cluster goes down**. Do **not** read these
> numbers as a claim that VidCast delivers 99.9% uptime.
>
> **The portfolio artifact is the machinery** — the multi-window multi-burn-rate
> PrometheusRules, the normalised burn-rate recording rules, and the error-budget
> Grafana dashboard — *not* the headline percentages. The same machinery, pointed
> at a real always-on deployment, would enforce real SLOs unchanged.

---

## The three SLOs

| # | SLO | Target | Window | SLI (how it's measured) |
|---|-----|--------|--------|--------------------------|
| 1 | **Availability** | 99.9% of gateway requests are non-5xx | 30 days | `vidcast_gateway_requests_total` — 1 − (5xx ÷ total) |
| 2 | **Conversion latency** | 95% of conversions finish ≤ 5 min | 30 days | `vidcast_conversion_duration_seconds` — fraction in the `le="300"` bucket |
| 3 | **End-to-end success** | 99% of uploads produce a notification email | 30 days | `vidcast_notifications_total{status="success"}` ÷ `vidcast_uploads_total` |

All three SLIs come from the **M-2 metrics foundation** built in this sprint
(gateway `/metrics`, converter & notification `start_http_server`, RabbitMQ's
`rabbitmq_prometheus` plugin). Scrape wiring: `monitoring/scrape/`.

---

## Error budgets and burn-rate thresholds

"Burn rate" = how fast you're spending the budget, **normalised** so **1× is the
exact rate that just exhausts the budget over the SLO window** and **14× is 14×
too fast**. The recording rules in `monitoring/alerts/vidcast-slo-rules.yaml`
store burn rates already normalised, so the alert thresholds are literally `> 14`
and `> 1`.

### 1. Availability — 99.9% / 30 days
- **Budget factor (1 − SLO):** 0.001
- **Error budget (time):** 0.1% × 30 d = **43.2 minutes** of allowed 5xx per 30 days
- **Fast-burn (page / critical):** 1h **and** 5m burn rate **> 14×** → at 14× the
  43.2-min budget is gone in ~3 h. `for: 2m`.
- **Slow-burn (ticket / warning):** 6h **and** 30m burn rate **> 1×**. `for: 15m`.

### 2. Conversion latency — 95% ≤ 5 min / 30 days
- **Budget factor:** 0.05 (5% of conversions may exceed 5 min)
- **Error budget:** 5% of all conversions in the 30-day window may be slow
- **Fast-burn (critical):** 1h **and** 5m burn rate **> 14×** (i.e. >70% of recent
  conversions slower than 5 min). `for: 2m`.
- **Slow-burn (warning):** 6h **and** 30m burn rate **> 1×** (>5% slow). `for: 15m`.

### 3. End-to-end success — 99% / 30 days
- **Budget factor:** 0.01
- **Error budget (time-equivalent):** 1% × 30 d = **432 minutes (7.2 h)** of total
  pipeline failure per 30 days; equivalently 1% of uploads may go un-notified
- **Fast-burn (critical):** 1h **and** 5m burn rate **> 14×**. `for: 5m`.
- **Slow-burn (warning):** 6h **and** 30m burn rate **> 1×**. `for: 30m`.

Why **multi-window** (long **and** short): the long window (1h/6h) decides
severity; the short window (5m/30m) must *also* be burning, which makes the alert
**clear quickly** once the incident is over instead of latching on for an hour.
(Google SRE workbook, "Alerting on SLOs".)

---

## Runbooks (alert → first action)

### §Availability
`VidcastAvailabilityFastBurn` / `…SlowBurn` — gateway 5xx rate over budget.
1. `kubectl logs deploy/gateway` — look for tracebacks / dependency errors.
2. Check `/healthz`: is MongoDB or RabbitMQ the failing dependency?
3. Check the `PodCrashLoopBackOff` alert and gateway pod restarts.

### §Conversion-latency
`VidcastConversionLatency…` — conversions taking too long.
1. Is the `video` queue backed up? (`RabbitMQQueueBacklog` alert / RabbitMQ UI :30004.)
2. Is KEDA scaling the converter? `kubectl get scaledobject,deploy converter`.
   Remember the single-node cap: **`maxReplicaCount: 2`** — at saturation the 2nd
   replica may be `Pending` (see the node-budget story), which *is* a latency cause.
3. Converter CPU throttling / OOM? `kubectl top pod -l app=converter`.

### §End-to-end-success
`VidcastE2ESuccess…` — uploads not turning into emails.
1. Inspect the dead-letter queues (`video.dlq`, `mp3.dlq`) — see `DLQ_TOPOLOGY_EXPLAINED.md`.
2. `kubectl logs deploy/notification` — SMTP/Gmail failures? (If `GMAIL_APP_PASSWORD`
   is `SKIP`, sends fail by design and this SLO is not meaningful — disable the alert.)
3. Is the outbox-relay publishing? `kubectl logs deploy/outbox-relay`.

---

## Honest measurement caveats

1. **30-day budgets vs 7-day retention.** Prometheus retention is **7 days**
   (`monitoring/values.yaml`). The *alerts* only use ≤6h windows, so they are
   unaffected. But the dashboard's **"budget remaining"** and **"time to
   exhaustion"** panels are computed over the **7-day** window and labelled as
   such — a true 30-day accounting needs longer retention (Thanos / remote-write),
   which is out of scope.
2. **End-to-end SLI is time-shifted.** Uploads and their emails are minutes apart,
   so over short windows `sends ÷ uploads` is noisy and can momentarily exceed 1.
   It is only meaningful over **long windows (≥6h)** where the shift washes out —
   which is exactly why only the 6h/30m slow-burn pair is trustworthy for this SLO.
3. **Conversion latency only counts completed jobs.** Jobs that dead-letter never
   enter the histogram — they are an *end-to-end-success* failure (SLO 3), not a
   latency failure. This is intentional and standard.
4. **No-traffic = no signal.** When idle, the ratios divide by a zero rate → NaN →
   alerts stay quiet. Correct for a demo cluster that is often idle.

---

## Where everything lives

| Artifact | Path |
|----------|------|
| Recording rules + burn-rate alerts | `monitoring/alerts/vidcast-slo-rules.yaml` |
| Error-budget Grafana dashboard | `monitoring/dashboards/vidcast-slo.json` |
| Scrape config (ServiceMonitor/PodMonitor) | `monitoring/scrape/` |
| Gateway metrics | `src/gateway-service/metrics.py`, `server.py` |
| Converter / notification metrics | `src/{converter,notification}-service/consumer.py` |
| Concept companion (gitignored) | `SLO_EXPLAINED.md` |
