# Agent Guidance for pi-cluster

## Setup (run once)
```bash
source .venv/bin/activate
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml -p ./collections
export KUBECONFIG=~/.kube/config-rpi
```

Every `ansible-playbook` run will prompt for sudo password (`become_ask_pass = True` in `ansible.cfg`).

## Deployment Order
1. `01-infra-prep.yml` — Reboots nodes; wait 2-3 min before continuing
2. `02-k3s-install.yml` — Nodes show `NotReady` until Cilium; this is expected
3. `03-addons.yml` — Cilium, Multus, Longhorn, Traefik
4. `04-monitoring.yml` — VictoriaMetrics + Grafana

## Targeted Reruns
```bash
ansible-playbook 03-addons.yml --tags cilium
ansible-playbook 03-addons.yml --tags multus,whereabouts
ansible-playbook 03-addons.yml --tags longhorn
ansible-playbook 03-addons.yml --tags traefik
ansible-playbook 04-monitoring.yml --tags vmsingle
ansible-playbook 04-monitoring.yml --tags victorialogs
ansible-playbook 04-monitoring.yml --tags vmagent
ansible-playbook 04-monitoring.yml --tags fluent-bit
ansible-playbook 04-monitoring.yml --tags grafana
```

## Day-2 Node Operations
Use `--limit` on these. **Never re-run `02-k3s-install.yml` on a live cluster.**
```bash
ansible-playbook k3s-add-worker.yml --limit <node>
ansible-playbook k3s-remove-worker.yml --limit <node> -e wipe_data=true
ansible-playbook k3s-add-master.yml --limit <node>  # ONE AT A TIME
ansible-playbook k3s-remove-master.yml --limit <node>
```

## Single-Node Targeting
```bash
ansible-playbook 01-infra-prep.yml --limit k3s-wrk-03
```

## Key Architecture Facts

### Storage NAD uses bridge CNI, NOT ipvlan
The `storage-network` NetworkAttachmentDefinition uses `type: bridge`. This is intentional. Longhorn's iSCSI initiator runs in the host namespace via `nsenter`; ipvlan L2 has a kernel limitation where the host cannot reach its own pod's ipvlan address ("No route to host" during volume discovery). Do not switch to ipvlan.

### br-storage bridge must exist before Multus
`01-infra-prep.yml` creates the `br-storage` bridge from USB Ethernet adapters. This bridge must exist before Multus and Longhorn can function.

### Cilium must coexist with Multus
The playbook sets `cni.exclusive: false` in Cilium Helm values. Without this, Cilium renames `00-multus.conf` to `.cilium_bak`, breaking secondary network support.

### Multus DaemonSet requires specific settings
The playbook patches the Multus DaemonSet to add:
- `securityContext.privileged: true` on both containers
- `mountPropagation: HostToContainer` on `hostroot`, `host-run-netns`, `host-var-lib-kubelet` mounts

Without these, pod creation fails with `unknown FS magic` or `operation not permitted`.

### Longhorn node tags are manual
Longhorn does not auto-populate `spec.tags`. The playbook sets `storage-network` tags via `longhorn_node_tags` in `group_vars/all.yml`. When adding a worker, rerun `--tags longhorn` to apply tags.

### Whereabouts version must match CRDs
The `whereabouts_version` in `group_vars/all.yml` must align between CRD manifests and the DaemonSet image. Version mismatch causes silent IP allocation failures.

## Verification
```bash
./scripts/verify-cluster.sh
```

## Version Source of Truth
All component versions are in `group_vars/all.yml` (`k3s_version`, `cilium_version`, `longhorn_version`, etc.). Update there first, then rerun relevant playbooks.

## Diagnose Bottom-Up
- Grafana empty? Check exporter → VMAgent logs → VictoriaMetrics → dashboard query
- Grafana logs missing? Check Fluent Bit logs → VictoriaLogs ingest → VictoriaLogs datasource in Grafana
- Longhorn stuck? Check Multus/Whereabouts → storage NAD → node `storage-ip` annotations
- Nodes NotReady after K3s install? Expected until Cilium runs

See `docs/OPERATIONS.md` for the full component dependency chain and `docs/TROUBLESHOOTING.md` for per-component diagnosis commands.
