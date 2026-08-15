# Synology DS923+ follow-up setup

This guide is post-baseline work. It describes two independent future services
on the DS923+: an off-cluster Git source for Flux, and an explicitly selected
NFS `ReadWriteMany` (RWX) storage path. Neither is part of the initial K3s
deployment. Do not run any of these steps until the clean-slate baseline is
accepted.

Before starting, the operator must provide and record the following values;
they are deliberately not guessed here:

| Input | Placeholder |
| --- | --- |
| NAS LAN IP or DNS name | `<nas-host>` |
| SSH port | `<nas-ssh-port>` |
| DSM volume and shared-folder name | `<volume>` / `<shared-folder>` |
| Git bare-repository path | `<git-repo-path>` |
| Dedicated Git account name | `<git-account>` |
| Git repository name | `<repo-name>.git` |
| Git default branch and Flux path | `<branch>` / `<cluster-manifest-path>` |
| NFS export path and allowed client CIDR | `<nfs-export-path>` / `<client-cidr>` |
| NFS workload UID/GID and squash policy | `<uid>` / `<gid>` / `<squash-policy>` |

Keep the NAS LAN-only. Restrict DSM administration, SSH, and NFS in the DSM
firewall to the management workstation and the required cluster/client CIDRs;
do not publish any of these services to the Internet. Confirm the exact DSM
screens and package behaviour against Synology's [Git Server documentation](https://kb.synology.com/en-global/DSM/help/Git/git?version=6) and [NFS permissions documentation](https://kb.synology.com/en-us/PAS/help/PAS/AdminCenter/file_share_privilege_nfs?version=1_0).

## A. Preferred canonical Git remote for Flux

The preferred canonical remote for `home-gitops` is a private bare repository
on the DS923+ using Synology's Git Server package. It is off-cluster, so Flux
can recover application configuration while the in-cluster Forgejo instance is
unavailable. Forgejo may be a fresh mirror, but must not become the canonical
copy.

### DSM and account setup

1. Install and enable the DSM Git Server package. Enable SSH only if it is
   required for Git access, on `<nas-ssh-port>`.
2. Create the dedicated, non-administrator `<git-account>`. Do not use a DSM
   administrator or `root` for Git access. Restrict the account to the one
   Git shared folder and configure its shell/access as `git-shell` where the
   DSM/package setup supports it; it must not provide an interactive admin
   shell.
3. Create a dedicated shared folder on `<volume>` for the Git repositories.
   Grant only `<git-account>` the necessary access. Create the bare repository
   owned by that account, without `sudo` or `root`, for example at
   `<git-repo-path>/<repo-name>.git`. Do not expose a writable working tree as
   the canonical remote.
4. Verify that an SSH login using the Git account is limited to Git operations
   and that an ordinary shell or DSM administration is refused.

Use separate keys and do not reuse a personal workstation key for Flux:

- Add a **read-only Flux deploy key** to `<git-account>`/the repository. It
  must be able to clone and fetch only; it must not push.
- Add a distinct **workstation write key** for maintainers who push reviewed
  changes. Keep its private material only on approved workstations.
- Record and pin the NAS SSH host key fingerprint before configuring Flux.
  Place the verified `<nas-host>:<nas-ssh-port>` host key in Flux's known-hosts
  configuration rather than accepting a key interactively or disabling host
  checking. Re-verify the fingerprint through an independent local channel
  before any planned NAS replacement or host-key rotation.

An example remote URL, with values intentionally left as placeholders, is:

```text
ssh://<git-account>@<nas-host>:<nas-ssh-port>/<git-repo-path>/<repo-name>.git
```

From a workstation using the write key, initialise the bare remote and make
the first push only after checking the remote path and ownership:

```bash
git remote add synology 'ssh://<git-account>@<nas-host>:<nas-ssh-port>/<git-repo-path>/<repo-name>.git'
git push synology <initial-branch>
```

Use the actual repository and branch names in place of the placeholders. The
commands do not create accounts, keys, or secrets; provision those through the
approved DSM and secret-management process.

### Flux bootstrap and normal reconciliation

First create the Flux SSH Secret from the read-only deploy key and the
verified known-hosts entry using the current Flux documentation and the chosen
secret-management process. Do not put private keys, known-hosts material, or
passwords in this repository. Then bootstrap or configure Flux conceptually
with the SSH remote, branch, and manifest path:

```bash
flux bootstrap git \
  --url='ssh://<git-account>@<nas-host>:<nas-ssh-port>/<git-repo-path>/<repo-name>.git' \
  --branch='<branch>' \
  --path='<cluster-manifest-path>'

flux reconcile source git <gitrepository-name> --with-source
flux reconcile kustomization <kustomization-name> --with-source
```

Select the exact bootstrap command and flags after confirming the installed
Flux version and how it consumes the read-only deploy key. Bootstrap often
writes Flux manifests to the remote; if it needs write access, perform that
one-time repository initialisation with a controlled workstation credential,
then configure ongoing Flux reconciliation with the read-only key. Never
silently give the running controller a write key merely to make bootstrap
convenient.

### Recovery, availability, and backup tests

Before depending on this service, prove all of the following:

- A new workstation can clone with the write key after independently verifying
  the pinned SSH host key; Flux can fetch with only its read-only key.
- Push a harmless committed change, reconcile it, and confirm that Flux uses
  the expected revision. Confirm that the Flux key cannot push.
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
