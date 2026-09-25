# Full-cluster power-loss recovery, 2026-09-25

## Failure

After a power outage all five nodes booted and their K3s services were active,
but the API VIP `192.168.1.40` and application ingress were unreachable.
Direct API access at `192.168.1.41:6443` showed five Ready nodes. All three
control-plane APIs passed their readiness checks, including etcd.

kube-vip pods were Running but could not acquire their leader lease: requests
to `https://10.43.0.1:443` timed out. Cilium's startup configuration and operator
were waiting for `https://192.168.1.40:6443`. This was a circular dependency:
Cilium needed the VIP, while kube-vip needed Cilium's ClusterIP routing.
Multus then failed to create application pod networks because it also could
not reach the Kubernetes ClusterIP.

## Recovery and permanent fix

At approximately 16:34 AEST, patched the kube-vip DaemonSet through the direct
API endpoint. Each kube-vip container now obtains `KUBERNETES_SERVICE_HOST`
from the Downward API's `status.hostIP` and uses port `6443`. Leader election
therefore connects directly to that control-plane node before Cilium starts.
The VIP returned immediately and all three replacement kube-vip pods ran.

Updated `templates/k3s/kube-vip-daemonset.yaml.j2` and rendered it to the
existing K3s auto-deploy manifest on `pi-ctl-01`. The previous manifest is
saved outside the watched directory at
`/root/kube-vip-daemonset.before-power-recovery-2026-09-25.yaml` on that node.
No K3s bootstrap, etcd restore, or membership change was performed.

Recreated the failed Cilium pod on `pi-ctl-01` to clear its startup backoff,
verified it became Ready, then recreated the other four failed Cilium pods.
Added Cilium DaemonSet coverage to the cluster verification script, since
node Ready status and running host-network pods did not detect this outage.

The recovery procedure is documented in `TROUBLESHOOTING.md`. It updates
only the kube-vip manifest and does not rerun the bootstrap playbook.

## Secondary storage-network failure

After Cilium recovered, `pi-wrk-02` could not exchange traffic with the other
storage nodes, despite its USB Ethernet adapter reporting 1000 Mb/s link-up.
Host-to-host pings over `br-storage` failed. Packet captures showed ARP
requests leaving the local network stack on `pi-wrk-02` but not appearing at
`pi-wrk-01`; broadcasts from `pi-ctl-03` reached both nodes. This isolated the
failure to the worker's storage-network path, independently of Kubernetes.

Taking `enx74dada33eea7` down and up did not restore connectivity. Rebinding
only its `ax88179_178a` USB interface (`1-1.4:1.0`) restored traffic. Networkd
automatically returned the interface to `br-storage`. The management NIC,
root SSD, and K3s service remained running. The precise reason for the adapter
state after power loss is unconfirmed; no speculative boot-time reset was
installed.

Longhorn automatically salvaged and reattached the volumes. Replica recovery
is limited to one rebuild per node. Verification now checks volume robustness
as well as storage placement, so a working API with degraded storage fails
the cluster check.

## Acceptance at approximately 16:44 AEST

- `./scripts/verify-cluster.sh` passed with no failures or warnings.
- All five nodes were Ready and schedulable; all non-completed pods were
  Running with their containers Ready.
- All four Longhorn volumes were attached and healthy. The engine checks
  showed both replicas returning to read/write mode as rebuilds completed.
- Homepage returned HTTP 200 through `192.168.1.200`; Grafana's `/api/health`
  returned HTTP 200 with `database: ok` through the same ingress address.
- vmagent reported zero pending remote-write bytes and zero dropped packets.
- Flux source reconciliation and the 1Password retrieval canary passed.
- Offline rebuild invariants, the bootstrap playbook's syntax check, shell
  syntax validation, and `git diff --check` passed.

No second full-cluster power cycle was performed. The kube-vip fix was
validated while Cilium was unavailable during this incident. The USB adapter
recovery was verified with host and storage-pod connectivity and successful
replica rebuilds; its underlying failure remains a follow-up investigation.
