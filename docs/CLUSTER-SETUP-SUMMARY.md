# Cluster setup summary

## Baseline architecture

The clean-slate cluster runs Ubuntu 26.04 ARM64 from USB SSD root on five nodes.
It has three schedulable K3s servers (`pi-ctl-01`–`pi-ctl-03`) and two agents
(`pi-wrk-01`, `pi-wrk-02`). kube-vip presents API VIP `192.168.1.40`; node
addresses are `192.168.1.41` through `.45`.

K3s uses `/var/lib/rancher/k3s`. There is no data migration, separate SSD
mount, or `/var` bind-mount configuration.

Longhorn uses bridge-CNI `storage-network`, `/var/lib/longhorn`, two replicas,
and only `pi-ctl-03`, `pi-wrk-01`, and `pi-wrk-02`. Monitoring uses
`vmsingle-stable`; Grafana credentials come from vaulted `grafana-admin`.
External Secrets Operator can reconcile application Secrets from a dedicated
1Password vault after `05-secrets.yml`; its bootstrap token remains outside
Git and Flux.

Synology DS923+ NFS CSI is deferred as non-default RWX storage alongside
Longhorn, with its inputs TBD. The canonical Git remote must be off-cluster and
its final location is TBD.
