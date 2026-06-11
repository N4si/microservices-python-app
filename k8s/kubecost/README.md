# k8s/kubecost — FinOps cost visibility (B3)

Kubecost (OSS / OpenCost core, **no license key**) for per-namespace / per-service /
per-conversion cost. Installed **last** in the upgrade plan because it is the
heaviest add-on and the most likely to pressure the single 2-vCPU node.

## The one tuning that matters

By default Kubecost deploys its **own** Prometheus + node-exporter +
kube-state-metrics (~1 CPU) — a duplicate of the kube-prometheus-stack from B4.
`values.yaml` **disables all of that** and points Kubecost at the existing
Prometheus, reducing it to a single ~175m cost-analyzer pod. Without this it does
not fit the node.

## Install (applied separately, like KEDA/ESO/Kyverno/Argo)

```bash
helm repo add kubecost https://kubecost.github.io/cost-analyzer/ && helm repo update
helm install kubecost kubecost/cost-analyzer -n kubecost --create-namespace \
  -f k8s/kubecost/values.yaml
kubectl apply -f monitoring/scrape/kubecost-servicemonitor.yaml   # Prometheus scrapes cost metrics
```

## ⚠️ Node-budget gate (do NOT skip)

Even tuned to ~175m, Kubecost pushes the **prod** footprint over the 90% idle gate
(see the B3 review note). Run it **against the dev (1-replica) footprint** (~81%
idle), **or** scale it to zero between cost-analysis sessions:

```bash
kubectl scale deploy/kubecost-cost-analyzer -n kubecost --replicas=0   # park it
kubectl scale deploy/kubecost-cost-analyzer -n kubecost --replicas=1   # bring it back; Prometheus 7d backfills
```

## Verify (live cluster)

```bash
kubectl get pods -n kubecost                       # cost-analyzer Running
# cost metrics present in Prometheus (Status ▸ Targets shows vidcast-kubecost UP):
#   node_total_hourly_cost, container_cpu_allocation, ...
kubectl port-forward -n kubecost deploy/kubecost-cost-analyzer 9090:9090  # optional Kubecost UI
```

Then load `monitoring/dashboards/vidcast-finops.json` in Grafana.

## Accuracy

Kubecost **estimates** from instance list pricing; **AWS Cost Explorer is ground
truth**. m7i-flex.large ≈ **$0.106/hr** (eu-west-2 on-demand — verify current
pricing). Reconcile the dashboard's monthly projection against the real bill; they
will differ (Kubecost doesn't see RIs/Savings Plans, data-transfer, or control-plane
charges unless configured). See `FINOPS_EXPLAINED.md`.
