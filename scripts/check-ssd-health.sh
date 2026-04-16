#!/usr/bin/env bash

set -euo pipefail

TARGET="${1:-}"
DEVICE="${2:-}"

if [[ -z "$TARGET" ]]; then
  echo "Usage: $0 <ssh-target> [device]" >&2
  echo "Example: $0 192.168.1.45 /dev/sdb" >&2
  exit 1
fi

if [[ -n "$DEVICE" ]]; then
  REMOTE_DEVICE="$DEVICE"
else
  REMOTE_DEVICE=''
fi

ssh "$TARGET" "SSD_DEVICE=$REMOTE_DEVICE bash -s" <<'EOF'
set -euo pipefail

device="${SSD_DEVICE:-}"
mount_source="$(findmnt -n -o SOURCE /mnt/ssd 2>/dev/null || true)"

if [[ -z "$device" ]]; then
  case "$mount_source" in
    UUID=*)
      device="$(blkid -U "${mount_source#UUID=}" 2>/dev/null || true)"
      ;;
    /dev/*)
      device="$mount_source"
      ;;
  esac
fi

printf '== Host ==\n'
hostname
date

printf '\n== Mounted SSD ==\n'
findmnt /mnt/ssd || true
lsblk -o NAME,MAJ:MIN,TRAN,SIZE,FSTYPE,MODEL,SERIAL,UUID,MOUNTPOINTS

if [[ -n "$device" ]]; then
  printf '\n== blkid %s ==\n' "$device"
  blkid "$device" || true
fi

printf '\n== Recent Disk/USB Errors ==\n'
sudo dmesg -T | egrep -i 'I/O error|blk_update|buffer i/o|EXT4-fs error|reset (SuperSpeed|high-speed) USB device|uas|usb-storage|sd[a-z]|scsi|rejecting I/O' | tail -120 || true

if ! command -v smartctl >/dev/null 2>&1; then
  sudo apt-get update -qq && sudo apt-get install -y smartmontools
fi

if command -v smartctl >/dev/null 2>&1 && [[ -n "$device" ]]; then
  printf '\n== SMART %s ==\n' "$device"
  sudo smartctl -d scsi -a "$device" || true
else
  printf '\n== SMART ==\n'
  echo "smartctl unavailable or SSD device could not be resolved"
fi

if [[ -f /etc/systemd/system/k3s-agent.service ]]; then
  printf '\n== k3s-agent ==\n'
  systemctl is-active k3s-agent || true
  journalctl -u k3s-agent -n 80 --no-pager || true
elif [[ -f /etc/systemd/system/k3s.service ]]; then
  printf '\n== k3s (server) ==\n'
  systemctl is-active k3s || true
  journalctl -u k3s -n 80 --no-pager || true
else
  printf '\n== k3s ==\n'
  echo "Neither k3s nor k3s-agent service found"
fi
EOF