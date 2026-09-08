# Failure-Test Record

This record covers the clean-slate baseline tests run on 2026-09-08. Each test
started from a passing `scripts/verify-cluster.sh` result, and disruptive tests
were serialized. Node times are approximate because readiness was sampled at
five-second intervals.

## Results

| Test | Result | Observation |
|---|---|---|
| Stop K3s on `pi-ctl-01` | Known limitation | Direct APIs on `pi-ctl-02` and `pi-ctl-03` remained healthy, but the API VIP was unavailable for all nine samples over about 45 seconds. The surviving kube-vip container retained the VIP while local port 6443 was down. K3s was restarted immediately and the cluster recovered. |
| Reboot `pi-ctl-01` | Pass | kube-vip moved to `pi-ctl-03`; API interruption was approximately 5-10 seconds. The node and all node-local pods rejoined. |
| Reboot `pi-ctl-02` | Pass | `pi-ctl-03` already held the VIP, so the API remained available. Grafana rescheduled to `pi-wrk-02`; its Longhorn RWO volume reattached after the expected brief multi-attach transition. |
| Reboot `pi-ctl-03` | Pass | kube-vip moved to `pi-ctl-01`; API interruption was approximately 10-15 seconds. The VictoriaMetrics volume and both replicas recovered. vmagent buffered about 52 MB while VictoriaMetrics was unavailable, dropped no packets, and later drained to zero. |
| Move disposable Longhorn PVC | Pass | A 1 GiB, two-replica `longhorn-rpi` PVC was written on `pi-wrk-01`, detached, mounted on `pi-wrk-02`, read successfully, and written again. Replicas were on distinct eligible storage nodes. |
| Reboot storage node `pi-wrk-01` | Pass | The disposable PVC was attached to `pi-wrk-02` with replicas on `pi-ctl-03` and `pi-wrk-01`. While `pi-wrk-01` was unavailable, the volume remained attached and writable in `degraded` state. The probe produced 351 timestamp samples across the degraded and recovery intervals with no observed write failure. The node returned Ready about 5.5 minutes after the reboot request. Longhorn serialized replica rebuilds and all volumes were healthy about 13.7 minutes after the request. |

The disposable namespace and PVC were deleted after validation. No application
data was used as test data.

## kube-vip service-stop caveat

`systemctl stop k3s` is not a faithful physical-node failure test in this
configuration. The kube-vip static pod can continue under the existing
containerd process, renew its leader lease through the Kubernetes service, and
advertise the VIP even though the stopped node no longer listens on port 6443.
That creates a VIP blackhole while etcd quorum and the peer API servers remain
healthy.

Use a reboot or real power/network loss for the HA acceptance test. Do not
repeat the K3s-service-only test on other servers unless kube-vip lifecycle or
local API health fencing is deliberately changed and reviewed.

## Storage recovery details

Longhorn's one-concurrent-rebuild-per-node setting behaved as intended after
the `pi-wrk-01` reboot. The 10 GiB VictoriaMetrics replica rebuilt first,
followed by smaller application volumes and the disposable 1 GiB volume. The
test PVC remained readable and writable from its surviving replica throughout
the degraded interval.

vmagent rescheduled to `pi-wrk-02` and buffered monitoring samples during
storage recovery. Its live self-metric
`vmagent_remotewrite_packets_dropped_total` remained zero. The live pod's
`vmagent_remotewrite_pending_data_bytes` metric was used for acceptance rather
than relying on a query of previously ingested queue metrics.

The test also saturated both VMSingle insert workers and reached roughly
529 MB resident memory with the original 500m CPU and 512 MiB memory limits.
The declared allocation was raised to 1 CPU and 1 GiB (requests 250m/512 MiB).
With vmalert briefly paused, the post-rollout queue drained from approximately
92 MB to zero in about two minutes without dropped packets. vmalert was then
restored to one replica and the complete cluster verifier passed with a live
queue depth of zero.

## Remaining acceptance work

- Exercise the Traefik `192.168.1.200` failover from a real LAN client.
- Run the complete warning, critical, Watchdog, dead-man, ntfy, and external
  heartbeat alert test set during a controlled failure.
- Complete the seven-day soak and review restarts, warnings, SMART health, etcd
  latency, Cilium drops, USB errors, storage latency, and replica rebuilds.
- Keep an off-NAS mirror of the canonical Synology Forgejo repository and test
  recovery from it.
