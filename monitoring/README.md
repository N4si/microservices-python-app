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

## Uninstall

```bash
helm uninstall monitoring -n monitoring
kubectl delete namespace monitoring
```
