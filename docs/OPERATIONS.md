# Operations

## Baseline

The clean-slate baseline is three schedulable servers (`pi-ctl-01`–`03`) and
two agents (`pi-wrk-01`–`02`). kube-vip exposes the API at `192.168.1.40`; the
node addresses are `.41`–`.45`. Nodes run Ubuntu 26.04 ARM64 directly from USB
SSD root. K3s uses `/var/lib/rancher/k3s`.

Component versions are frozen in `group_vars/all.yml`. Use the matching tagged
playbook for an intentional component rerun. Never rerun `02-k3s-install.yml`
on a live cluster.

```bash
export KUBECONFIG=~/.kube/config-rpi
uv run ansible-playbook 03-addons.yml --tags cilium
uv run ansible-playbook 03-addons.yml --tags longhorn
uv run ansible-playbook 04-monitoring.yml --tags vmsingle
uv run ansible-playbook 05-secrets.yml --tags external-secrets
./scripts/verify-cluster.sh
```

## Dependencies

`br-storage` precedes Multus; Multus and Whereabouts precede Longhorn; Cilium
must be healthy for general networking and the Traefik load-balancer address;
Longhorn precedes storage-backed monitoring. The `storage-network` NAD is bridge
CNI by design. Do not replace it with ipvlan.

Longhorn has two replicas and uses `/var/lib/longhorn` only on `pi-ctl-03`,
`pi-wrk-01`, and `pi-wrk-02`. Verify those placement constraints before adding
or draining a node.

## Membership

Use `--limit` and add only one server at a time:

```bash
uv run ansible-playbook k3s-add-master.yml --limit pi-ctl-03 --forks=1
uv run ansible-playbook k3s-add-worker.yml --limit pi-wrk-02
uv run ansible-playbook k3s-remove-worker.yml --limit pi-wrk-02 -e wipe_data=true
uv run ansible-playbook k3s-tune-usb-ssd.yml --limit pi-ctl-03
```

Drain a live node before `k3s-tune-usb-ssd.yml -e usb_ssd_reboot=true`. The
UAS quirk binds only after reboot. Apply one node at a time; on Longhorn
storage nodes wait for volumes to return `attached/healthy` before the next.

## Observability

Grafana obtains its credentials from the vaulted `grafana-admin` Secret. Do not
use default credentials. vmagent and vmalert use `vmsingle-stable`, the stable
ClusterIP fronting VictoriaMetrics. For empty dashboards, trace exporter →
vmagent → `vmsingle-stable` → Grafana; for logs trace Fluent Bit →
VictoriaLogs (its message field is `_msg`) → Grafana datasource.

## Deferred storage and Git

Synology DS923+ NFS CSI is not part of the baseline. Post-baseline it will be
a non-default RWX StorageClass alongside the default Longhorn class; its inputs
are TBD. The canonical Git remote is required to be off-cluster and remains
TBD.
