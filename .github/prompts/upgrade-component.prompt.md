---
description: Upgrade a single cluster component to a new version. Updates group_vars/all.yml and provides the exact rerun command.
argument-hint: "Component name, e.g. cilium, victorialogs, grafana, longhorn"
agent: agent
tools:
  - read
  - search
  - edit
---

You are helping upgrade a component in a K3s Raspberry Pi cluster managed by Ansible.

## Component → Variable mapping

| Component | Variable in `group_vars/all.yml` | Playbook | Tag |
|-----------|----------------------------------|----------|-----|
| k3s | `k3s_version` | `02-k3s-install.yml` | _(see warning)_ |
| cilium | `cilium_version` | `03-addons.yml` | `cilium` |
| longhorn | `longhorn_version` | `03-addons.yml` | `longhorn` |
| traefik | `traefik_version` | `03-addons.yml` | `traefik` |
| multus | `multus_version` | `03-addons.yml` | `multus,whereabouts` |
| whereabouts | `whereabouts_version` | `03-addons.yml` | `multus,whereabouts` |
| victoriametrics / vmsingle | `victoria_metrics_version` | `04-monitoring.yml` | `vmsingle` |
| grafana | `grafana_version` | `04-monitoring.yml` | `grafana` |
| node-exporter | `node_exporter_chart_version` | `04-monitoring.yml` | `vmsingle` |
| vmagent | `vmagent_chart_version` | `04-monitoring.yml` | `vmagent` |
| victorialogs | `victorialogs_chart_version` | `04-monitoring.yml` | `victorialogs` |
| fluent-bit | `fluent_bit_chart_version` | `04-monitoring.yml` | `fluent-bit` |

## Workflow

1. Read `group_vars/all.yml` to find the current version of the requested component.
2. Identify the correct variable name from the table above.
3. Update the variable value in `group_vars/all.yml` to the new version provided by the user (or ask for it if not given).
4. Show the diff of the change.
5. Print the exact rerun command to apply the upgrade.

## Special Cases

**k3s** — NEVER re-run `02-k3s-install.yml` on a live cluster. K3s upgrades use the system-upgrade-controller or manual drain/upgrade. Warn the user and do not proceed automatically.

**multus + whereabouts** — Always upgrade together; always use `--tags multus,whereabouts`. Warn if the user only wants to upgrade one.

**whereabouts** — CRD manifests must be updated to match `whereabouts_version`. They live in `03-addons.yml` as URLs constructed from the version var. Version mismatch causes silent IP allocation failures.

## Output Format

After making the edit, respond with:

```
Updated: group_vars/all.yml
  cilium_version: "1.16.4" → "1.17.0"

Rerun command:
  ansible-playbook 03-addons.yml --tags cilium
```
