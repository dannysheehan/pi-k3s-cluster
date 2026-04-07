# Pi K3s Cluster - Troubleshooting and Component Guide

This guide is written as an operator reference for the moving parts in this repo.
It focuses on what each component does, how the components depend on one another,
and which `kubectl` commands are the fastest way to diagnose issues.

## Component Map

### K3s
- Runs the Kubernetes control plane and agent services.
- Stores cluster state under `/mnt/ssd/k3s`.
- Provides the API server that every other component depends on.

Useful checks:
```bash
kubectl get nodes -o wide
kubectl get pods -A
sudo systemctl status k3s
sudo systemctl status k3s-agent
```

### Cilium
- Primary CNI for the cluster.
- Replaces Flannel and kube-proxy.
- Handles pod networking on the main cluster network.
- Provides L2 load balancer behavior for `LoadBalancer` services.

What depends on it:
- All regular pod networking
- Traefik external IP advertisement
- Hubble metrics and UI

Useful checks:
```bash
kubectl get pods -n kube-system -l k8s-app=cilium -o wide
kubectl describe ds cilium -n kube-system
kubectl exec -n kube-system ds/cilium -- cilium status
kubectl exec -n kube-system ds/cilium -- sh -c 'wget -qO- http://127.0.0.1:9962/metrics | head'
```

### Multus
- Secondary CNI meta-plugin.
- Lets selected pods attach to more than one network interface.
- In this repo it is used so Longhorn can reach the dedicated `br-storage` network.

What depends on it:
- The `storage-network` NetworkAttachmentDefinition
- Longhorn `storageNetwork` integration

Common failure mode:
- If Multus host CNI state is wrong, new pods can get stuck in `ContainerCreating`
  with `FailedCreatePodSandBox`.

Useful checks:
```bash
kubectl get ds -n kube-system kube-multus-ds
kubectl logs -n kube-system ds/kube-multus-ds --tail=100
kubectl get network-attachment-definition -A
```

Known repo safeguards:
- `03-addons.yml` reapplies a local patch to `kube-multus-ds` after the upstream
  manifest install.
- The patch switches `install-multus-binary` to `install_multus -t thick`,
  keeps the standard `/run/netns` hostPath mount for Ubuntu/K3s nodes, and sets
  a higher `kube-multus` resource request without a hard memory limit to avoid
  known reboot-race and low-memory failures.

### Whereabouts
- IPAM for secondary networks managed by Multus.
- Allocates addresses on the dedicated storage subnet.
- Excludes statically assigned node `storage_ip` values from inventory.

What depends on it:
- `storage-network` address assignment
- Any future workload using secondary network IPAM

Useful checks:
```bash
kubectl get ds -n kube-system whereabouts
kubectl get crd | grep whereabouts
kubectl logs -n kube-system ds/whereabouts --tail=100
kubectl get ippools.whereabouts.cni.cncf.io -A
```

### Longhorn
- Distributed block storage for PVCs.
- Stores data on `/mnt/ssd/longhorn`.
- Uses the dedicated storage network for replication traffic.
- Also uses `longhorn.io/storage-ip` annotations to bind replication to each node's storage IP.

What depends on it:
- Persistent volumes for VictoriaMetrics and Grafana
- Any app using the `longhorn` storage class

Useful checks:
```bash
kubectl get pods -n longhorn-system
kubectl get settings.longhorn.io -n longhorn-system
kubectl get nodes.longhorn.io -n longhorn-system -o jsonpath='{range .items[*]}{.metadata.name}: {.metadata.annotations.longhorn\.io/storage-ip}{"\n"}{end}'
kubectl get network-attachment-definition -n longhorn-system
kubectl describe ds longhorn-manager -n longhorn-system
```

### Traefik
- Ingress and Gateway API controller.
- Exposes services through a `LoadBalancer` IP provided by Cilium L2.
- Also exposes Prometheus-format metrics for monitoring.

What depends on it:
- User-facing HTTP routing
- Grafana `/grafana` access path
- Gateway API examples

Useful checks:
```bash
kubectl get pods -n traefik -o wide
kubectl get svc -n traefik traefik
kubectl logs -n traefik deploy/traefik --tail=100
kubectl get ingressroute -A
kubectl get gateway -A
kubectl get httproute -A
```

### VictoriaMetrics Stack
- `vmsingle`: stores metrics
- `vmagent`: scrapes targets and remote-writes to `vmsingle`
- Grafana: queries VictoriaMetrics and renders dashboards

What depends on it:
- Operational dashboards
- Metric-based troubleshooting

Useful checks:
```bash
kubectl get pods -n monitoring
kubectl logs -n monitoring -l app.kubernetes.io/instance=vmagent --tail=200
kubectl port-forward -n monitoring svc/vmsingle-victoria-metrics-single-server 8428:8428
curl 'http://127.0.0.1:8428/api/v1/label/__name__/values' | grep -E 'cilium|traefik|hubble'
```

### VictoriaLogs
- Log storage and query backend (LogsQL compatible, Loki-compatible ingest).
- Stores logs under the same `monitoring` namespace as VictoriaMetrics.
- Exposes HTTP API at port 9428.
- **Requires `_msg` as the message field.** Fluent Bit writes logs using a field named `log`;
  the Fluent Bit config includes a `[FILTER] Name modify / Rename log _msg` block to
  translate this before forwarding. If this filter is missing, VictoriaLogs accepts the
  entries but silently marks them as having `"missing _msg field"` — every query returns
  no visible text.

What depends on it:
- Grafana Logs dashboards and Explore
- Fluent Bit (sends to it)

Useful checks:
```bash
kubectl get pods -n monitoring -l app=vlogs-victoria-logs-single
kubectl get statefulset -n monitoring vlogs-victoria-logs-single-server
# Smoke test — should return log lines with a _msg field
kubectl exec -n monitoring vlogs-victoria-logs-single-server-0 -- \
  wget -qO- 'http://127.0.0.1:9428/select/logsql/query?query=*&limit=1'
# Check for _msg field presence
kubectl exec -n monitoring vlogs-victoria-logs-single-server-0 -- \
  wget -qO- 'http://127.0.0.1:9428/select/logsql/query?query=*&limit=1' | grep _msg
```

### Fluent Bit
- Log collection DaemonSet running on every worker node.
- Tails `/var/log/containers/*.log` and enriches entries with Kubernetes metadata.
- Forwards logs to VictoriaLogs via the Loki-compatible `/insert/loki/api/v1/push` endpoint.
- **Critical filter**: must rename `log` → `_msg` before forwarding (see VictoriaLogs note above).

What depends on it:
- VictoriaLogs receiving any data at all

Useful checks:
```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=fluent-bit
kubectl logs -n monitoring -l app.kubernetes.io/name=fluent-bit --tail=50
# Check Fluent Bit output plugin errors specifically
kubectl logs -n monitoring -l app.kubernetes.io/name=fluent-bit --tail=100 | grep -i 'error\|warn\|output'
```

## How The Networking Pieces Fit Together

### Primary cluster network
1. K3s starts with Flannel disabled.
2. Cilium becomes the primary CNI.
3. Normal pods get their main interface from Cilium.
4. Traefik gets a `LoadBalancer` IP from Cilium L2.

Useful checks:
```bash
kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy
kubectl get svc -n traefik traefik
```

### Dedicated storage network
1. `01-infra-prep.yml` creates `br-storage` on each node.
2. Multus adds support for a secondary interface.
3. Whereabouts allocates IPs on the storage subnet.
4. `03-addons.yml` creates the `storage-network` NAD in `longhorn-system`.
5. Longhorn uses `storageNetwork` plus node `storage-ip` annotations for replication traffic.
6. `03-addons.yml` also sets `spec.tags: ["storage-network"]` on every worker
   Longhorn node CR. These tags are **never auto-populated** by Longhorn — they
   must be set explicitly (see
   [Storage Tags docs](https://longhorn.io/docs/archives/1.5.5/volumes-and-nodes/storage-tags/)).

Useful checks:
```bash
kubectl get network-attachment-definition -n longhorn-system storage-network -o yaml
kubectl get nodes.longhorn.io -n longhorn-system -o yaml | grep storage-ip
kubectl get nodes.longhorn.io -n longhorn-system -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.tags}{"\n"}{end}'
ansible all -a "ip addr show br-storage"
```

If a new node shows blank in the Longhorn UI "storage-network" column, rerun:
```bash
ansible-playbook 03-addons.yml --tags longhorn
```

## Quick Failure Isolation

### Pods stuck in `ContainerCreating`
Usually a node/runtime/CNI problem.

Checks:
```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl get events -A --sort-by=.lastTimestamp | tail -50
kubectl get ds -n kube-system kube-multus-ds whereabouts
kubectl get pods -n kube-system -l k8s-app=cilium -o wide
```

### LoadBalancer IP missing
Usually Cilium L2 or Traefik service configuration.

Checks:
```bash
kubectl get svc -n traefik traefik
kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy
kubectl describe svc -n traefik traefik
```

### Longhorn volumes not attaching
Usually storage network, storage IP annotations, or Longhorn manager health.

Checks:
```bash
kubectl get pods -n longhorn-system
kubectl get volumes.longhorn.io -n longhorn-system
kubectl describe volume <name> -n longhorn-system
kubectl get settings.longhorn.io storage-network -n longhorn-system -o jsonpath='{.value}'
```

### Metrics missing in Grafana
Split the problem into exporter, scrape, and storage/query.

Checks:
```bash
kubectl logs -n monitoring -l app.kubernetes.io/instance=vmagent --tail=200
kubectl exec -n kube-system ds/cilium -- sh -c 'wget -qO- http://127.0.0.1:9962/metrics | head'
kubectl exec -n traefik deploy/traefik -- sh -c 'wget -qO- http://127.0.0.1:9100/metrics | head'
curl 'http://127.0.0.1:8428/api/v1/series?match[]=cilium_process_cpu_seconds_total'
```
### Logs missing in Grafana (VictoriaLogs datasource shows no data)
Work bottom-up: Fluent Bit → VictoriaLogs ingest → Grafana datasource.

Checks:
```bash
# 1. Is Fluent Bit running on all nodes?
kubectl get pods -n monitoring -l app.kubernetes.io/name=fluent-bit -o wide

# 2. Any Fluent Bit output errors?
kubectl logs -n monitoring -l app.kubernetes.io/name=fluent-bit --tail=100 | grep -i 'error\|warn'

# 3. Is VictoriaLogs receiving and storing anything?
kubectl exec -n monitoring vlogs-victoria-logs-single-server-0 -- \
  wget -qO- 'http://127.0.0.1:9428/select/logsql/query?query=*&limit=1'

# 4. Do stored entries have a _msg field? (absence = Fluent Bit filter missing)
kubectl exec -n monitoring vlogs-victoria-logs-single-server-0 -- \
  wget -qO- 'http://127.0.0.1:9428/select/logsql/query?query=*&limit=1' | grep _msg

# 5. Is the Grafana datasource uid correct? (must be 'victorialogs')
kubectl get secret -n monitoring grafana -o jsonpath='{.data.grafana\.ini}' | base64 -d | grep -A5 victorialogs
```

Most common root causes:
- Fluent Bit `[FILTER] Rename log _msg` block is missing → all entries stored without message text
- Grafana datasource provisioned without explicit `uid: victorialogs` → dashboard panels using
  hardcoded `"uid": "victorialogs"` cannot resolve the datasource
- LogsQL query syntax error in a dashboard panel (LogsQL is **not** PromQL —
  `count() by (field)` does not work; use a plain filter expression with `queryType: hits`)
## Useful Namespace Views

```bash
kubectl get all -n kube-system
kubectl get all -n longhorn-system
kubectl get all -n traefik
kubectl get all -n monitoring
```

## Safe Targeted Reruns

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
ansible-playbook 04-monitoring.yml --tags verification
```

## Ansible Helm Gotcha: `helm repo update` Must Be Explicit

The `kubernetes.core.helm_repository` module only registers a repo URL — it
does **not** run `helm repo update`. If a targeted rerun skips the repo
registration tasks but tries to install a chart, Helm will use a stale index
and fail with:

```
Error: no chart version found for <chart>-<version>
```

The playbook works around this by running an explicit
`ansible.builtin.command: helm repo update` task tagged with **all** component
tags so it always fires before any install task in a targeted rerun. If you
add a new chart to the playbook, ensure its component tag is also on the repo
tasks and the `helm repo update` task.
