# Incident Report: Grafana Metric Dashboards Empty

Date: 2026-06-04  
Status: Resolved  
Severity: Medium  
Affected services: Grafana metric dashboards, VictoriaMetrics, VMAgent

## Summary

Grafana loaded successfully at `/grafana`, but metric dashboards were failing or
empty because the VictoriaMetrics backend was unavailable. The `vmsingle`
StatefulSet was in `CrashLoopBackOff` after VictoriaMetrics failed to parse a
corrupted storage metadata file:

```text
/storage/data/small/2026_05/parts.json
```

After VictoriaMetrics was repaired, VMAgent was still replaying a large
remote-write backlog before current samples. Restarting VMAgent discarded the
stale backlog and restored live dashboard data.

## Impact

- Grafana metric panels returned query errors or no data.
- VictoriaMetrics had no ready Service endpoints while `vmsingle` was
  crashlooping.
- VMAgent accumulated nearly 2 GiB of pending remote-write queue data.
- Live dashboard recovery was delayed until the VMAgent queue was cleared.
- Log dashboards backed by VictoriaLogs were not identified as part of this
  incident.

## Detection

The issue was reported as "grafana dashboard not working".

Initial checks showed:

```text
pod/grafana-797f79645-6mrbd                    3/3 Running
pod/vmsingle-victoria-metrics-single-server-0  0/1 CrashLoopBackOff
```

VictoriaMetrics logs showed:

```text
FATAL: cannot parse "/storage/data/small/2026_05/parts.json":
invalid character '\x00' looking for beginning of value
```

## Root Cause

VictoriaMetrics could not start because a persisted `parts.json` file in the
May 2026 small partition contained NUL bytes instead of valid JSON. This
prevented the storage engine from opening and left the metrics backend
unavailable to both Grafana queries and VMAgent remote writes.

The exact source of the file corruption was not proven during recovery. Plausible
contributors include storage interruption, node instability, filesystem-level
corruption, or an unclean write path on the Longhorn-backed VictoriaMetrics PVC.

## Contributing Factors

- `vmsingle` is deployed as a single instance, so one corrupted local storage
  partition takes the metrics backend offline.
- The remote-write target is the `vmsingle` headless Service. During backend
  unavailability, VMAgent had repeated DNS/write failures and accumulated a
  large persistent queue.
- VMAgent replayed old queued samples after VictoriaMetrics recovered. Current
  Grafana panels still appeared empty until VMAgent was restarted.
- Node `k3s-wrk-04-11c34487` was `NotReady`, which continued to generate scrape
  failures for that node after the primary incident was resolved.

## Recovery Actions

1. Confirmed Grafana itself was running and exposed through Traefik.
2. Identified `vmsingle-victoria-metrics-single-server-0` as the failed metrics
   backend.
3. Scaled the VictoriaMetrics StatefulSet to zero replicas.
4. Mounted the VictoriaMetrics PVC in a temporary repair pod.
5. Quarantined the corrupted partition directory:

   ```text
   /storage/quarantine/2026_05.small.corrupt-parts-json.20260604011414
   ```

6. Deleted the temporary repair pod.
7. Scaled VictoriaMetrics back to one replica.
8. Verified VictoriaMetrics opened storage successfully and restored a ready
   endpoint.
9. Restarted VMAgent to discard the stale 2 GiB queue and resume current
   samples.
10. Verified live metric queries returned data again, including `up` and
    `cilium_process_cpu_seconds_total`.

## Verification

Post-recovery checks showed:

```text
vmsingle-victoria-metrics-single-server-0  1/1 Running
vmagent-victoria-metrics-agent             1/1 Running
vmagent remote-write pending queue         0 bytes
```

VictoriaMetrics returned live PromQL results for:

```text
up
cilium_process_cpu_seconds_total
```

Grafana route check:

```text
HTTP/1.1 302 Found
Location: /grafana/login
```

## Prevention Recommendations

### 1. Add a VictoriaMetrics Storage-Corruption Runbook

Add an explicit runbook section for the observed failure signature:

```text
FATAL: cannot parse "/storage/data/.../parts.json"
invalid character '\x00' looking for beginning of value
```

The runbook should document the reversible quarantine workflow used here:

1. Scale `vmsingle` to zero.
2. Mount the PVC in a temporary repair pod.
3. Move the affected partition under `/storage/quarantine/`.
4. Start `vmsingle`.
5. Restart VMAgent if stale queue replay delays live dashboards.

This reduces recovery time if the same failure reappears.

### 2. Alert On `vmsingle` CrashLooping And Missing Endpoints

Add alerts or verification checks for:

- `vmsingle` pod not ready.
- `vmsingle` restart count increasing.
- `vmsingle-victoria-metrics-single-server` Service having no ready endpoints.
- Grafana datasource query failures against VictoriaMetrics.

These symptoms should page or visibly fail `./scripts/verify-cluster.sh` before
Grafana is manually checked.

### 3. Alert On VMAgent Queue Growth

Track these VMAgent metrics:

```text
vmagent_remotewrite_pending_data_bytes
vm_persistentqueue_bytes_pending
vmagent_remotewrite_retries_count_total
vmagent_remotewrite_requests_total
```

Recommended thresholds:

- Warning if pending queue exceeds 256 MiB for more than 10 minutes.
- Critical if pending queue exceeds 1 GiB or continues growing for 30 minutes.
- Critical if remote-write retries are increasing while successful `2XX`
  requests are absent.

### 4. Prefer Fast Live Recovery Over Replaying Stale Metrics

For this small cluster, live dashboard recovery is usually more valuable than
preserving hours of queued monitoring samples. If VictoriaMetrics has been down
long enough for VMAgent to build a large queue, the documented recovery step
should be:

```bash
kubectl rollout restart deploy/vmagent-victoria-metrics-agent -n monitoring
```

Do this only after VictoriaMetrics is healthy. This discards stale queued
samples and resumes current scraping quickly.

### 5. Revisit The Stable Service Recommendation For `vmsingle`

Review and consider implementing `docs/RECOMMENDATION-VMSINGLE-CLUSTERIP.md`.
A stable ClusterIP Service for VictoriaMetrics would reduce DNS-level disruption
for VMAgent and Grafana during pod replacement or endpoint churn.

This would not prevent on-disk corruption, but it should make normal restarts
and reschedules less likely to cascade into remote-write queue buildup.

### 6. Watch Node Health As A Monitoring Dependency

The cluster still had `k3s-wrk-04-11c34487` in `NotReady` after recovery. Node
health should be treated as part of monitoring health because failed nodes
produce scrape errors and partially empty dashboard panels.

Recommended checks:

- Include node readiness in monitoring verification output.
- Alert when any node is `NotReady` for more than 10 minutes.
- Investigate repeated node-exporter, kubelet, Cilium, and Hubble scrape errors
  tied to the same node.

### 7. Validate Longhorn Volume And Node Storage Health

Because the corruption occurred on a Longhorn-backed PVC, follow up with storage
checks:

```bash
./scripts/check-ssd-health.sh
./scripts/analyze-longhorn-replicas.sh
```

Also inspect the Longhorn UI for the VictoriaMetrics volume replica health,
recent rebuilds, and node disk warnings.

## Follow-Up Tasks

- [x] Add VictoriaMetrics `parts.json` corruption recovery to
      `docs/RUNBOOKS.md`.
- [x] Extend `scripts/verify-cluster.sh` to fail when `vmsingle` has no ready
      endpoints.
- [x] Add VMAgent queue checks to `scripts/verify-cluster.sh`.
- [ ] Decide whether to implement the ClusterIP recommendation for
      VictoriaMetrics.
- [ ] Investigate and recover `k3s-wrk-04-11c34487`.
- [ ] Run SSD and Longhorn replica health checks after the incident.
- [ ] Decide how long to retain quarantined VictoriaMetrics data before deleting
      `/storage/quarantine/2026_05.small.corrupt-parts-json.20260604011414`.

## Related Documentation

- `docs/RUNBOOKS.md`
- `docs/TROUBLESHOOTING.md`
- `docs/OPERATIONS.md`
- `docs/RECOMMENDATION-VMSINGLE-CLUSTERIP.md`
