# VidCast Monitoring Stack

Prometheus + Grafana + Alertmanager deployed via kube-prometheus-stack.

## Install

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install monitoring prometheus-community/kube-prometheus-stack \
  -f monitoring/values.yaml \
  -n monitoring \
  --create-namespace
```

Wait for all pods to start:
```bash
kubectl get pods -n monitoring -w
```

## Access

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | http://NODE_IP:30007 | admin / vidcast-demo |
| Alertmanager | http://NODE_IP:30008 | none |

Replace `NODE_IP` with the output of `kubectl get nodes -o wide`.

## Apply Custom Dashboard

The `dashboards/vidcast-operations.json` file is loaded automatically via the Grafana sidecar when the release is installed with the values in `values.yaml`. To load manually:

1. Open Grafana → Dashboards → Import
2. Upload `monitoring/dashboards/vidcast-operations.json`

## Apply Custom Alert Rules

```bash
kubectl apply -f monitoring/alerts/vidcast-alerts.yaml
```

## B4 — SLO scrape targets, burn-rate rules & error-budget dashboard

App metrics are scraped via operator-native ServiceMonitor/PodMonitor resources
(the old static `additionalScrapeConfigs` gateway job was retired):

```bash
kubectl apply -f monitoring/scrape/            # gateway + rabbitmq SM, converter + notification PM
kubectl apply -f monitoring/alerts/vidcast-slo-rules.yaml   # recording rules + multi-burn-rate alerts
```

These depend on the **M-2 metrics foundation**: the gateway `/metrics` endpoint,
the converter/notification metrics servers (`:9000/metrics`), and RabbitMQ's
`rabbitmq_prometheus` plugin (`:15692`, enabled in `Helm_charts/RabbitMQ`). All
need a fresh image build (gateway/converter/notification) and a RabbitMQ re-deploy.

- **SLO definitions, budgets, runbooks:** `SLO.md` (repo root)
- **Error-budget dashboard:** `dashboards/vidcast-slo.json` (load like the ops dashboard)

Verify scrape targets after applying: Prometheus UI → Status → Targets should show
`vidcast-gateway`, `vidcast-rabbitmq`, `vidcast-converter`, `vidcast-notification` **UP**.

## Uninstall

```bash
helm uninstall monitoring -n monitoring
kubectl delete namespace monitoring
```
