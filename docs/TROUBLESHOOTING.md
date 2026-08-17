# Troubleshooting

Use the configured kubeconfig:

```bash
export KUBECONFIG=~/.kube/config-rpi
kubectl get nodes -o wide
kubectl get pods -A
./scripts/verify-cluster.sh
```

## API or node failures

Confirm the API VIP is `192.168.1.40` and servers are `pi-ctl-01`–`03`. Check
the affected host's `k3s` service (or `k3s-agent` on agents). K3s data is under
`/var/lib/rancher/k3s`. Do not repair a live cluster by rerunning the bootstrap
playbook.

## USB SSD dropouts

Ping OK with SSH hanging is the USB-SSD dropout signature: the cheap
`0930:1400` bridge left the bus and `/` is wedged on I/O. Only a physical
power cycle recovers it. After recovery, confirm `Driver=usb-storage` and
`UAS is ignored for this device` in dmesg. If those are missing, drain the
node and rerun:

```bash
uv run ansible-playbook k3s-tune-usb-ssd.yml --limit <node> -e usb_ssd_reboot=true
```

Do not edit `/boot/firmware/cmdline.txt` for this; Ubuntu tryboot reads
`/boot/firmware/current/cmdline.txt`. See
`docs/INCIDENT-2026-08-18-CTL03-SSD-DISCONNECT.md`.

## Networking and Longhorn

If pods fail secondary-network setup, first verify `br-storage`, then Multus
and Whereabouts, then the `storage-network` NAD. It must remain bridge CNI.

If new pods stay in `ContainerCreating` with
`validateIfName: no net namespace /var/run/netns/cni-... Statfs`, the Multus
thick daemon cannot see the path containerd reports. The reviewed DaemonSet
patch must mount host netns at both `/run/netns` and `/var/run/netns`. Confirm
every node has `/etc/cni/net.d/00-multus.conf`; without it, pods skip Multus
and Longhorn never gets the storage-network NIC. If the error is
`failed to find plugin "bridge" in path [/opt/cni/bin]`, copy
`/var/lib/rancher/k3s/data/cni/bridge` into `/opt/cni/bin/bridge` (a host
symlink does not resolve inside the Multus container).

For Longhorn failures, check that `/var/lib/longhorn` is present and that only
`pi-ctl-03`, `pi-wrk-01`, and `pi-wrk-02` are eligible storage nodes. Volumes
expect two replicas. Inspect the Longhorn manager and CSI pods after confirming
the storage bridge and storage-network attachment.

## Monitoring

For absent metrics, inspect exporter targets, vmagent logs, and the stable
`vmsingle-stable` endpoints before Grafana queries. For absent logs, inspect
Fluent Bit and VictoriaLogs ingestion; `_msg` is the required message field.
Grafana's password is in the vaulted `grafana-admin` Secret, not a default
credential.

## Deferred NFS

Synology DS923+ NFS CSI is intentionally absent from the baseline. Do not
diagnose it as a failed default storage provider; its future non-default RWX
class and connection inputs are TBD.
