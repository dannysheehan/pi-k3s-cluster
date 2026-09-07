# GitOps

GitOps is post-baseline work. First verify the clean-slate K3s baseline with
`./scripts/verify-cluster.sh`.

The canonical `home-gitops` remote is the Forgejo instance on the Synology
DS923+:

- maintainer push: `ssh://git@nas.home.ftmon.org:2222/dsheehan/home-gitops.git`;
- anonymous Flux read: `http://nas.home.ftmon.org:3000/dsheehan/home-gitops.git`;
- branch/path: `main` / `./clusters/rpi`.

The workstation SSH key authenticates as Forgejo user `dsheehan` and a push
dry-run has been verified. Anonymous HTTP clone access has also been verified.
This removes the in-cluster Forgejo bootstrap dependency; the in-cluster
service is an application, not the canonical source. The NAS is still one
failure domain, so configure and test an independent off-NAS mirror. Prefer
HTTPS for Flux when trusted TLS is available; plain HTTP provides no transport
integrity. See [Synology DS923+ follow-up setup](SYNOLOGY.md) for recovery
tests and the deferred NFS RWX plan.

Flux reconciles applications and UI routing from that remote.
Keep cluster bootstrap and frozen versions in `group_vars/all.yml` separate from
post-baseline application configuration.

Synology DS923+ NFS CSI is also deferred. A future GitOps deployment must use
the upstream NFS CSI driver and keep it a non-default RWX StorageClass alongside
Longhorn with TBD inputs.
