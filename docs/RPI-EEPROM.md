# Raspberry Pi USB boot preflight

Complete this manual hardware gate on every Raspberry Pi before running
Ansible. The cluster assumes Ubuntu 26.04 boots directly from the USB SSD;
Ansible deliberately does not update bootloader EEPROM firmware.

Keep physical access, a known-good Raspberry Pi OS recovery SD card, and a
copy of the original EEPROM configuration available. Update and test one Pi at
a time. Do not remove power while an EEPROM update is being applied.

## Inspect and update the bootloader

Boot a supported Raspberry Pi OS maintenance image when the installed Ubuntu
image does not provide the `rpi-eeprom` tools. Use the distribution package;
do not download an unreviewed firmware image or script.

```bash
sudo apt update
sudo apt install rpi-eeprom
rpi-eeprom-update
rpi-eeprom-config
```

Save the output with the node's hardware record. If `rpi-eeprom-update`
reports an available update, review it and deliberately schedule the packaged
stable release:

```bash
sudo rpi-eeprom-update -a
sudo reboot
rpi-eeprom-update
```

Do not update all five nodes together. Confirm that the rebooted node is
healthy before proceeding to the next one.

## Set SD-first recovery, then USB boot

Edit the latest packaged bootloader configuration:

```bash
sudo -E EDITOR=nano rpi-eeprom-config --edit
```

Set this value, leaving unrelated settings unchanged:

```text
BOOT_ORDER=0xF41
```

Raspberry Pi evaluates `BOOT_ORDER` from right to left: `1` tries the SD card,
`4` then tries USB mass storage, and `F` restarts the sequence. With no SD
card present the Pi boots its USB SSD normally. Inserting the known-good
recovery SD makes it take precedence without another EEPROM edit. Reboot to
apply the pending EEPROM image, then read back the effective value:

```bash
sudo reboot
rpi-eeprom-update
rpi-eeprom-config | grep '^BOOT_ORDER='
```

The expected result is `BOOT_ORDER=0xF41` (the tool may display hexadecimal
letters in lower case). If it differs, stop and correct the
EEPROM configuration before imaging or bootstrapping the cluster.

## Prove SSD-root boot

Shut the Pi down, remove the SD card, and cold boot from the USB SSD. Verify
the root filesystem and transport rather than relying on the device name:

```bash
findmnt -n -o SOURCE,FSTYPE,OPTIONS /
lsblk -o NAME,MODEL,SERIAL,TRAN,FSTYPE,MOUNTPOINTS
```

Perform two successful cold boots with the SD card absent. Accept the node
only when `/` is backed by the intended USB SSD, SSH is reachable, and the
USB storage and network adapters remain stable. Insert the recovery SD only
for deliberate maintenance; SD-first ordering makes that card an explicit
recovery override, while normal cluster operation must not depend on it.

See the official Raspberry Pi
[bootloader configuration documentation](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-bootloader-configuration)
and the upstream [`rpi-eeprom` repository](https://github.com/raspberrypi/rpi-eeprom)
before changing additional EEPROM settings.
