#!/usr/bin/env bash

set -euo pipefail

target="${1:-}"
requested_device="${2:-}"
smart_type="${3:-scsi}"

if [[ -z "$target" ]]; then
  echo "Usage: $0 <ssh-target> [device] [smartctl-device-type]" >&2
  echo "Example: $0 pi-wrk-02 /dev/sda scsi" >&2
  exit 1
fi

if [[ -n "$requested_device" && ! "$requested_device" =~ ^/dev/[a-zA-Z0-9._/-]+$ ]]; then
  echo "Device must be an absolute /dev path" >&2
  exit 1
fi
if [[ ! "$smart_type" =~ ^[a-zA-Z0-9,+_-]+$ ]]; then
  echo "Invalid smartctl device type" >&2
  exit 1
fi

ssh "$target" bash -s -- "$requested_device" "$smart_type" <<'EOF'
set -euo pipefail

device="${1:-}"
smart_type="${2:-scsi}"
root_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"

if [[ -z "$device" && -n "$root_source" ]]; then
  device="$(lsblk -sno PATH,TYPE "$root_source" 2>/dev/null | awk '$2 == "disk" { print $1; exit }')"
fi

printf '== Host ==\n'
hostname
date

printf '\n== Raspberry Pi temperature ==\n'
if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
  awk '{ printf "thermal_zone0: %.3f°C\n", $1 / 1000 }' /sys/class/thermal/thermal_zone0/temp
else
  echo 'thermal_zone0 is unavailable'
fi
if command -v vcgencmd >/dev/null 2>&1; then
  vcgencmd measure_temp || true
  vcgencmd get_throttled || true
fi
if command -v sensors >/dev/null 2>&1; then
  sensors || true
fi

printf '\n== Root filesystem and block devices ==\n'
findmnt /
lsblk -o NAME,MAJ:MIN,TRAN,SIZE,FSTYPE,MODEL,SERIAL,UUID,MOUNTPOINTS

printf '\n== Recent disk and USB errors ==\n'
sudo dmesg -T | grep -Ei 'I/O error|blk_update|buffer i/o|EXT4-fs error|reset (SuperSpeed|high-speed) USB device|uas|usb-storage|sd[a-z]|scsi|rejecting I/O' | tail -120 || true

printf '\n== SMART root disk ==\n'
if ! command -v smartctl >/dev/null 2>&1; then
  echo 'smartctl is unavailable; rerun 01-infra-prep.yml' >&2
elif [[ -z "$device" ]]; then
  echo 'Root disk could not be resolved; pass it explicitly, for example /dev/sda' >&2
else
  printf 'Running: smartctl -d %q -a %q\n' "$smart_type" "$device"
  sudo smartctl -d "$smart_type" -a "$device" || true
fi

if [[ -f /etc/systemd/system/k3s-agent.service ]]; then
  printf '\n== k3s-agent ==\n'
  systemctl is-active k3s-agent || true
  journalctl -u k3s-agent -n 80 --no-pager || true
elif [[ -f /etc/systemd/system/k3s.service ]]; then
  printf '\n== k3s ==\n'
  systemctl is-active k3s || true
  journalctl -u k3s -n 80 --no-pager || true
else
  printf '\n== k3s ==\n'
  echo 'Neither k3s nor k3s-agent service found'
fi
EOF
