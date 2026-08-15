# Runbooks

## Rebuild baseline

This is a clean-slate operation: there is no migration or retained-data path.
Install Ubuntu 26.04 ARM64 directly to each node's USB SSD root, configure the
USB-first EEPROM and cold-boot checks in `RPI-EEPROM.md`, configure the
inventory addresses (`pi-ctl-01`–`03`, `pi-wrk-01`–`02`), then run:

```bash
uv run ansible-playbook 01-infra-prep.yml
uv run ansible-playbook 02-k3s-install.yml
uv run ansible-playbook k3s-add-master.yml --limit pi-ctl-02 --forks=1
# Verify etcd before joining the next server.
uv run ansible-playbook k3s-add-master.yml --limit pi-ctl-03 --forks=1
uv run ansible-playbook 03-addons.yml
uv run ansible-playbook 04-monitoring.yml
uv run ansible-playbook 05-secrets.yml
./scripts/verify-cluster.sh
```

The API VIP is `192.168.1.40`. K3s
nodes remain `NotReady` until Cilium is installed. K3s uses its default
`/var/lib/rancher/k3s` data directory.

## Replace or add a node

Do not rerun bootstrap against a live cluster. For an intentional membership
change, update inventory and use the dedicated playbook. Add servers one at a
time.

```bash
uv run ansible-playbook k3s-add-master.yml --limit pi-ctl-03 --forks=1
uv run ansible-playbook k3s-add-worker.yml --limit pi-wrk-02
uv run ansible-playbook k3s-remove-worker.yml --limit pi-wrk-02 -e wipe_data=true
```

Before removing a Longhorn storage node, move or recover volumes and verify
replica health. Longhorn data is `/var/lib/longhorn`, replica count is two, and
the permitted storage nodes are `pi-ctl-03`, `pi-wrk-01`, and `pi-wrk-02`.

## Restore control-plane data

Treat etcd restoration as an incident requiring a current, tested snapshot and
a maintenance window. Stop K3s on the affected server and follow the K3s
version-matched restore procedure using snapshots under
`/var/lib/rancher/k3s/server/db/snapshots`.

## Post-baseline work

Synology DS923+ NFS CSI is deferred. Introduce it only after baseline
verification as a non-default RWX StorageClass beside Longhorn, once endpoint,
export, and credentials are decided. Maintain an off-cluster canonical Git
remote; its location is TBD.
