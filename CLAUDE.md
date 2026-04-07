# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Ansible playbooks for deploying and managing a K3s cluster on Raspberry Pi 4 hardware. The cluster runs:
- **K3s** (1 control plane + 4 workers) with default networking stack disabled
- **Cilium** as CNI + kube-proxy replacement + L2 LoadBalancer
- **Multus + Whereabouts** for secondary storage network attachments
- **Longhorn** for distributed block storage on USB SSDs
- **Traefik** for ingress (both IngressRoute CRD and Gateway API)
- **VictoriaMetrics + VictoriaLogs + Grafana** for metrics+logs observability
  - VictoriaMetrics: metrics TSDB (PromQL compatible)
  - VictoriaLogs: log storage (LogsQL, Loki-compatible ingest)
  - Fluent Bit: log shipper DaemonSet on all nodes
  - Grafana: unified dashboards for both metrics and logs

## Environment Setup

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml -p ./collections
export KUBECONFIG=~/.kube/config-rpi
```

## Common Commands

```bash
# Test SSH connectivity
ansible -i hosts.ini all -m ping

# Run a playbook (sudo password required - become_ask_pass = True in ansible.cfg)
ansible-playbook 01-infra-prep.yml
ansible-playbook 02-k3s-install.yml
ansible-playbook 03-addons.yml
ansible-playbook 04-monitoring.yml

# Target a single node
ansible-playbook 01-infra-prep.yml --limit k3s-wrk-03

# Targeted rerun of a component layer (03-addons.yml)
ansible-playbook 03-addons.yml --tags cilium
ansible-playbook 03-addons.yml --tags multus,whereabouts
ansible-playbook 03-addons.yml --tags longhorn
ansible-playbook 03-addons.yml --tags traefik

# Targeted rerun of monitoring components (04-monitoring.yml)
ansible-playbook 04-monitoring.yml --tags vmsingle
ansible-playbook 04-monitoring.yml --tags victorialogs
ansible-playbook 04-monitoring.yml --tags vmagent
ansible-playbook 04-monitoring.yml --tags fluent-bit
ansible-playbook 04-monitoring.yml --tags grafana
ansible-playbook 04-monitoring.yml --tags verification

# Quick cluster health check
./scripts/verify-cluster.sh
```

## Day-2 Node Operations

Never re-run `02-k3s-install.yml` on a live cluster — use dedicated node management playbooks instead. All require `--limit`:

```bash
ansible-playbook k3s-add-worker.yml --limit k3s-wrk-05
ansible-playbook k3s-remove-worker.yml --limit k3s-wrk-05
ansible-playbook k3s-add-master.yml --limit k3s-ctl-02  # add ONE AT A TIME
ansible-playbook k3s-remove-master.yml --limit k3s-ctl-03

# Wipe data on removal
ansible-playbook k3s-remove-worker.yml --limit k3s-wrk-05 -e wipe_data=true
```

## Architecture: Dependency Chain

The cluster has four layers that must be deployed in order and diagnosed bottom-up:

1. **Host prep** (`01-infra-prep.yml`): SSD mounts, `/var` offloaded to SSD, cgroups, `br-storage` bridge from USB NIC — must exist before K3s or Multus work
2. **K3s** (`02-k3s-install.yml`): Nodes will show `NotReady` until Cilium is installed — this is expected
3. **Add-ons** (`03-addons.yml`): Cilium must be healthy first; Multus/Whereabouts depend on `br-storage`; Longhorn depends on the `storage-network` NAD; Traefik depends on Cilium L2 for its external IP
4. **Monitoring** (`04-monitoring.yml`): Depends on Longhorn PVCs for storage

## Key Configuration Files

- [group_vars/all.yml](group_vars/all.yml): Single source of truth for all component versions (`k3s_version`, `cilium_version`, `longhorn_version`, etc.) and cluster-wide settings (`master_ip`, network ranges, monitoring sizing)
- [hosts.ini](hosts.ini): Node inventory with `storage_ip` and `storage_mac` for each node's USB Ethernet adapter (used by the storage network setup)
- [ansible.cfg](ansible.cfg): `become_ask_pass = True` — sudo password will be prompted on every playbook run

## Storage Architecture

- OS runs on SD card; all heavy-write paths are on USB SSD mounted at `/mnt/ssd`
- K3s data: `/mnt/ssd/k3s`; Longhorn volumes: `/mnt/ssd/longhorn`; entire `/var` is bind-mounted from `/mnt/ssd/var`
- Storage replication traffic uses a dedicated network (`192.168.10.0/24`) via USB Ethernet adapters, isolated from application traffic

## Storage NAD: Bridge, Not ipvlan

The `storage-network` NetworkAttachmentDefinition uses `type: bridge` (veth pairs via `br-storage`), **not** `ipvlan`. Longhorn's iSCSI initiator runs in the host network namespace via `nsenter`; ipvlan L2 has a kernel limitation where the host cannot reach its own pod's ipvlan address, which causes iSCSI "No route to host" during volume discovery. Do not switch this back to ipvlan.

## Multus Patch Details

The Multus DaemonSet patch in `03-addons.yml` does **not** just reapply the upstream manifest — it also:

- Sets `securityContext: privileged: true` on both the init container and main container
- Adds `mountPropagation: HostToContainer` on `hostroot`, `host-run-netns`, and `host-var-lib-kubelet` mounts — this ensures new nsfs bind mounts created by containerd on the host propagate into the Multus container so Cilium CNI can enter pod network namespaces
- Uses `install_multus -t thick` in the init container

Do **not** apply raw upstream manifests directly — always upgrade by changing `multus_version` in `group_vars/all.yml` and rerunning with `--tags multus,whereabouts`.

## Longhorn Node Tags

The playbook explicitly sets `spec.tags: ["storage-network"]` on every worker Longhorn node CR (via the `longhorn_node_tags` variable in `group_vars/all.yml`). Longhorn does **not** auto-populate these tags — if they are missing, the storage network column in the Longhorn UI will be blank and replication may not use the dedicated network. If a new node is added and tags are missing, rerun `--tags longhorn`.

## Operational Docs

- [docs/OPERATIONS.md](docs/OPERATIONS.md): Component dependency chain and safe rerun patterns
- [docs/RUNBOOKS.md](docs/RUNBOOKS.md): Recovery procedures
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md): Diagnosis commands per component
- [docs/UPGRADING.md](docs/UPGRADING.md): K3s, Cilium, Longhorn, Multus upgrade procedures
- [docs/MAINTENANCE.md](docs/MAINTENANCE.md): etcd backup/restore, SD/SSD health checks
- [dashboards/README.md](dashboards/README.md): Custom Grafana dashboard workflow
