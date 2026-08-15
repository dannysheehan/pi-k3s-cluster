# Maintenance

## Secrets

Inline vault values in `group_vars/all.yml` include notification endpoints and
Grafana's admin password. The vault password is outside the repository at
`~/.ansible/vault-pass-pi-cluster`; back it up securely. Grafana uses the
vaulted `grafana-admin` Secret, so there are no documented default credentials.

## Storage and host health

Nodes boot directly from USB SSD root. Inspect the root filesystem and device
health with `findmnt /`, `lsblk`, `sensors`, `smartctl`, and kernel logs. K3s data is at
`/var/lib/rancher/k3s`; Longhorn data is at `/var/lib/longhorn` on
`pi-ctl-03`, `pi-wrk-01`, and `pi-wrk-02`.

Host preparation installs `lm-sensors` and `smartmontools`. Useful checks are:

```bash
cat /sys/class/thermal/thermal_zone0/temp  # divide by 1000 for °C
vcgencmd measure_temp                     # when vcgencmd is available
sensors
sudo smartctl -d scsi -a /dev/sda
sudo systemctl status pi-health-metrics.timer
cat /var/lib/node_exporter/textfile_collector/pi-health.prom
```

The health timer discovers the parent disk backing `/` unless
`pi_health_smart_device` overrides it. It defaults to `-d scsi` for the
cluster's USB bridges. Node exporter collects the resulting temperature and
SMART metrics; VMAlert warns at 75°C, becomes critical at 80°C, and alerts on
failed SMART health or collection.

## Container runtime diagnostics

Every K3s install and join path renders `/etc/crictl.yaml` for the bundled
containerd socket. Confirm runtime access without repeating endpoint flags:

```bash
uv run ansible-playbook k3s-configure-crictl.yml  # safe for an existing cluster
sudo crictl info
sudo crictl pods
sudo crictl pods -q | wc -l
sudo crictl images
```

The day-2 playbook does not install or restart K3s. Do not rerun
`02-k3s-install.yml` merely to configure `crictl`.

Retain and test etcd snapshots from
`/var/lib/rancher/k3s/server/db/snapshots`. Confirm Longhorn replica health
before host maintenance; volumes use two replicas.

## Scheduled checks

```bash
./scripts/verify-cluster.sh
```

Check VictoriaMetrics through `vmsingle-stable`, VictoriaLogs ingestion, and
the alert heartbeat as part of regular operations. NFS CSI for the Synology
DS923+ is deferred and should remain non-default when introduced.
