# pi-cluster

Ansible-managed clean-slate K3s baseline for five Ubuntu 26.04 ARM64 Raspberry
Pi nodes booting directly from USB SSD root.

## Current topology

| Role | Nodes | LAN addresses |
|---|---|---|
| K3s servers (schedulable) | `pi-ctl-01`–`pi-ctl-03` | `192.168.1.41`–`.43` |
| K3s agents | `pi-wrk-01`, `pi-wrk-02` | `192.168.1.44`, `.45` |
| API VIP | kube-vip | `192.168.1.40` |

K3s uses `/var/lib/rancher/k3s`. Component versions are frozen in
`group_vars/all.yml`.

## Commands

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
uv run ansible-playbook k3s-tune-usb-ssd.yml --limit pi-ctl-03
./scripts/verify-cluster.sh
```

Complete `docs/RPI-EEPROM.md` before bootstrap. Do not rerun the bootstrap
playbook (`02-k3s-install.yml`) on a live cluster.
For membership changes, target exactly one server at a time with
`k3s-add-master.yml --limit <node>`.

Longhorn uses bridge-based `storage-network`, `/var/lib/longhorn`, replicas
`2`, and only `pi-ctl-03`, `pi-wrk-01`, and `pi-wrk-02`. Grafana credentials
come from the vaulted `grafana-admin` Secret; monitoring uses
`vmsingle-stable`.

The Synology DS923+ NFS CSI integration is deferred post-baseline: it will be
a non-default RWX class alongside Longhorn, with connection inputs TBD. Prefer
the Synology SSH bare repository plus an off-NAS mirror as canonical Git.

Refer to `README.md` and `docs/` for operations guidance.
