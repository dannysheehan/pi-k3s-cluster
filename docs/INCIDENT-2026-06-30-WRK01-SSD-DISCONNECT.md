# Incident Report: k3s-wrk-01 USB SSD Disconnect And 4.5-Day Node Outage

Date: 2026-06-30 (detected 2026-07-05)  
Status: Resolved  
Severity: High  
Affected services: k3s-wrk-01 (all workloads), Longhorn replicas on that node,
node-level logging and metrics for that node

## Summary

The USB SSD backing `/mnt/ssd` on `k3s-wrk-01` dropped off the USB bus entirely
at approximately 23:02 AEST on 2026-06-30 and never re-enumerated. The kernel
deleted the `sda` block device, but the `/mnt/ssd` mount and the `/var` bind
mount on top of it continued to reference the ghost device, so every read and
write returned `EIO`:

```text
EXT4-fs warning (device sda): dx_probe:823: inode #4194309: lblock 0:
  comm k3s: error -5 reading directory block
attempt to access beyond end of device
sda: rw=12288, sector=218170368, nr_sectors = 8 limit=0
```

`k3s-agent` crash-looped (its data dir `/mnt/ssd/k3s` was gone), the node went
`NotReady`, and the outage was not noticed for approximately 4.5 days because
no alerting exists for `NotReady` nodes.

## Impact

- `k3s-wrk-01` was `NotReady` from 2026-06-30 23:05 until 2026-07-05.
- All pods on the node were rescheduled or lost; Longhorn had to serve volumes
  from replicas on other nodes and later rebuild the node's replicas.
- SSH logins to the node were extremely slow because PAM, systemd, and journald
  all blocked on dead `/var` I/O.
- Local forensic evidence was destroyed by the failure itself:
  - The dmesg ring buffer was flooded by repeating ext4 errors, rotating out
    the original USB disconnect event.
  - The persistent journal lives on `/var` (on the dead SSD), so journald
    corrupted its journal and reset — only entries from the day of recovery
    survived.
- A reboot in this state would have hung into emergency mode: the fstab entry
  `/dev/sda /mnt/ssd ext4 defaults,noatime 0 0` had no `nofail`, and the
  `/var` bind mount depended on it.

## Detection

Reported manually as "node has lost the /mnt/ssd mount". No alert fired.

Initial checks showed the mount apparently present but the device gone:

```text
findmnt /mnt/ssd        -> /dev/sda ext4 rw,noatime   (ghost mount)
lsblk                   -> no sda; only mmcblk0 (SD) and sdb (Longhorn iSCSI)
lsusb                   -> no mass-storage device; USB 3.0 bus empty
ls /sys/block/          -> no sda
```

The failure time was recovered from the control plane, not the node:

```text
kubectl describe node k3s-wrk-01
  Ready  Unknown  LastHeartbeat 2026-06-30 23:02:57  Transition 23:05:15
  Reason: NodeStatusUnknown - Kubelet stopped posting node status
```

Corroborated by `/dev/disk/by-uuid/` directory mtime on the node:
`Jun 30 23:07` (when the SSD's UUID symlink was removed).

## Root Cause

The USB-SATA bridge disappeared from the USB bus at the hardware level and did
not re-enumerate until physically power-cycled. The exact trigger was not
proven — the disconnect event was lost with the local logs (see Impact).
Plausible causes: bridge firmware hang (common on JMicron/ASMedia bridges under
UAS), cable/connector fault, or drive-side power issue.

Pi-side power was ruled out: `vcgencmd get_throttled` returned `0x0` after 27
days of uptime, meaning no under-voltage was ever detected since boot.

## Contributing Factors

- The fstab entry used the unstable device name `/dev/sda` instead of the
  filesystem UUID. The node was provisioned before `01-infra-prep.yml` was
  updated to mount by UUID (commit 5421c41) and was never re-run.
- No `nofail` / device timeout on the `/mnt/ssd` entry: any reboot with the
  drive absent would have dropped the node into emergency mode, requiring
  console access.
- The `/var` bind mount had no dependency on `/mnt/ssd` being mounted, risking
  a silent bind onto the empty SD-card stub directory.
- Persistent journald storage lives on the SSD, so node-local logs die with
  the disk. Kernel logs were not shipped off-node.
- No alerting on node `NotReady` or on `node_filesystem_device_error`, so a
  hard node failure went unnoticed for 4.5 days.
- The filesystem UUID was unrecoverable while the drive was offline (superblock
  unreadable, `/dev/disk/by-uuid` symlink removed, `/run/blkid` cache had only
  the SD card, no Ansible fact caching configured), which blocked converting
  the fstab entry to UUID until after physical recovery.

## Recovery Actions

1. Confirmed via SSH that `/mnt/ssd` was a ghost mount: device absent from
   `lsusb`, `lsblk`, and `/sys/block`, with continuous `EIO` in the kernel log.
2. Established the failure timestamp (2026-06-30 23:02) from the Kubernetes
   node conditions, since local logs were lost.
3. Ruled out Pi under-voltage (`vcgencmd get_throttled` = `0x0`).
4. Hand-edited `/etc/fstab` on the node (backup at `/etc/fstab.bak-2026-07-05`)
   to make it reboot-safe before any power-cycle:

   ```text
   /dev/sda /mnt/ssd ext4 defaults,noatime,nofail,x-systemd.device-timeout=10s 0 0
   /mnt/ssd/var /var none bind,nofail,x-systemd.requires-mounts-for=/mnt/ssd 0 0
   ```

   Ran `systemctl daemon-reload` and verified both mount units downgraded from
   hard requirements to `WantedBy=local-fs.target`, with `var.mount` gaining
   `RequiresMountsFor=/mnt/ssd`.
5. Updated `01-infra-prep.yml` so the playbook writes the same options
   (`nofail,x-systemd.device-timeout=10s` on the SSD mount;
   `nofail,x-systemd.requires-mounts-for=/mnt/ssd` on the `/var` bind) and does
   not regress the hand fix on re-run.
6. Physically power-cycled the drive / rebooted the node. The SSD
   re-enumerated on the USB bus.
7. Re-ran `01-infra-prep.yml` on all nodes, converting the fstab entry to the
   real UUID and standardizing the new mount options fleet-wide:

   ```text
   UUID=92646951-6ab1-4683-855a-68380018686c /mnt/ssd ext4 defaults,noatime,nofail,x-systemd.device-timeout=10s 0 0
   ```

8. Verified Longhorn rebuilt the node's replicas and all volumes returned to
   `attached/healthy`, and that the node CR retained the `storage-network` tag.
9. Waited out the transient vmagent remote-write backlog (~1.9 GiB) that
   accumulated while `vmsingle` was rescheduled during the reboots; confirmed
   it was draining at ~1 MB/s rather than stuck.

## Verification

Post-recovery checks showed:

```text
kubectl get nodes                 -> all 5 nodes Ready (incl. k3s-wrk-01)
lsblk on k3s-wrk-01               -> sda (usb, 111.8G) mounted at /mnt/ssd
grep ssd /etc/fstab               -> UUID-based entry with nofail + timeout
longhorn volumes                  -> 3/3 attached, robustness healthy
longhorn node k3s-wrk-01          -> tags ["storage-network"], disk Ready=True
kubectl get pods -A               -> all Running (Grafana 3/3 after one
                                     slow-start probe restart)
vmagent_remotewrite_pending_data_bytes -> draining, ~30 min to clear
```

`./scripts/verify-cluster.sh` reported a single expected transient failure
(vmagent queue above threshold) at verification time.

## Prevention Recommendations

### 1. Mount By UUID With Boot-Safe Options Everywhere (Done)

`01-infra-prep.yml` now writes:

- `/mnt/ssd`: `defaults,noatime,nofail,x-systemd.device-timeout=10s`, source
  `UUID=...`
- `/var` bind: `bind,nofail,x-systemd.requires-mounts-for=/mnt/ssd`

This keeps a node bootable and reachable over SSH when its SSD is absent,
prevents `/dev/sdX` re-enumeration surprises (note: Longhorn iSCSI volumes also
appear as `sdX` on workers), and prevents `/var` from silently binding to the
SD card. Rolled out to all nodes on 2026-07-05. Note the `/var` bind task
notifies the Reboot handler, so future fleet rollouts of mount-option changes
should be done one node at a time with `--limit`.

### 2. Alert On Node NotReady

This outage lasted 4.5 days without detection. Add a vmalert rule such as:

```text
kube_node_status_condition{condition="Ready",status!="true"} == 1 for 5m
up{job=~".*node-exporter.*"} == 0 for 5m
```

### 3. Alert On Filesystem Device Errors

`node_filesystem_device_error{mountpoint="/mnt/ssd"} == 1` fires the moment a
filesystem starts erroring — hours or days before workloads visibly fail. Add
it as a critical alert and as a check in `./scripts/verify-cluster.sh`.

### 4. Ship Kernel Logs Off-Node

Node-local logs die with the SSD, which is exactly when they are needed.
Ensure Fluent Bit tails `/dev/kmsg` (or `journalctl -k`) so USB disconnect and
ext4 error events reach VictoriaLogs even when local journald storage is dead.

### 5. Check The USB-SATA Bridge For Known UAS Issues (Done — No Quirk Applied)

Surveyed on 2026-07-05 after recovery. All five nodes use the identical
bridge, which reports spoofed generic descriptors:

```text
ID 0930:1400 Toshiba Corp. "Memory Stick 2GB" / "TOSHIBA USB DRV"
Driver=uas, 5000M
```

Behind the bridge: Phison-driven OEM 120 GB SATA SSDs (firmware SBFM61.3),
SMART accessible via `smartctl -d sat`. The bridge is not one of the
known-problematic JMicron/ASMedia chips and is not in the kernel's
`unusual_uas` quirk table.

Decision: do **not** apply `usb-storage.quirks=0930:1400:u` at this time.
Evidence does not implicate the UAS driver — zero `uas_eh`/USB-reset events in
the kernel logs of all five nodes (27+ days uptime on the healthy ones, and
none on k3s-wrk-01 since recovery), and exactly one bus-drop in 216 days of
cluster operation. Forcing BOT mode would cost command queueing (Longhorn
replication throughput) fleet-wide for no demonstrated benefit.

Revisit if disconnects recur: swap the cable/enclosure on the affected node
first (hardware is the more likely culprit), and only reach for the quirk if
UAS error signatures (`uas_eh_abort_handler`, repeated `reset SuperSpeed`)
actually appear in the shipped kernel logs.

### 6. Schedule SMART / SSD Health Checks

Run `./scripts/check-ssd-health.sh` on a schedule (cron or smartd) to catch
pre-failure indicators. Run it now against the recovered drive on
`k3s-wrk-01` — a drive that drops off the bus once may be failing.

## Follow-Up Tasks

- [x] Make `/etc/fstab` on k3s-wrk-01 reboot-safe before physical recovery.
- [x] Update `01-infra-prep.yml` mount options (SSD + `/var` bind).
- [x] Re-run `01-infra-prep.yml` on all nodes (UUID mounts fleet-wide).
- [x] Verify Longhorn replica health and node tags after recovery.
- [x] Add checks for node `NotReady` and `node_filesystem_device_error` —
      implemented in `scripts/verify-cluster.sh` (the cluster runs no vmalert
      or Alertmanager, matching how the 2026-06-04 incident's alert items were
      completed). A true paging path would require deploying vmalert plus a
      notification receiver — still an open decision.
- [x] Confirm Fluent Bit ships kernel logs (`/dev/kmsg`) to VictoriaLogs —
      it did not (container logs only). Added a `kmsg` input to the Fluent
      Bit config in `04-monitoring.yml`, shipped as `job=kernel-logs` with a
      `node` label. Requires `privileged: true`: the container device cgroup
      blocks `/dev/kmsg` even with CAP_SYSLOG (same approach as
      node-problem-detector). Verified logs flowing from all four workers.
      Note: the Fluent Bit DaemonSet does not run on the control-plane node
      (pre-existing; no control-plane toleration), so `k8s-ctl-01` kernel
      logs are still not shipped.
- [x] Identify the USB-SATA bridge chip and evaluate UAS quirks — bridge is
      `0930:1400` (spoofed Toshiba IDs, Phison OEM SSD behind it); no UAS
      errors on any node; decision: leave UAS enabled, no quirk (see
      Prevention Recommendation 5).
- [x] Run `./scripts/check-ssd-health.sh` against the recovered drive and
      decide whether to replace it preemptively — SMART PASSED, 97% life
      left, zero read/PHY/CRC errors, no error log entries; decision: keep
      the drive, monitor. (Also fixed the script to use `smartctl -d sat`:
      the `0930:1400` bridges return no ATA attributes under `-d scsi`.)
- [x] Remove `/etc/fstab.bak-2026-07-05` on k3s-wrk-01 (contents preserved in
      this report's Recovery Actions).
- [x] Re-run `./scripts/verify-cluster.sh` after the vmagent queue drains —
      all checks pass, queue at 0 bytes (2026-07-05).

## Related Documentation

- `docs/RUNBOOKS.md`
- `docs/TROUBLESHOOTING.md`
- `docs/MAINTENANCE.md`
- `docs/INCIDENT-2026-06-04-GRAFANA-DASHBOARDS.md`
