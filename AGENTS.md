# Agent Guidance for pi-cluster

## Scope and source of truth

This repository deploys a clean-slate Raspberry Pi K3s baseline. It has no
migration path and assumes no data must be preserved. Versions are frozen in
`group_vars/all.yml`; update that file before rerunning a component.

The cluster has three schedulable K3s servers (`pi-ctl-01` through
`pi-ctl-03`) and two agents (`pi-wrk-01`, `pi-wrk-02`). The API virtual IP is
`192.168.1.40`; node IPs are `192.168.1.41` through `.45` in inventory order.
All nodes run Ubuntu 26.04 ARM64 directly from USB SSD root. K3s uses its
default data path, `/var/lib/rancher/k3s`.

## Setup

```bash
uv sync --locked --all-groups
uv run ansible-galaxy collection install -r requirements.yml -p ./collections
export KUBECONFIG=~/.kube/config-rpi
```

Run repository Python tools and Ansible commands with `uv run` so they use the
locked environment, for example `uv run ansible-playbook --syntax-check
03-addons.yml`.

Playbooks escalate with sudo (`become = True` in `ansible.cfg`).
`become_ask_pass` is off, so a cached timestamp is enough; if it has
expired the run fails with `sudo: a password is required` until you
pass `-K`.

## Multi-model workgroups

When the user requests delegation or parallel AI work, use the personal
`$delegate-ai-workgroups` skill and read `docs/AI-WORKGROUPS.md`. Keep one
coordinator responsible for architecture and final acceptance, assign disjoint
file scopes, and independently validate every worker handoff.

## Deployment and day-2 safety

First complete the manual EEPROM and SSD-root gate in `docs/RPI-EEPROM.md`.
Run `01-infra-prep.yml`, then `02-k3s-install.yml`. Join `pi-ctl-02` and
`pi-ctl-03` separately with `k3s-add-master.yml --limit <node> --forks=1`,
verifying etcd after each join. Then run `03-addons.yml` and
`04-monitoring.yml`, then `05-secrets.yml` once its 1Password inputs are
prepared. Finally run `06-flux.yml` to install Flux from the checksum-pinned
public NAS manifests. Nodes are expected to be `NotReady` after K3s bootstrap
until Cilium is installed.

Never rerun `02-k3s-install.yml` against a live cluster. For day-2 membership
operations, use `--limit`; add servers one at a time.

```bash
uv run ansible-playbook k3s-add-worker.yml --limit pi-wrk-02
uv run ansible-playbook k3s-remove-worker.yml --limit pi-wrk-02 -e wipe_data=true
uv run ansible-playbook k3s-add-master.yml --limit pi-ctl-03 --forks=1
uv run ansible-playbook k3s-remove-master.yml --limit pi-ctl-03
uv run ansible-playbook k3s-tune-usb-ssd.yml --limit pi-ctl-03
```

USB SSD UAS/autosuspend tunables live in `k3s-tune-usb-ssd.yml` (also
included from `01-infra-prep.yml`). Drain first; reboot is required for the
quirk to bind. Do not edit `/boot/firmware/cmdline.txt` — Ubuntu tryboot
uses `/boot/firmware/current/cmdline.txt`.

Useful targeted reruns are `03-addons.yml --tags cilium`,
`03-addons.yml --tags multus,whereabouts`, `03-addons.yml --tags longhorn`,
and `04-monitoring.yml --tags vmsingle`, `--tags victorialogs`,
`--tags vmagent`, or `--tags grafana`.

## Architecture invariants

- `br-storage` must exist before Multus. The Longhorn `storage-network` NAD is
  deliberately bridge CNI, not ipvlan.
- Longhorn data lives at `/var/lib/longhorn`, has two replicas, and schedules
  only on `pi-ctl-03`, `pi-wrk-01`, and `pi-wrk-02`.
- Cilium cluster-pool IPv4 must be `k3s_cluster_cidr` (`10.42.0.0/16`), not
  the chart default `10.0.0.0/8`. Changing that on a live cluster re-IPs
  every pod.
- Keep Cilium `cni.exclusive: false` and the privileged Multus mount settings.
  The thick daemon must mount host netns at both `/run/netns` and
  `/var/run/netns` (containerd passes the latter; the Multus image's `/var/run`
  is not a symlink to `/run`). Every node needs `/etc/cni/net.d/00-multus.conf`.
  The `bridge` plugin must exist as a real file in `/opt/cni/bin` (copied from
  `/var/lib/rancher/k3s/data/cni/bridge`; a host symlink will not resolve
  inside the Multus container). Without it, storage-network attachment fails
  after primary CNI succeeds.
- K3s uses `/var/lib/rancher/k3s`; retain Longhorn's explicitly pinned
  kubelet root setting unless verified otherwise.
- Grafana credentials are supplied through the vaulted `grafana-admin` Secret.
- Monitoring writes to the stable `vmsingle-stable` service.
- External Secrets uses a dedicated 1Password vault; never store its service
  account token in Git or Flux.
- Host preparation writes temperature and root-SSD SMART textfile metrics for
  node-exporter. Keep SCSI SMART as the default unless the actual USB bridge is
  tested with another mode.
- Every K3s install/join path must render `/etc/crictl.yaml` for
  `unix:///run/k3s/containerd/containerd.sock` and verify `crictl info`.
  Use `k3s-configure-crictl.yml` for existing nodes; never rerun bootstrap for
  this configuration.

Synology DS923+ NFS CSI is deferred until after the baseline. It will be a
non-default RWX class beside Longhorn; its endpoint, export, and credentials
are still TBD. Prefer the Synology SSH bare repository with an off-NAS mirror
as the canonical Git remote; do not treat in-cluster Forgejo as canonical.

## Verification

```bash
./scripts/verify-cluster.sh
```

See `docs/OPERATIONS.md`, `docs/TROUBLESHOOTING.md`, and `docs/RUNBOOKS.md`.
