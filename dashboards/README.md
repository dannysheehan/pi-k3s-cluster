# Dashboards

This directory holds custom Grafana dashboards and the Kubernetes manifests used
to provision them.

## Files

- `cilium-overview.json`
  - The raw Grafana dashboard JSON.
- `cilium-overview-configmap.yaml`
  - A ConfigMap manifest labeled for Grafana's dashboard sidecar.

## Recommended Pattern For New Dashboards

1. Create or export the dashboard JSON into this directory.
2. Create a matching `*-configmap.yaml` manifest that places the JSON under
   `ConfigMap.data`.
3. Apply that manifest from `04-monitoring.yml` with a dedicated task.

Why use this pattern:
- It avoids large inline JSON blobs in Ansible playbooks.
- It avoids YAML/templating edge cases when Grafana placeholders like
  `{{ node }}` appear inside dashboard definitions.
- It makes dashboard diffs easier to review.
