# Alerting

Deployed 2026-07-05 (best-practices review, finding A2 — after the wrk-01 SSD
failure went unnoticed for 4.5 days). Alerts push to the ntfy app on your
phone.

## How It Fits Together

```text
vmagent ──scrapes──> vmsingle (VictoriaMetrics TSDB)
                        ▲
                        │ queries (PromQL, every 30s)
                     vmalert ──firing alerts──> Alertmanager ──webhook──> ntfy.sh/<topic> ──> phone
```

All components live in the `monitoring` namespace, deployed by
`04-monitoring.yml`:

| Component | Workload | Purpose |
|---|---|---|
| vmalert | `deploy/vmalert-victoria-metrics-alert-server` | Evaluates alert rules against vmsingle |
| Alertmanager | `deploy/vmalert-victoria-metrics-alert-alertmanager` | Grouping, repeat throttling, delivery to ntfy |
| kube-state-metrics | `deploy/kube-state-metrics` | Supplies `kube_node_status_condition` etc. for node rules |

Alertmanager is deliberately **not** persisted to Longhorn: the alerting path
must not depend on the storage it alerts about. Silences are lost if the pod
restarts — acceptable trade.

## ntfy Delivery

- Server/topic: `ntfy_server` + `ntfy_topic` in `group_vars/all.yml`. The
  topic is a shared secret and is **ansible-vault encrypted** — see
  "Secrets Management" in [MAINTENANCE.md](MAINTENANCE.md).
- Subscribe on your phone: ntfy app → subscribe to the topic.
- Formatting: Alertmanager posts its webhook JSON directly to ntfy; ntfy
  renders it via URL-encoded Go templates in the webhook URL (no bridge
  component). Decoded templates are documented as comments next to the URL in
  `04-monitoring.yml`.
- Firing = 🔥 title, resolved = ✅. `severity=critical` is delivered at ntfy
  **urgent** priority (bypasses phone quiet hours); warnings at default.
- Repeat intervals: critical every 6h, warning every 24h, until resolved.

## Current Rules (12)

Defined in `04-monitoring.yml` under the vmalert helm values
(`server.config.alerts.groups`):

| Group | Alert | Fires when | Severity |
|---|---|---|---|
| node-health | NodeNotReady | node NotReady 5m | critical |
| node-health | NodeScrapeTargetDown | node-exporter unreachable 5m | critical |
| node-health | FilesystemDeviceError | ext4 errors on / /mnt/ssd /var 2m (SSD drop signature) | critical |
| storage | LonghornVolumeDegraded | robustness=degraded 10m | warning |
| storage | LonghornVolumeFaulted | robustness=faulted 1m | critical |
| storage | PVCSpaceLow / PVCSpaceCritical | <15% free 15m / <5% free 5m | warning / critical |
| monitoring-pipeline | VMSingleDown / VMAgentDown | scrape target down 3m / 5m | critical / warning |
| monitoring-pipeline | VMAgentQueueHigh / Critical | remote-write queue >256MiB / >1GiB 10m | warning / critical |
| certificates | APIClientCertExpirySoon | API client certs <30d 1h | warning |

## Dead-Man's Switch (healthchecks.io)

In-cluster alerting cannot report its own death: if vmsingle/vmalert/
Alertmanager are down — or the whole cluster is — nothing fires. Covered
(2026-07-05) by two healthchecks.io checks that alert **from outside** when
pings stop:

| Check | Pinged by | Cadence | Alerts after | Silence means |
|---|---|---|---|---|
| `pi-cluster-heartbeat` | `cronjob/cluster-heartbeat` (monitoring ns) | 5m | ~10m (period 5m + grace 5m) | Cluster / scheduling down |
| `pi-cluster-alerting-watchdog` | Alertmanager `Watchdog` route (always-firing `vector(1)` rule) | ~10m | ~30m (period 15m + grace 15m) | Alerting pipeline broken (even if cluster is up) |

Config lives in `04-monitoring.yml` (rule group `meta`, the `healthchecks`
receiver/route, and the CronJob task). Ping URLs are vault-encrypted in
`group_vars/all.yml`; the healthchecks.io API key is at
`~/.ansible/healthchecks-api-key` (outside the repo). The Watchdog routes
*only* to healthchecks — it never reaches ntfy.

```bash
# Check both statuses from the CLI
KEY=$(tr -d '[:space:]' < ~/.ansible/healthchecks-api-key)
curl -s -H "X-Api-Key: $KEY" https://healthchecks.io/api/v3/checks/

# Fire a heartbeat immediately (instead of waiting for the 5m schedule)
kubectl -n monitoring create job hb-test --from=cronjob/cluster-heartbeat
```

Make sure healthchecks.io itself has a notification channel configured
(email/push) — the checks were created with all project channels assigned.

## Operations

```bash
# Redeploy after changing rules or receivers
ansible-playbook 04-monitoring.yml --tags vmalert

# See rule states (inactive / pending / firing)
kubectl -n monitoring exec deploy/vmagent-victoria-metrics-agent -- \
  wget -qO- http://vmalert-victoria-metrics-alert-server.monitoring.svc:8880/api/v1/rules

# End-to-end delivery test (synthetic alert -> should hit your phone in ~30s)
kubectl -n monitoring exec deploy/vmagent-victoria-metrics-agent -- \
  wget -qO- --header 'Content-Type: application/json' --post-data \
  '[{"labels":{"alertname":"AlertingPipelineTest","severity":"critical"},"annotations":{"summary":"Test"},"startsAt":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}]' \
  http://vmalert-victoria-metrics-alert-alertmanager.monitoring.svc:9093/api/v2/alerts

# Silence an alert (UI): port-forward Alertmanager, then browse
kubectl -n monitoring port-forward svc/vmalert-victoria-metrics-alert-alertmanager 9093:9093
# -> http://localhost:9093  (silences do not survive pod restarts)

# vmalert UI (rule evaluation, last errors)
kubectl -n monitoring port-forward svc/vmalert-victoria-metrics-alert-server 8880:8880
# -> http://localhost:8880

# Check recent ntfy messages without a phone
curl -s "https://ntfy.sh/<topic>/json?poll=1&since=1h"
```

## Adding a Rule

1. Edit `04-monitoring.yml` → vmalert task → `server.config.alerts.groups`.
2. Prometheus template variables in annotations (`{{ $labels.x }}`,
   `{{ $value }}`) must be tagged `!unsafe` so Ansible's Jinja leaves them
   alone — copy an existing rule.
3. Verify the metric exists first (query vmsingle as in the test above);
   a rule on a nonexistent metric never fires and never errors.
4. `ansible-playbook 04-monitoring.yml --tags vmalert`, then check
   `/api/v1/rules` shows the new rule.

## Version Pins

`group_vars/all.yml`: `vmalert_chart_version` (vm/victoria-metrics-alert),
`kube_state_metrics_chart_version` (prometheus-community/kube-state-metrics).
