# Recommendation: Add A Stable `ClusterIP` Service For `vmsingle`

## Status

Proposed. Not yet implemented.

## Summary

Add a separate normal `ClusterIP` Service in front of the `vmsingle`
StatefulSet and use that service for:

- `vmagent` remote write
- Grafana metrics datasource
- ad hoc port-forwarding and troubleshooting commands where appropriate

Keep the existing chart-managed service behavior unless there is a strong
reason to replace it. This recommendation is to add a stable write/query
service, not to redesign the whole VictoriaMetrics deployment.

## Why This Is Being Considered

During the `k3s-wrk-02` node failure:

- `vmsingle-victoria-metrics-single-server-0` moved to a different node after
  Longhorn recovery.
- `vmagent` stopped writing metrics and VictoriaMetrics became empty from
  Grafana's perspective.
- `vmagent` logs showed repeated failures resolving the current write target:

```text
lookup vmsingle-victoria-metrics-single-server.monitoring.svc ... no such host
```

The monitoring stack recovered only after restarting `vmagent`.

That indicates the current service/DNS path was not resilient enough for this
failure mode in this cluster.

## Current Design

Today the repo points `vmagent` and Grafana at:

```text
http://vmsingle-victoria-metrics-single-server.monitoring.svc:8428
```

This has worked under normal conditions, but it was brittle during the
StatefulSet failover event above.

## Proposed Change

Create a dedicated Service such as:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: vmsingle-stable
  namespace: monitoring
spec:
  type: ClusterIP
  selector:
    app: server
    app.kubernetes.io/instance: vmsingle
    app.kubernetes.io/name: victoria-metrics-single
  ports:
    - name: http
      port: 8428
      targetPort: 8428
```

Then point:

- `vmagent.remoteWrite.url` to
  `http://vmsingle-stable.monitoring.svc:8428/api/v1/write`
- Grafana datasource URL to
  `http://vmsingle-stable.monitoring.svc:8428`

## Reasoning

### What This Improves

1. A normal `ClusterIP` service gives Kubernetes a stable virtual IP and
   service identity for reads and writes.
2. It decouples clients from pod identity more explicitly than writing to the
   StatefulSet service name.
3. It reduces the chance that a brief endpoint disappearance during failover
   turns into a DNS-level outage for `vmagent`.
4. It aligns better with the spirit of VictoriaMetrics documentation, which
   consistently shows `vmagent` remote-writing to a stable service URL.

### Why This Is Only A "Reasonable But More Opinionated" Change

This is not an explicit VictoriaMetrics requirement that was found in official
docs for `victoria-metrics-single`.

The official docs clearly support:

- writing to a stable URL
- relying on `vmagent` retry/on-disk queue behavior

But they do **not** explicitly say:

- "`victoria-metrics-single` should always have an extra `ClusterIP` service"
- "the chart's default service pattern is wrong"

So this recommendation is based on:

- the actual outage behavior observed in this cluster
- normal Kubernetes service-resilience reasoning
- the fact that `VMCluster` uses a stable `vminsert` service for writes in the
  clustered architecture

That makes this a pragmatic hardening measure, not a strict "VictoriaMetrics
best practice" claim.

## Benefits

- Better resilience for `vmagent` remote write during `vmsingle` reschedules
- Better resilience for Grafana queries during `vmsingle` reschedules
- Minimal operational change compared with migrating to `VMCluster`
- Easy to roll back if it proves unnecessary

## Costs And Tradeoffs

- Adds repo-specific behavior on top of the upstream chart
- Slightly more documentation and config to maintain
- May not fix every possible outage if the real issue is deeper than service
  discovery
- Could be redundant if the persistent `vmagent` queue change is already enough
  for acceptable recovery

## Why This Is Not The First Fix

The first change already made was:

- persist `vmagent`'s remote-write queue on a bounded `2Gi` PVC

That change is lower risk and more directly supported by VictoriaMetrics
guidance, because it improves `vmagent`'s ability to survive temporary remote
write failures without losing all in-flight samples.

The `ClusterIP` service recommendation comes after that because it is more of a
Kubernetes architecture preference informed by local failure behavior.

## Alternatives

### 1. Do Nothing

Pros:
- no extra config

Cons:
- same failure mode may recur
- continued reliance on `vmagent` restart as the manual recovery step

### 2. Keep `vmsingle`, But Rely Only On Persistent `vmagent` Queue

Pros:
- closest to VictoriaMetrics guidance
- simplest change

Cons:
- reduces data loss, but does not necessarily reduce recovery latency
- still depends on the current service path recovering cleanly

### 3. Migrate To `VMCluster`

Pros:
- architecturally stronger HA model
- stable `vminsert` write path is natural in that design
- better fit if downtime is unacceptable

Cons:
- significantly more components
- higher CPU/memory/storage overhead on Pi hardware
- more operational complexity

## When To Choose This Recommendation

This is a reasonable next step if:

- you want better recovery behavior than current `vmsingle`
- you do **not** want to move to `VMCluster` yet
- you are comfortable with a small amount of repo-specific service wiring

This is probably **not** the right next step if:

- you need genuine HA with minimal monitoring downtime
- you are already leaning toward a `VMCluster` migration

## Suggested Evaluation Criteria

If this is implemented later, evaluate it against these outcomes:

1. During a `vmsingle` pod reschedule, does `vmagent` resume remote write
   without a manual restart?
2. During a `vmsingle` pod reschedule, does Grafana recover automatically once
   the pod is ready?
3. Does the service continue to publish endpoints cleanly during failover?
4. Does this materially reduce operator intervention compared with the current
   setup?

## Implementation Sketch

If approved later, the change would likely include:

1. Add a `ClusterIP` service resource for `vmsingle` in `04-monitoring.yml`
2. Update `vmagent.remoteWrite.url`
3. Update the Grafana datasource URL
4. Update troubleshooting and runbook docs to reflect the new stable service
5. Verify with:

```bash
kubectl -n monitoring get svc,endpoints | grep vmsingle
kubectl -n monitoring logs -l app.kubernetes.io/instance=vmagent --tail=200
kubectl -n monitoring exec grafana-<pod> -- \
  wget -qO- http://vmsingle-stable.monitoring.svc:8428/api/v1/labels
```

## Recommendation

Keep this as a candidate hardening change.

It is a sensible improvement for the current `vmsingle` architecture, but it
should be evaluated as a pragmatic Kubernetes resilience measure, not as a
universally mandated VictoriaMetrics best practice.
