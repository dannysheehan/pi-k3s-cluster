# Scripts

Scripts use `~/.kube/config-rpi` unless overridden by `KUBECONFIG`.

## `verify-cluster.sh`

Runs non-destructive baseline verification, including stable `vmsingle-stable`
VictoriaMetrics service health and five-node Raspberry Pi temperature/SMART
collector coverage.

```bash
export KUBECONFIG=~/.kube/config-rpi
./scripts/verify-cluster.sh
```

## `analyze-node-pressure.sh`

Summarizes a named node resource usage, placed pods, and events.

```bash
./scripts/analyze-node-pressure.sh pi-wrk-02
```

## `analyze-longhorn-replicas.sh`

Shows replica placement. The baseline expects two replicas and storage nodes
`pi-ctl-03`, `pi-wrk-01`, and `pi-wrk-02`.

```bash
./scripts/analyze-longhorn-replicas.sh
```

## `check-ssd-health.sh`

Performs USB SSD root-device health triage over SSH: root filesystem, block
devices, kernel USB/disk errors, SMART data when available, and K3s journal.
It does not expect a separate SSD mount.

```bash
./scripts/check-ssd-health.sh 192.168.1.45
./scripts/check-ssd-health.sh pi-wrk-02 /dev/sda scsi
```
