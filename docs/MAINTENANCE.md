# Maintenance

Routine maintenance procedures for the Raspberry Pi K3s cluster.

## Backup etcd (Control Plane Data)

```bash
# K3s automatically creates snapshots in /mnt/ssd/k3s/server/db/snapshots
ssh ubuntu@192.168.1.41
sudo ls -lh /mnt/ssd/k3s/server/db/snapshots/

# Manual snapshot
sudo k3s etcd-snapshot save --name manual-backup-$(date +%Y%m%d)
```

## Restore from etcd Snapshot

```bash
# Stop K3s
sudo systemctl stop k3s

# Restore snapshot
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/mnt/ssd/k3s/server/db/snapshots/<snapshot-name>

# Start K3s
sudo systemctl start k3s
```

## Monitor SD Card Health

SD card writes should be minimal since `/var` and K3s data are offloaded to SSD.

```bash
ssh ubuntu@192.168.1.41
iostat -x 1 5
```

## Check SSD Health

```bash
sudo apt install smartmontools
sudo smartctl -a /dev/sda
```

## Storage Usage

### Create a PersistentVolumeClaim

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 5Gi
```

```bash
kubectl apply -f pvc.yaml
kubectl get pvc
```
