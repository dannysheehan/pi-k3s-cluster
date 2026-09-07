# Synology DS923+ follow-up setup

This guide covers two independent DS923+ services: the active off-cluster Git
source for Flux, and a future explicitly selected NFS `ReadWriteMany` (RWX)
storage path. The Git source is part of rebuild recovery; NFS remains deferred
until the clean-slate baseline is accepted.

Before starting, the operator must provide and record the following values;
they are deliberately not guessed here:

| Input | Placeholder |
| --- | --- |
| NAS DNS name | `nas.home.ftmon.org` |
| Forgejo HTTP / SSH ports | `3000` / `2222` |
| DSM volume and shared-folder name | `<volume>` / `<shared-folder>` |
| Git repository | `dsheehan/home-gitops` |
| Maintainer Forgejo account | `dsheehan` (selected by the workstation SSH key) |
| Git default branch and Flux path | `main` / `./clusters/rpi` |
| NFS export path and allowed client CIDR | `<nfs-export-path>` / `<client-cidr>` |
| NFS workload UID/GID and squash policy | `<uid>` / `<gid>` / `<squash-policy>` |

The Git repository is intentionally publicly readable so a new Flux controller
can clone it without a bootstrap credential. Writes still require SSH key
authentication. Restrict DSM administration, NFS, and unrelated NAS services
at the firewall; expose only the intended Forgejo endpoints. Plain HTTP does
not protect repository traffic from alteration in transit, so trusted HTTPS is
a follow-up requirement when certificates are available.

## A. Canonical Git remote for Flux

The canonical `home-gitops` repository is Forgejo on the DS923+. It is outside
the K3s cluster, so Flux can recover application configuration while the
in-cluster Forgejo application and all cluster PVCs are unavailable.

```text
Web:        http://nas.home.ftmon.org:3000/dsheehan/home-gitops
Flux read:  http://nas.home.ftmon.org:3000/dsheehan/home-gitops.git
Git push:   ssh://git@nas.home.ftmon.org:2222/dsheehan/home-gitops.git
```

The local `home-gitops` checkout uses the SSH URL as `origin`. Its key is
mapped by Forgejo to user `dsheehan`; Forgejo correctly refuses interactive
shell access. Anonymous HTTP `ls-remote`, SSH fetch, and a no-op SSH push
dry-run were verified on 2026-09-07 at commit `c4bb55a`.

Flux's `GitRepository/flux-system` uses the public HTTP URL without a
`secretRef`. This deliberately removes secret provisioning from initial Flux
recovery. The repository must remain public for that configuration to work.
If it becomes private, switch Flux to a dedicated read-only deploy key and pin
the NAS SSH host key; never give the controller a maintainer write key.

For a clean bootstrap, install the Flux controllers at the version committed
under `clusters/rpi/flux-system`, then apply `gotk-sync.yaml`. The source must
become Ready before any in-cluster Forgejo resources are required:

```bash
kubectl apply -f clusters/rpi/flux-system/gotk-components.yaml
kubectl apply -f clusters/rpi/flux-system/gotk-sync.yaml
flux reconcile source git flux-system --with-source
flux reconcile kustomization flux-system --with-source
```

### Recovery, availability, and backup tests

Before depending on this service, prove all of the following:

- A new workstation can clone anonymously over the Flux URL and fetch/push
  with the maintainer SSH key after verifying the SSH host key.
- Push a harmless committed change, reconcile it, and confirm that Flux uses
  the expected revision without a Kubernetes Git credential Secret.
- Recover a clean Flux controller/cluster from the NAS remote and reconcile
  the intended manifests without relying on Forgejo.
- Take a DSM snapshot of the Git shared folder and restore a test clone from
  it. Configure Hyper Backup or equivalent replication to an off-NAS target,
  then test restoring a repository from that copy.
- Keep a tested second mirror outside the NAS (for example, another private
  Git remote under operator control) and periodically test clone and recovery
  from it.
- Simulate or schedule a NAS reboot/outage and document Flux's expected stale
  state, alerting, recovery time, and the successful post-recovery reconcile.

The DS923+ is still one availability and failure domain. RAID, snapshots, and
Hyper Backup reduce different risks but do not make the NAS highly available;
the independently tested off-NAS mirror is required for recovery from NAS loss.

## B. Deferred NFS RWX StorageClass

Use the upstream GA [Kubernetes NFS CSI driver](https://github.com/kubernetes-csi/csi-driver-nfs), `kubernetes-csi/csi-driver-nfs`, when this work is scheduled.
Do not deploy the unmaintained/legacy `nfs-subdir-external-provisioner` as the
cluster's NFS solution. This is a separate, non-default StorageClass for
workloads that explicitly need shared RWX filesystems.

Longhorn remains the default replicated `ReadWriteOnce` (RWO) storage path on
`pi-ctl-03`, `pi-wrk-01`, and `pi-wrk-02`. Do not place embedded etcd, K3s
state, Longhorn replicas, Longhorn backups/metadata, or other Longhorn
internals on NFS.

### DSM NFS preparation

1. Enable NFS in DSM and create a dedicated share for Kubernetes dynamic
   provisioning; do not export a general-purpose personal share.
2. Add an NFS permission for only `<client-cidr>` and record the export as
   `<nfs-export-path>`. Limit it to the cluster nodes that will mount it.
3. Prefer NFSv4 if the DS923+, nodes, CSI-driver version, identity mapping, and
   workload tests all succeed. Retain the option to use a tested supported NFS
   version when they do not; do not assume an NFSv4 configuration is correct
   merely because it is preferred.
4. Use `AUTH_SYS` deliberately: container UID/GID values are sent to the NAS,
   so define workload ownership and group IDs in advance. Apply the least
   permissive workable squash and share permissions. Do not casually use
   `map-all-to-admin`, and do not map root to an administrator identity. Test
   the selected root-squash/no-root-squash behaviour with a non-privileged
   workload before granting broader access.
5. Keep NFS access limited by DSM firewall and export client rules, and ensure
   the NAS storage and network capacity are acceptable for the intended shared
   workload.

### Kubernetes rollout and validation

Install a pinned, supported release of `csi-driver-nfs` following its upstream
documentation. Create a StorageClass with a distinct name such as
`synology-nfs-rwx` (replace it if the final naming standard differs), point it
at `<nas-host>:<nfs-export-path>`, set it as **non-default**, and initially use
`reclaimPolicy: Retain`. Do not change Longhorn's default StorageClass.

Validate with disposable test data before any application uses it:

- Mount one RWX PVC from two pods on different nodes; create, read, and update
  files concurrently while checking expected UID/GID and permissions.
- Reschedule a consumer pod and verify the shared files remain available and
  uncorrupted.
- Exercise dynamic provision, PVC deletion, and the resulting retained
  directory/archive procedure. Define how operators inspect, archive, and
  explicitly remove retained data; do not let deletion semantics surprise
  users.
- Reboot the NAS and test a planned outage. Observe pod I/O behaviour,
  Kubernetes recovery, mount recovery, alerts, and application restart policy.
- Test an unplanned NAS connectivity outage and recovery. Record the result
  and the acceptable workload behaviour before approving production use.

Only promote a workload after these tests and after documenting its recovery
expectations. An RWX class is not a replacement for replicated Longhorn RWO
volumes, and an NFS outage affects every workload using that export.
