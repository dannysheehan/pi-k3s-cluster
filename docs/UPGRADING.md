# Upgrading

Versions are frozen in `group_vars/all.yml`. Change and review one component
version there, then run only its relevant playbook tag after validating the
upstream compatibility notes.

## K3s

Take and verify an etcd snapshot first. Upgrade servers one at a time, then
agents, retaining quorum throughout. The cluster has three schedulable servers
(`pi-ctl-01`–`03`) behind API VIP `192.168.1.40`. Do not use
`02-k3s-install.yml` as a live-cluster upgrade mechanism. K3s data remains at
`/var/lib/rancher/k3s`.

## Add-ons and monitoring

Upgrade Cilium before dependent networking changes. Preserve Cilium/Multus
coexistence and the bridge `storage-network`. For Longhorn, preserve the
`/var/lib/longhorn` data path, two replicas, and storage-node restriction to
`pi-ctl-03`, `pi-wrk-01`, and `pi-wrk-02`.

For monitoring, validate vmagent and vmalert connectivity to
`vmsingle-stable` after upgrades. Grafana credentials remain managed through
the vaulted `grafana-admin` Secret.

Synology DS923+ NFS CSI is deferred and is not an upgrade prerequisite.
