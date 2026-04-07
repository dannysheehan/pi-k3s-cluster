---
description: Add a new Grafana dashboard to the cluster — from a JSON export or a Grafana.com dashboard ID.
argument-hint: "Dashboard name or Grafana.com dashboard ID, e.g. 'node exporter full' or '1860'"
agent: agent
tools:
  - read
  - search
  - edit
  - web
---

You are adding a new Grafana dashboard to this K3s cluster. The cluster uses the ConfigMap sidecar pattern described in `dashboards/README.md`.

## Workflow

1. **Get the dashboard JSON**
   - If the user provides a Grafana.com ID (e.g. `1860`), fetch it from `https://grafana.com/api/dashboards/<id>/revisions/latest/download`
   - If the user points to a local file, read it
   - Save the raw JSON as `dashboards/<name>.json`

2. **Check datasource references**
   - Search the JSON for `"datasource"` fields
   - Verify they match datasource UIDs provisioned in the cluster:
     - Metrics: uid `victoriametrics` (Prometheus-compatible)
     - Logs: uid `victorialogs`
   - If the dashboard uses `prometheus` or `loki` UIDs, update them to match

3. **Create the ConfigMap manifest**
   - Create `dashboards/<name>-configmap.yaml` following the pattern in `dashboards/cilium-overview-configmap.yaml`
   - The ConfigMap must have label `grafana_dashboard: "1"` for the sidecar to pick it up
   - Use `|-` block scalar for the JSON value to avoid YAML quoting issues
   - Do NOT use Ansible/Jinja2 `{{ }}` syntax inside the JSON — escape as `{{ '{{' }}` if needed

4. **Add the apply task to `04-monitoring.yml`**
   - Find the existing dashboard apply block (search for `cilium-overview-configmap`)
   - Add a new `kubernetes.core.k8s` task immediately after it
   - Tag it with `[monitoring, grafana]`
   - Use `src:` pointing to `dashboards/<name>-configmap.yaml`

5. **Show the apply command**

```
ansible-playbook 04-monitoring.yml --tags grafana
```

## Gotchas

- **YAML indentation**: The JSON value in the ConfigMap must be indented consistently — 4 spaces under the `data:` key is standard.
- **Jinja2 conflicts**: Grafana variables like `${node}` are fine; `{{ node }}` will be interpreted by Ansible. Use `{{ '{{' }}` to escape.
- **Community dashboard uid mismatch**: Dashboards from Grafana.com often hard-code a datasource uid. Always update to the cluster's actual uid before applying.
- **Panel plugin availability**: Community dashboards may require plugins not installed in this cluster's Grafana. Check `plugins` in the Grafana Helm values in `04-monitoring.yml` and add any missing ones.
