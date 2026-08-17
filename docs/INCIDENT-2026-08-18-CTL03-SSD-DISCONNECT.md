# Incident Report: pi-ctl-03 USB SSD Disconnect Recurrence

Date: 2026-08-18  
Status: Mitigated (software); hardware replacement still open  
Severity: High  
Affected services: `pi-ctl-03` (etcd voter, schedulable server, Longhorn
storage node), Longhorn replica rebuilds during recovery

## Summary

`pi-ctl-03` dropped its USB SSD off the bus again. This is the same failure
class as `docs/INCIDENT-2026-06-30-WRK01-SSD-DISCONNECT.md` (then `k3s-wrk-01`
and a five-day-later recurrence on `k3s-wrk-04`): the USB-SATA bridge
disappears, the node stops posting status, and only a physical power cycle
brings the disk back.

The node had already been power-cycled and cordoned when investigation
started around 07:48 AEST. SMART on the Phison 120 GB drive still passed.
The 2026-07-05 decision to leave UAS enabled was reversed: Ubuntu tryboot
cmdlines now disable UAS and USB autosuspend for the fleet's `0930:1400`
bridges.

## Impact

- `pi-ctl-03` left the schedulable set (`Ready,SchedulingDisabled`) until
  after the software reboot at 08:15 AEST (Ready `lastTransitionTime`
  `2026-08-17T22:15:26Z`).
- The node is an etcd voter and one of three Longhorn storage nodes
  (`pi-ctl-03`, `pi-wrk-01`, `pi-wrk-02`). Quorum held because `pi-ctl-01`
  and `pi-ctl-02` stayed up. Longhorn volumes stayed available from the
  remaining replicas and later rebuilt.
- The disconnect dmesg from this event was not recovered. The host had
  already rebooted (13 minutes uptime at 07:55 AEST), so the ring buffer
  only showed a clean USB enumeration. That matches the June incident:
  local kernel evidence dies with the disk.

## Detection

Reported manually as another SSD failure on `pi-ctl-03`. The node was
reachable over SSH after the operator power cycle.

```text
kubectl get nodes
  pi-ctl-03   Ready,SchedulingDisabled   control-plane,etcd

hostname / uptime
  pi-ctl-03   up 13 min   kernel 7.0.0-1009-raspi
  (siblings were on 7.0.0-1016-raspi)
```

`vcgencmd get_throttled` was `0x0` after recovery. Pi-side undervoltage
since that boot is not indicated.

## Root Cause

Same class as June 2026: the USB-SATA bridge left the bus and needed VBUS
removed to recover. The NAND is not the failing part.

Live hardware on `pi-ctl-03` after recovery, identical to the rest of the
fleet:

```text
Raspberry Pi 4 Model B Rev 1.1
ID 0930:1400 Toshiba Corp. "Memory Stick 2GB" / TOSHIBA USB DRV
Driver=uas, 5000M
Phison OEM 120 GB SATA SSD, firmware SBFM61.3
SMART PASSED, 97% life left, 0 CRC, 0 SATA PHY errors
Unsafe_Shutdown_Count 123 of 126 power cycles
Storage NIC on USB 2 (D-Link DUB-1312); SSD on USB 3
VL805 000138c0 and bootloader 2026-01-09, both current
usbcore.autosuspend=2 (kernel default)
weekly fstrim.timer enabled
root mounted relatime, not noatime
```

The spoofed Toshiba identity is a cheap bridge, not a real Toshiba device.
Pi 4 USB current is a hard 1.2 A aggregate across all ports; each node
already powers an SSD plus a gigabit USB NIC from that budget. A larger
USB-C brick does not raise that cap.

The June write-up left UAS enabled because there were no `uas_eh` /
`reset SuperSpeed` signatures and only one drop in 216 days. Recurrence
on `pi-ctl-03` (after wrk-01 and wrk-04 on the previous build) is the
revisit trigger that report described.

## Recovery Actions

1. Confirmed the recovered node: USB SSD present, SMART passing, k3s
   active, node cordoned.
2. Identified Ubuntu 26.04's tryboot cmdline as
   `/boot/firmware/current/cmdline.txt` (and `new/` when present). The
   leftover `/boot/firmware/cmdline.txt` only holds
   `cfg80211.ieee80211_regdom=AU` and is not the kernel command line.
3. Added day-2 playbook `k3s-tune-usb-ssd.yml` and shared tasks in
   `tasks/tune-usb-ssd.yml`, also included from `01-infra-prep.yml`.
4. Applied software tunables on `pi-ctl-03`, then rebooted. After boot:

   ```text
   usb-storage.quirks=0930:1400:u
   usbcore.autosuspend=-1
   usb 2-1: UAS is ignored for this device, using usb-storage instead
   Driver=usb-storage, 5000M
   / mounted rw,noatime
   fstrim.timer masked
   ```

5. Rolled the same change to `pi-ctl-01`, `pi-ctl-02`, `pi-wrk-01`, and
   `pi-wrk-02`, one node at a time: drain, playbook with
   `usb_ssd_reboot=true`, wait for Ready, uncordon. On the Longhorn
   workers, waited until all four volumes were `attached/healthy` before
   touching the next node.
6. Left EEPROM, PSU, cables, powered hub, and enclosure replacement as
   operator hardware work. Ansible does not update bootloader EEPROM.

## Verification

```text
kubectl get nodes                 -> all 5 Ready
lsusb -t on every node            -> Mass Storage Driver=usb-storage, 5000M
dmesg                             -> UAS is ignored for this device
Longhorn volumes                  -> 4/4 attached, robustness healthy
```

## Prevention

### Done — software tunables

```bash
uv run ansible-playbook k3s-tune-usb-ssd.yml --limit <node>
uv run ansible-playbook k3s-tune-usb-ssd.yml --limit <node> -e usb_ssd_reboot=true
```

Drain first on a live node. The playbook writes:

- `usb-storage.quirks=0930:1400:u` and `usbcore.autosuspend=-1` on
  `/boot/firmware/current/cmdline.txt` (and `new/` if staged)
- udev rule `/etc/udev/rules.d/99-usb-ssd-autosuspend.rules`
- `noatime` on the `LABEL=writable` root ext4 fstab line, remounted live
- `fstrim.timer` and `fstrim.service` masked

The UAS quirk only binds after reboot. flash-kernel copies
`current/cmdline.txt` to `new/` on kernel updates, so the quirk survives
tryboot A/B.

Cost: BOT instead of UAS (less sequential throughput, TRIM usually
stops working). That is an acceptable trade for USB-root etcd and
Longhorn.

### Still open — hardware

Software reduces UAS and autosuspend races. It does not fix a bridge
that hangs until VBUS is pulled.

1. Official Pi 4 5.1 V / 3 A USB-C PSU (table stakes; does not raise the
   1.2 A USB-A cap).
2. Short, thick USB 3 cable; no coupler.
3. Self-powered USB 3 hub for the SSD, especially on Longhorn nodes.
4. Replace the `0930:1400` caddies with ASM1153E (StarTech
   `USB312SAT3CB` is the usual known-good). Keep the Phison drives.
   Do not buy RTL9210 NVMe enclosures for these SATA disks.
5. Structural: Pi 5 / CM5 + NVMe HAT removes USB-SATA from the root
   path. See finding B1 in `docs/BEST-PRACTICES-REVIEW-2026-07.md`.

## Follow-Up Tasks

- [x] Apply UAS quirk + autosuspend disable on `pi-ctl-03` and reboot.
- [x] Roll the same tunables to the other four nodes, drained one at a
      time.
- [x] Confirm `Driver=usb-storage` and Longhorn `attached/healthy`.
- [x] Add `k3s-tune-usb-ssd.yml` and include it from `01-infra-prep.yml`.
- [ ] Replace the `0930:1400` enclosure (and cable) on `pi-ctl-03` first,
      then the other Longhorn nodes.
- [ ] Confirm official PSUs and consider a powered USB 3 hub on storage
      nodes.
- [ ] Keep EEPROM `USB_MSD_PWR_OFF_TIME` as a manual `RPI-EEPROM.md`
      experiment if warm reboot leaves a disk dark. It does not stop a
      mid-run bus drop.

## Related Documentation

- `docs/INCIDENT-2026-06-30-WRK01-SSD-DISCONNECT.md`
- `docs/BEST-PRACTICES-REVIEW-2026-07.md` (B1)
- `docs/RPI-EEPROM.md`
- `docs/TROUBLESHOOTING.md`
- `docs/OPERATIONS.md`
- `k3s-tune-usb-ssd.yml`
