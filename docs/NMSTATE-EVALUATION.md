# NMState Evaluation for This Cluster

This note captures how the Kubernetes NMState CRDs could be used in this cluster in the future. It is intentionally separate from the active implementation. The current source of truth remains the Ansible playbooks and the operational docs.

## Summary

Kubernetes NMState would be useful here as a declarative controller for **host network state** after the cluster is already running.

It would **not** replace:

- Multus for secondary pod interfaces
- Whereabouts for IP address management on the secondary network
- Longhorn's use of the node `storage-ip` annotation

It **could** replace or supplement the current day-2 management of the `br-storage` host bridge that is initially configured by Ansible.

## Current Architecture

The current storage-network path has four distinct layers:

1. Host network:
   `01-infra-prep.yml` creates the `br-storage` Linux bridge and assigns the node's static storage IP.
2. Secondary CNI attachment:
   `03-addons.yml` installs Multus.
3. Secondary network IPAM:
   `03-addons.yml` installs Whereabouts.
4. Longhorn traffic selection:
   `03-addons.yml` creates the `storage-network` NetworkAttachmentDefinition and annotates Longhorn nodes with `longhorn.io/storage-ip`.

Relevant references:

- [01-infra-prep.yml](../01-infra-prep.yml)
- [03-addons.yml](../03-addons.yml)
- [DESIGN.md](DESIGN.md)
- [OPERATIONS.md](OPERATIONS.md)

## Where NMState Fits

NMState operates at the **host network layer**.

In this cluster, that means NMState could be used to declaratively manage:

- the existence of `br-storage`
- whether the bridge is `up`
- which physical NIC is attached to the bridge
- the static storage IP on the bridge
- bridge options like STP behavior
- future MTU, route, VLAN, or bond settings if the storage network evolves

That is below Multus and below the workloads. Multus would still attach pods to `br-storage`; NMState would only ensure the host-side bridge exists and is correct.

## What NMState Would Be Good For

### 1. Declarative ownership of `br-storage`

Today the bridge is created by writing a Netplan file in `01-infra-prep.yml`. NMState could represent the same intent as a Kubernetes policy and continuously reconcile it.

Why this is useful:

- host network intent becomes visible inside the cluster
- drift can be detected instead of assumed away
- day-2 network changes become easier to track and audit
- the same host-network design can be expressed as Kubernetes manifests

### 2. Day-2 network changes

NMState is stronger than one-time provisioning when you want to make live changes later, for example:

- change MTU on the storage network
- add a route
- add another bridge or VLAN for future workloads
- evolve the storage network without relying only on SSH and host-local config files

### 3. Observability and drift detection

NMState exposes CRDs that show:

- desired state
- per-node enactment status
- observed current network state

That is useful for diagnosing problems like:

- a node missing `br-storage`
- the wrong NIC attached to the bridge
- an incorrect storage IP
- a node that drifted after manual changes or OS updates

## What NMState Would Not Replace

### Multus

NMState does not attach extra pod interfaces. Multus is still required for multi-network pods.

### Whereabouts

NMState does not provide the pod IPAM behavior currently handled by Whereabouts.

### Longhorn `storage-ip`

Longhorn still needs the node's real storage address. NMState could ensure the node actually has the correct `br-storage` IP, but it does not remove the need for `longhorn.io/storage-ip`.

This is an important distinction in this cluster because Longhorn's networking constraints are about the host-reachable path, not just pod attachment semantics.

## Why NMState Should Not Replace Bootstrap

The most important architectural caution is timing.

The current implementation intentionally creates `br-storage` **before** Multus and Longhorn depend on it. That happens during infra prep, before the cluster add-ons are applied.

NMState only works after:

- K3s is already up
- the NMState operator is installed
- the CRDs and handler pods are running

That means NMState is not a good replacement for first-boot host networking in this repo. If the cluster is down or not yet installed, Ansible still needs to be able to restore the host bridge directly.

Recommended position:

- keep Ansible/Netplan for bootstrap and disaster recovery
- use NMState only for day-2 reconciliation after the cluster is healthy

## Recommended Adoption Model

The safest model for this repo would be:

1. Keep `01-infra-prep.yml` as the bootstrap source of truth for initial host networking.
2. Install NMState only after `02-k3s-install.yml` has completed and the cluster is stable.
3. Generate per-node `NodeNetworkConfigurationPolicy` resources from existing inventory values like `storage_ip` and `storage_mac`.
4. Use NMState to enforce and observe the host bridge over time.
5. Leave Multus, Whereabouts, and Longhorn's storage annotation flow unchanged.

This gives the operational benefits of NMState without creating a bootstrap dependency loop.

## Why Per-Node Policies Make More Sense Here

A single generic policy for all nodes sounds attractive, but this cluster has node-specific facts:

- each node has a different static `storage_ip`
- USB NIC identity may vary per node
- the current Ansible inventory already models per-node storage details

Because of that, **per-node NMState policies are the safer design**.

Benefits of per-node policies:

- exact node-to-IP mapping
- easier troubleshooting
- lower risk of accidentally applying the wrong static IP to the wrong host
- cleaner relationship with the existing inventory model

## Example Policy

Example `NodeNetworkConfigurationPolicy` for a single node:

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: br-storage-k3s-wrk-03
spec:
  nodeSelector:
    kubernetes.io/hostname: k3s-wrk-03
  desiredState:
    interfaces:
      - name: enx001122334455
        type: ethernet
        state: up
      - name: br-storage
        type: linux-bridge
        state: up
        ipv4:
          enabled: true
          dhcp: false
          address:
            - ip: 192.168.10.43
              prefix-length: 24
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: enx001122334455
```

## In-Depth Explanation of the Example Settings

### `apiVersion: nmstate.io/v1`

This selects the NMState API version.

Why it matters:

- NMState CRDs are versioned APIs.
- The installed operator and the manifest must agree.
- Using the stable API avoids drift across examples from different versions.

### `kind: NodeNetworkConfigurationPolicy`

This declares desired network state for one or more nodes.

Why it matters:

- this is the object the operator reconciles
- it represents desired host-network intent, not just a one-time command

### `metadata.name`

Example:

```yaml
metadata:
  name: br-storage-k3s-wrk-03
```

Why it matters:

- the name should describe ownership clearly
- for this repo, node-specific names are preferable because addresses are static and node-specific

### `spec.nodeSelector`

Example:

```yaml
nodeSelector:
  kubernetes.io/hostname: k3s-wrk-03
```

Why it matters:

- a static host IP should not be applied to multiple nodes
- exact node targeting reduces the chance of a bad policy affecting the wrong machine

### `desiredState.interfaces`

This is the actual network model being enforced.

Why it matters:

- the cluster depends on a real host bridge with a real physical port behind it
- interfaces are the correct unit of declaration for this storage-network design

### Physical interface block

Example:

```yaml
- name: enx001122334455
  type: ethernet
  state: up
```

Why each setting exists:

- `name`: identifies the real Linux NIC that backs the storage network
- `type: ethernet`: tells NMState this is a physical Ethernet interface
- `state: up`: ensures the NIC is administratively enabled

Why this block matters:

- the bridge is only useful if the actual USB NIC is present and up
- it makes the relationship between hardware and bridge explicit

### Bridge interface block

Example:

```yaml
- name: br-storage
  type: linux-bridge
  state: up
```

Why each setting exists:

- `name: br-storage`: preserves the current contract assumed elsewhere in the repo
- `type: linux-bridge`: tells NMState to manage a Linux bridge rather than an ordinary NIC
- `state: up`: ensures the bridge is available for host and pod traffic

Why this block matters:

- Multus currently expects the host bridge to be named `br-storage`
- the bridge is the anchor point for the storage-network NAD

### `ipv4.enabled: true`

Why it matters:

- the storage network in this repo is IPv4-based
- Longhorn annotations point at IPv4 storage addresses

### `ipv4.dhcp: false`

Why it matters:

- the current design uses static `storage_ip` values
- Longhorn and operations procedures benefit from stable node addresses
- DHCP would add churn and make troubleshooting harder

### `ipv4.address`

Example:

```yaml
address:
  - ip: 192.168.10.43
    prefix-length: 24
```

Why it matters:

- this is the actual node storage IP used on the dedicated network
- it should remain stable and predictable
- `/24` matches the current storage network design

Why the IP belongs on the bridge:

- in a bridge topology, the host IP is typically assigned to the bridge, not the enslaved port

### `bridge.options.stp.enabled: false`

Why it matters:

- this preserves the current bridge behavior from the Netplan config
- STP exists to prevent layer-2 forwarding loops on bridged networks
- a forwarding loop happens when there are multiple active paths between the same layer-2 segments and Ethernet frames can circulate indefinitely
- when that happens, broadcasts and unknown unicast traffic can multiply rapidly, causing a bridge network meltdown
- STP solves that by detecting redundant paths and putting some bridge ports into a blocking or listening state instead of forwarding immediately

Why that is usually unnecessary in this cluster:

- each node has a single dedicated USB Ethernet adapter connected to the storage network
- the host bridge `br-storage` is just the local software bridge that joins that one physical port with any local veth endpoints attached by Multus
- there is no intentional redundant path design here such as dual uplinks, multiple bridged ports on the same host, or a mesh of switches that could create a loop
- in other words, this bridge is being used as a simple attachment point, not as part of a more complex switching topology

Why disabling STP is reasonable here:

- if there is only one real external path off the host bridge, there is no loop for STP to protect against under normal design assumptions
- disabling STP avoids extra bridge state transitions and avoids relying on loop-prevention logic that is not buying much in this topology
- it keeps the storage bridge behavior aligned with the current Netplan configuration and operational expectations

What the tradeoff is:

- if the physical network were later changed to include redundant layer-2 paths, unmanaged switches wired in a loop, or multiple bridge member interfaces that could create alternate forwarding paths, then leaving STP disabled would become riskier
- the current recommendation only holds because this storage network is intentionally simple and isolated

How this relates to `forward-delay: 0` in the current Netplan:

- `forward-delay` is part of the normal bridge/STP state machine and affects how long ports wait in intermediate states before forwarding traffic
- in a design that does not depend on STP for loop prevention, keeping the bridge from spending time in those transitional states is consistent with the goal of immediate, predictable forwarding on the dedicated storage network
- that matches the current configuration in `01-infra-prep.yml`, where `stp: false` and `forward-delay: 0` are set together

### `bridge.port`

Example:

```yaml
port:
  - name: enx001122334455
```

Why it matters:

- this enslaves the physical NIC into the bridge
- without it, `br-storage` would exist but would not actually connect to the dedicated physical storage network

## Why Ansible Would Still Matter

Even with NMState, Ansible would still be useful for:

- initial bootstrap before Kubernetes exists
- disaster recovery when host networking must be restored out-of-band
- rendering node-specific policies from inventory variables

The likely long-term split of responsibility would be:

- Ansible: discover or store node-specific facts and bootstrap the host
- NMState: reconcile the host network continuously after the cluster is up

## Operational Risks

Host networking is higher risk than ordinary workload configuration.

A bad NMState policy can isolate a node from the cluster. Because of that, rollout should be conservative:

1. start with one worker node
2. validate enactment status
3. confirm `br-storage` and Longhorn behavior still match expectations
4. expand only after successful verification

Control-plane nodes should be treated more carefully than workers because a network mistake there has a higher recovery cost.

## Bottom Line

NMState is a reasonable future enhancement for this cluster if the goal is to make the `br-storage` host network declarative, observable, and continuously reconciled after bootstrap.

It is **not** a replacement for the current storage-network architecture. It is best viewed as a way to manage the host-side bridge more cleanly in day-2 operations while keeping:

- Ansible for bootstrap and recovery
- Multus for secondary pod interfaces
- Whereabouts for secondary-network IPAM
- Longhorn's node storage IP annotations
