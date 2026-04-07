# Pi K3s Cluster - Runbooks

This file is for the situations where you do not want theory first. Each
section is a practical recovery sequence for a common failure mode in this
cluster.

Use this alongside:
- `OPERATIONS.md` for the architectural view
- `TROUBLESHOOTING.md` for component-specific diagnosis commands

## 1. Pods Stuck In `ContainerCreating`

Most often this means node runtime trouble, Cilium trouble, or Multus host CNI
state trouble.

### First checks

```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl get events -A --sort-by=.lastTimestamp | tail -50
kubectl get pods -n kube-system -l k8s-app=cilium -o wide
kubectl get ds -n kube-system kube-multus-ds whereabouts
```

### If the failure mentions `FailedCreatePodSandBox`

```bash
kubectl logs -n kube-system ds/kube-multus-ds --tail=100
kubectl logs -n kube-system ds/whereabouts --tail=100
```

If this started right after Multus changes, repair the secondary network stack:

```bash
ansible-playbook 03-addons.yml --tags multus,whereabouts
```

If a single node is wedged, inspect that node directly:

```bash
ssh ubuntu@<node-ip>
sudo systemctl status k3s-agent --no-pager
sudo journalctl -u k3s-agent -n 200 --no-pager
sudo crictl pods -a
```

## 2. Nodes Stay `NotReady`

### Right after `02-k3s-install.yml`

This is normal until Cilium is installed.

### After `03-addons.yml`

This is no longer normal. Start here:

```bash
kubectl get nodes -o wide
kubectl get pods -n kube-system -l k8s-app=cilium -o wide
kubectl exec -n kube-system ds/cilium -- cilium status
```

If one worker is still bad while `k3s-agent` is active, rerun the worker
recovery logic:

```bash
ansible-playbook 02-k3s-install.yml
```

## 3. Traefik Has No External IP

This usually points to Cilium L2 announcements or the Traefik `LoadBalancer`
service.

### Checks

```bash
kubectl get svc -n traefik traefik -o wide
kubectl describe svc -n traefik traefik
kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy
kubectl get pods -n kube-system -l k8s-app=cilium -o wide
```

### Recovery

If Cilium is otherwise healthy, rerun just the Traefik and Cilium-related
pieces:

```bash
ansible-playbook 03-addons.yml --tags cilium,traefik
```

## 4. Longhorn Volumes Will Not Attach

This cluster is more sensitive here because storage depends on both SSD
readiness and the dedicated storage network.

### Checks

```bash
kubectl get pods -n longhorn-system
kubectl get settings.longhorn.io -n longhorn-system
kubectl get nodes.longhorn.io -n longhorn-system -o jsonpath='{range .items[*]}{.metadata.name}: {.metadata.annotations.longhorn\.io/storage-ip}{"\n"}{end}'
kubectl get network-attachment-definition -n longhorn-system storage-network -o yaml
```

### Host-side check

```bash
ansible all -a "ip addr show br-storage"
ansible all -a "mount | grep /mnt/ssd"
```

### Recovery

If the host bridge exists and the node storage IP annotations are wrong or
missing, rerun Longhorn after confirming inventory values:

```bash
ansible-playbook 03-addons.yml --tags longhorn
```

If the issue started after secondary-network changes, rerun:

```bash
ansible-playbook 03-addons.yml --tags multus,whereabouts,longhorn
```

Note:
- `csi-attacher`, `csi-provisioner`, `csi-resizer`, and `csi-snapshotter`
  should migrate to workers in this repo
- `longhorn-csi-plugin` is a DaemonSet and may still appear on the control node
  unless you intentionally enforce a stricter no-Longhorn-on-control-plane
  policy

## 5. Monitoring Pods `OOMKilled`

The most likely pod to hit this on Pi hardware is `vmagent`.

### Checks

```bash
kubectl get pods -n monitoring
kubectl top pod -n monitoring
kubectl logs -n monitoring -l app.kubernetes.io/instance=vmagent --tail=200
```

### Recovery

Rerun the monitoring stack or just the scraper tier:

```bash
ansible-playbook 04-monitoring.yml --tags vmagent
```

If the pod still dies, reduce scrape load or raise the configured VMAgent
memory settings in the monitoring playbook inputs.

## 6. `Multi-Attach` Error On A Persistent Volume

This usually means a `Deployment` with a single Longhorn `ReadWriteOnce` PVC is
trying to roll from the old pod to the new pod using the default rolling update
strategy.

### Checks

```bash
kubectl get pods -n <namespace> -o wide
kubectl describe pod -n <namespace> <new-pod-name>
kubectl get volumeattachments
```

### Recovery

If the old pod is still holding the volume:

```bash
kubectl delete pod -n <namespace> <old-pod-name>
```

### Prevention

For single-replica apps with a Longhorn `ReadWriteOnce` PVC, use:

```yaml
deploymentStrategy:
  type: Recreate
```

## 7. Grafana Dashboards Are Empty

Do not start with Grafana itself. Split the problem into exporter, scrape,
storage, and dashboard layers.

### Checks

```bash
kubectl logs -n monitoring -l app.kubernetes.io/instance=vmagent --tail=200
kubectl port-forward -n monitoring svc/vmsingle-victoria-metrics-single-server 8428:8428
curl 'http://127.0.0.1:8428/api/v1/label/__name__/values' | grep -E 'cilium|traefik|hubble'
```

For Cilium specifically:

```bash
curl 'http://127.0.0.1:8428/api/v1/series?match[]=cilium_process_cpu_seconds_total'
```

### Recovery

```bash
ansible-playbook 04-monitoring.yml --tags vmagent,verification
ansible-playbook 04-monitoring.yml --tags grafana
```

If the metrics exist in VictoriaMetrics but the imported dashboard is still
empty, prefer a custom dashboard over continued dashboard-debugging.

## 8. Multus Or Whereabouts Changes Broke New Pod Scheduling

This cluster has already hit this class of failure, so it deserves a direct
runbook.

### Checks

```bash
kubectl get ds -n kube-system kube-multus-ds whereabouts
kubectl logs -n kube-system ds/kube-multus-ds --tail=100
kubectl logs -n kube-system ds/whereabouts --tail=100
kubectl get network-attachment-definition -A
```

### Recovery

Rerun only the pinned secondary-network stack:

```bash
ansible-playbook 03-addons.yml --tags multus,whereabouts
```

Note:
- This repo patches `kube-multus-ds` after applying the upstream Multus
  manifest.
- The patch uses `install_multus -t thick`, keeps the standard `/run/netns`
  hostPath mount for Ubuntu/K3s nodes, and sets a higher `kube-multus`
  resource request without a hard memory limit to reduce the known
  reboot-race and OOM failure modes.

Then verify ordinary pods can start:

```bash
kubectl run cni-smoke --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl get pod cni-smoke -w
kubectl delete pod cni-smoke
```

## 9. Safe Verification Pass

After any repair, this is a good minimum confirmation set:

```bash
./scripts/verify-cluster.sh
ansible-playbook 04-monitoring.yml --tags verification
```

## 10. Grafana Logs Show No Data (`_msg` Field Missing)

Symptom: VictoriaLogs is running and Fluent Bit pods are healthy, but the
Grafana Logs panel is empty or shows log entries with no message text.

### Root cause

VictoriaLogs requires the log message to be in a field named `_msg`. Fluent
Bit's Kubernetes tail input stores the raw log line in a field named `log`.
Without an explicit rename, VictoriaLogs accepts the entries but stores them
without a message body — every LogsQL query returns results with no visible
text.

### Verification

```bash
# Should return entries; check for _msg key in the output
kubectl exec -n monitoring vlogs-victoria-logs-single-server-0 -- \
  wget -qO- 'http://127.0.0.1:9428/select/logsql/query?query=*&limit=1'
```

If output contains `"_msg":""` or no `_msg` key at all, the filter is missing.

### Recovery

Verify the Fluent Bit ConfigMap (managed by the Helm chart values in
`04-monitoring.yml`) contains this filter block between the Kubernetes filter
and the Loki output:

```
[FILTER]
    Name    modify
    Match   kube.*
    Rename  log _msg
```

Reapply:

```bash
ansible-playbook 04-monitoring.yml --tags fluent-bit
```

Wait ~30 seconds for the DaemonSet to roll out, then re-verify.

## 11. Grafana Pod Stuck `Pending` — PVC Not Found

Symptom: After a `--tags grafana` rerun, the Grafana pod stays `Pending` with
an event like `persistentvolumeclaim "grafana" not found`.

### Root cause

The Grafana Helm chart is configured with `persistence.existingClaim: grafana`.
If the `grafana` PVC was deleted (e.g. by force-deleting a stuck pod while
Longhorn held the volume), Helm upgrade succeeds but the pod cannot start
because the PVC no longer exists.

### Verification

```bash
kubectl get pvc -n monitoring
# grafana PVC should appear; if absent, it needs to be recreated
```

### Recovery

Recreate the PVC manually (Helm will adopt the pre-existing claim on next
upgrade):

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana
  namespace: monitoring
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources:
    requests:
      storage: 2Gi
EOF
```

Then wait for Longhorn to provision the volume and the pod to start:

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -w
```

### Prevention

`04-monitoring.yml` includes an explicit `kubernetes.core.k8s` task that
ensures the `grafana` PVC exists before the Helm install/upgrade runs. This
means `--tags grafana` reruns are safe even if the PVC was previously deleted.

## 12. VictoriaLogs PVC Stuck in `Terminating`

Symptom: `kubectl get pvc -n monitoring` shows the VictoriaLogs volume
(`server-volume-vlogs-victoria-logs-single-server-0`) stuck in `Terminating`.

### Root cause

Longhorn uses a finalizer on PVCs associated with active volumes. The PVC will
not be fully deleted until the Longhorn volume is detached and cleaned up. This
can take several minutes after a force-delete.

### Recovery

First, wait 5 minutes to see if it self-resolves. If it is still stuck:

```bash
# Check if the Longhorn volume itself is gone
kubectl get volumes.longhorn.io -n longhorn-system | grep vlogs

# If the PVC finalizer is the only thing blocking deletion:
kubectl patch pvc server-volume-vlogs-victoria-logs-single-server-0 \
  -n monitoring \
  -p '{"metadata":{"finalizers":null}}' --type=merge
```

Once the PVC is gone, redeploy VictoriaLogs to get a fresh volume:

```bash
ansible-playbook 04-monitoring.yml --tags victorialogs
```
