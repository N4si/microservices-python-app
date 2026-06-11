# k8s/keda — Autoscaling (A7)

KEDA-driven scale-to-zero for the **converter** + a CPU HPA for the **gateway**.

## What's here

| File | Purpose |
|---|---|
| `values.yaml` | KEDA Helm install values (conservative resources for the 2-vCPU node) |
| `triggerauthentication.yaml` | `TriggerAuthentication` → reads the broker connection string from `keda-rabbitmq-secret` |
| `scaledobject-converter.yaml` | `ScaledObject` → scales **converter** 0→3 on `video` queue depth |
| `hpa-gateway.yaml` | `HorizontalPodAutoscaler` → scales **gateway** 1→3 on CPU 70% |
| `secret.yaml.example` | template for the gitignored `secret.yaml` (the `host` amqp URI) |

## Why two different autoscalers

- **Converter → KEDA (queue depth, scale-to-zero).** The converter is an async,
  CPU-heavy, bursty queue consumer that is idle most of the time. KEDA scales it on
  `video` queue length and to **zero** when there's no work — no idle CPU burn.
- **Gateway → HPA (CPU).** The gateway is the synchronous, user-facing request
  tier; it must always have ≥1 replica and scales on CPU load.

**They target different deployments**, so the two controllers never fight over the
same replica count (a classic KEDA+HPA footgun).

## Install order (CRDs first)

```bash
helm repo add kedacore https://kedacore.github.io/charts && helm repo update
helm install keda kedacore/keda -n keda --create-namespace -f k8s/keda/values.yaml

# broker connection string for KEDA (gitignored; from secret.yaml.example or ESO)
cp k8s/keda/secret.yaml.example k8s/keda/secret.yaml   # then edit, OR use ESO
kubectl apply -f k8s/keda/secret.yaml

kubectl apply -k k8s/keda
```

## Prerequisites

- **metrics-server** must be installed for the gateway CPU HPA (EKS doesn't bundle
  it). Without it the HPA reports `<unknown>` CPU and won't scale.
- The gateway has a CPU **request** (100m) — required for utilisation-% targeting.

## Verify

```bash
kubectl get scaledobject,hpa -n default
kubectl describe scaledobject converter-scaler        # READY/ACTIVE conditions
# scale-to-zero: with an empty video queue, converter replicas -> 0 after cooldown
kubectl get deploy converter -w
# scale-up: publish a burst to the video queue, watch replicas climb toward 3
```

> Note: once KEDA owns the converter, its replica count is managed by KEDA, not the
> overlay. The `replicas:` in the converter base manifest is only the pre-KEDA
> bootstrap value; re-applying the overlay may briefly reset it until KEDA
> reconciles. See `AUTOSCALING_EXPLAINED.md`.
