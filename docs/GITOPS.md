# GitOps

GitOps is post-baseline work. First verify the clean-slate K3s baseline with
`./scripts/verify-cluster.sh`.

The canonical Git remote must remain off-cluster. The preferred future provider
is the Synology DS923+ Git Server package with a private SSH bare repository,
pending the required NAS IP/DNS, SSH port, volume/share/repository path, and
account inputs. Do not designate an in-cluster Git service as the canonical
source. See [Synology DS923+ follow-up setup](SYNOLOGY.md) for the Git setup,
key separation, host-key pinning, recovery tests, and deferred NFS RWX plan.

When selected, Flux may reconcile applications and UI routing from that remote.
Keep cluster bootstrap and frozen versions in `group_vars/all.yml` separate from
post-baseline application configuration.

Synology DS923+ NFS CSI is also deferred. A future GitOps deployment must use
the upstream NFS CSI driver and keep it a non-default RWX StorageClass alongside
Longhorn with TBD inputs.
