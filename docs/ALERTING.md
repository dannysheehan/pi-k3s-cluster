# Alerting

The monitoring baseline uses VictoriaMetrics, vmagent, vmalert, Alertmanager,
ntfy, and healthchecks.io. Versions and vaulted notification values are in
`group_vars/all.yml`. vmagent and vmalert use `vmsingle-stable`.

Host health rules consume the node-exporter textfile metrics produced by
`pi-health-metrics.timer`: Raspberry Pi temperature warns above 75°C and is
critical above 80°C, root SSD SMART failure is critical, and a failed metrics
collection is warning-level. The collector uses `smartctl -d scsi` by default.

Fluent Bit must rename `log` to `_msg` before VictoriaLogs ingestion. Grafana
credentials are provided through the vaulted `grafana-admin` Secret; no default
Grafana password is documented.

```bash
export KUBECONFIG=~/.kube/config-rpi
kubectl get endpoints -n monitoring vmsingle-stable
kubectl get pods -n monitoring
./scripts/verify-cluster.sh
```

The healthchecks heartbeat detects broad cluster loss. The Alertmanager
watchdog detects failure in the alerting pipeline. Investigate vmalert,
Alertmanager, and ntfy delivery in that order.
