# Deployment checklist

## Before bootstrap

- [ ] Five Ubuntu 26.04 ARM64 nodes boot directly from USB SSD root.
- [ ] `docs/RPI-EEPROM.md` is complete on each node: packaged EEPROM firmware
  reviewed, effective `BOOT_ORDER=0xF41`, and two cold boots succeed from the
  intended USB SSD with the SD card removed.
- [ ] Inventory has servers `pi-ctl-01`–`pi-ctl-03` at `.41`–`.43` and agents
  `pi-wrk-01`/`pi-wrk-02` at `.44`/`.45`.
- [ ] kube-vip API address is `192.168.1.40`.
- [ ] SSH, sudo, and the Ansible vault password work from the control host.
- [ ] Frozen versions in `group_vars/all.yml` have been reviewed.

## Deploy in order

- [ ] Run `01-infra-prep.yml`; confirm every node remains reachable over SSH.
- [ ] Confirm `br-storage` exists on every node.
- [ ] Run `02-k3s-install.yml`; `NotReady` nodes before Cilium are expected.
- [ ] Join `pi-ctl-02` with `k3s-add-master.yml --limit pi-ctl-02 --forks=1`;
  verify etcd membership and health.
- [ ] Join `pi-ctl-03` with `k3s-add-master.yml --limit pi-ctl-03 --forks=1`;
  verify all three etcd members are healthy.
- [ ] Run `03-addons.yml`; verify Cilium, Multus, Whereabouts, Longhorn, and Traefik.
- [ ] Run `04-monitoring.yml`; verify monitoring and alerting.
- [ ] Prepare the dedicated 1Password vault/service account, set
  `onepassword_vault_id`, and run `05-secrets.yml` from a trusted terminal.
- [ ] Confirm the `onepassword` ClusterSecretStore reports Ready without
  printing or decoding any Secret.
- [ ] Confirm NAS `home-gitops` `main` contains the reviewed public Flux source
  manifest, then run `06-flux.yml`.
- [ ] Confirm the `flux-system` GitRepository and root Kustomization are Ready
  from `http://nas.home.ftmon.org:3000/dsheehan/home-gitops.git`.
- [ ] Run `./scripts/verify-cluster.sh`.

## Baseline acceptance

- [ ] All three servers and two agents are Ready through API VIP `192.168.1.40`.
- [ ] Longhorn uses `/var/lib/longhorn`, two replicas, and only `pi-ctl-03`,
  `pi-wrk-01`, and `pi-wrk-02`.
- [ ] The Longhorn `storage-network` NAD is bridge CNI and `br-storage` is up.
- [ ] `vmsingle-stable` has ready endpoints.
- [ ] Grafana uses the vaulted `grafana-admin` Secret.
- [ ] No NFS CSI StorageClass is the default.

Do not rerun `02-k3s-install.yml` after the cluster is live. For membership
changes, use add/remove playbooks with `--limit`; add servers one at a time.
Synology DS923+ NFS CSI remains deferred until post-baseline as non-default RWX
storage alongside Longhorn.
