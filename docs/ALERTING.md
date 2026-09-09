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

## Smoke testing

The default smoke test is read-only. It verifies Alertmanager configuration,
webhook counters, the always-firing Watchdog, and the latest scheduled cluster
heartbeat:

```bash
./scripts/test-alerting.sh
```

The live mode sends clearly named temporary warning and critical notifications
to the configured ntfy topic, resolves them, signals a controlled external
heartbeat failure and recovery, and runs a disposable heartbeat Job from
inside the cluster:

```bash
./scripts/test-alerting.sh --live
```

Live mode intentionally produces external notifications. It extracts the
vaulted endpoints only from live workload configuration, never prints them,
and uses an exit trap to resolve alerts and restore the heartbeat after a
failure. Confirm the expected ntfy and healthchecks.io notifications with the
operator. Do not run live mode during an unrelated incident.
