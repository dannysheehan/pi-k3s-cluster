# Helper Scripts

These scripts are lightweight operator helpers for common checks and should stay
safe to run repeatedly.

## `verify-cluster.sh`

Runs a quick day-2 verification pass against the cluster using
`~/.kube/config-rpi` by default.

Usage:

```bash
chmod +x scripts/verify-cluster.sh
./scripts/verify-cluster.sh
```

To use a different kubeconfig:

```bash
KUBECONFIG=/path/to/config ./scripts/verify-cluster.sh
```

## `analyze-probe-pressure.sh`

Summarizes recent warning events, non-ready pods, and restart-heavy pods so you
can tune probe budgets from observed failures instead of guesswork.

Usage:

```bash
chmod +x scripts/analyze-probe-pressure.sh
./scripts/analyze-probe-pressure.sh
```

To inspect a larger or smaller event window:

```bash
EVENT_LIMIT=500 ./scripts/analyze-probe-pressure.sh
```

## `analyze-node-pressure.sh`

Focuses on a single node: shows node-level `kubectl top`, pods placed on the
node, top pods on that node, recent node-scoped events, and Longhorn volumes
attached there.

Usage:

```bash
chmod +x scripts/analyze-node-pressure.sh
./scripts/analyze-node-pressure.sh k3s-wrk-03-f118e128
```

To widen the recent event window:

```bash
EVENT_LIMIT=200 ./scripts/analyze-node-pressure.sh k3s-wrk-03-f118e128
```

## `analyze-longhorn-replicas.sh`

Shows Longhorn volume ownership, per-node replica counts, scheduled replica
bytes, and replica placement by volume so skew is easy to spot.

This is especially useful on Pi clusters, where the problem is often not "all
replicas are on one node" but "one node owns too many attached volumes and too
many future rebuild bytes".

Usage:

```bash
chmod +x scripts/analyze-longhorn-replicas.sh
./scripts/analyze-longhorn-replicas.sh
```

## `check-ssd-health.sh`

Runs a host-level SSD triage pass over SSH: mounted source for `/mnt/ssd`,
`lsblk`, `blkid`, recent kernel USB/disk errors, SMART output when available,
and the recent `k3s-agent` journal.

Usage:

```bash
chmod +x scripts/check-ssd-health.sh
./scripts/check-ssd-health.sh 192.168.1.45
```

If auto-detection cannot resolve the block device cleanly, pass it explicitly:

```bash
./scripts/check-ssd-health.sh 192.168.1.45 /dev/sdb
```
