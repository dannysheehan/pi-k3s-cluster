# Design

## Goals

This repository defines a repeatable clean-slate K3s baseline, not a migration.
It runs five Ubuntu 26.04 ARM64 Raspberry Pi nodes from USB SSD root and keeps
component versions frozen in `group_vars/all.yml`.

## Control plane and scheduling

Three schedulable K3s servers (`pi-ctl-01`, `pi-ctl-02`, `pi-ctl-03`) provide
embedded-etcd quorum. Two agents (`pi-wrk-01`, `pi-wrk-02`) provide capacity.
kube-vip exposes API VIP `192.168.1.40`; node addresses are `.41` through `.45`.
K3s uses `/var/lib/rancher/k3s`. The bootstrap playbook is initial creation
only; day-2 server additions use the dedicated playbook one server at a time.

## Storage

Longhorn is the baseline default block store. Its data path is
`/var/lib/longhorn`, replica count is two, and its storage nodes are
`pi-ctl-03`, `pi-wrk-01`, and `pi-wrk-02`.

A USB Ethernet-backed `br-storage` bridge precedes Multus. Longhorn
`storage-network` deliberately uses bridge CNI, not ipvlan: host-namespace
iSCSI traffic cannot reliably reach an ipvlan-attached pod on the same host.

Synology DS923+ NFS CSI is deferred. Once introduced, it will be a non-default
RWX StorageClass alongside Longhorn; endpoint, export, and credentials are TBD.

## Networking and observability

Cilium is the primary CNI and must coexist with Multus. VictoriaMetrics clients
use `vmsingle-stable`; VictoriaLogs requires Fluent Bit field `_msg`. Grafana
administration comes from vaulted `grafana-admin`, with no default credentials.

## GitOps

The canonical Git repository must remain off-cluster. Its location and Flux
bootstrap inputs are TBD. An in-cluster Git service is not the source of truth.
