# pi-cluster

Ansible playbooks for a clean-slate, highly available K3s baseline on five
Ubuntu 26.04 ARM64 Raspberry Pi nodes. This repository does not provide a
migration procedure and assumes a fresh deployment with no retained cluster
data.

## Topology

| Function | Name(s) | Address |
|---|---|---|
| API endpoint | kube-vip | `192.168.1.40` |
| Schedulable K3s servers | `pi-ctl-01`, `pi-ctl-02`, `pi-ctl-03` | `.41`, `.42`, `.43` |
| K3s agents | `pi-wrk-01`, `pi-wrk-02` | `.44`, `.45` |

All nodes boot directly from USB SSD root. K3s retains its default data
directory, `/var/lib/rancher/k3s`.

Before bootstrap, follow `docs/RPI-EEPROM.md` to update and inspect the Pi
bootloader, set SD-first recovery followed by USB boot, and prove SSD-root cold boots
with the SD card removed.

## Bootstrap

```bash
uv sync --locked --all-groups
uv run ansible-galaxy collection install -r requirements.yml -p ./collections
export KUBECONFIG=~/.kube/config-rpi

uv run ansible-playbook 01-infra-prep.yml
uv run ansible-playbook 02-k3s-install.yml
uv run ansible-playbook k3s-add-master.yml --limit pi-ctl-02 --forks=1
uv run ansible-playbook k3s-add-master.yml --limit pi-ctl-03 --forks=1
uv run ansible-playbook 03-addons.yml
uv run ansible-playbook 04-monitoring.yml
uv run ansible-playbook 05-secrets.yml
./scripts/verify-cluster.sh
```

K3s nodes remain `NotReady` until Cilium is installed, which is expected. Versions are frozen
in `group_vars/all.yml` and should be changed there first.

Do not rerun `02-k3s-install.yml` against a live cluster. For day-2 changes,
use the dedicated membership playbooks with `--limit`; add K3s servers one at
a time.

## Storage and observability

Longhorn is the default block-storage provider. It stores data in
`/var/lib/longhorn`, uses two replicas, and is restricted to `pi-ctl-03`,
`pi-wrk-01`, and `pi-wrk-02`. Its secondary `storage-network` is intentionally
bridge CNI via `br-storage`; do not change it to ipvlan.

Grafana uses the vaulted `grafana-admin` Secret. VictoriaMetrics ingestion and
queries use the stable `vmsingle-stable` service.

External Secrets Operator integrates the cluster with a dedicated 1Password
vault after baseline bootstrap. Its service-account token is entered privately
and stays out of Git; see `docs/SECRETS.md`.

Synology DS923+ NFS CSI is deliberately deferred until the baseline is proven.
It will be introduced as a non-default RWX StorageClass alongside Longhorn;
the server, export, and credentials remain TBD.

## GitOps

The preferred canonical Git remote is a private SSH bare repository on the
Synology DS923+, with a tested off-NAS mirror; its address and account details
remain operator inputs. Applications and UI routing may later be reconciled by
Flux from it. An in-cluster Git service is not canonical. See `docs/GITOPS.md`.

## Documentation

- `docs/DEPLOYMENT-CHECKLIST.md` — clean-slate deployment gates
- `docs/RPI-EEPROM.md` — SD-recovery-first EEPROM and SSD-root boot preflight
- `docs/SYNOLOGY.md` — off-cluster Git and future non-default NFS storage
- `docs/SECRETS.md` — External Secrets Operator and 1Password bootstrap
- `docs/AI-WORKGROUPS.md` — model routing and empirical delegation results
- `docs/OPERATIONS.md` — normal operations and component dependencies
- `docs/TROUBLESHOOTING.md` and `docs/RUNBOOKS.md` — diagnosis and recovery
- `docs/UPGRADING.md` and `docs/MAINTENANCE.md` — controlled lifecycle work
