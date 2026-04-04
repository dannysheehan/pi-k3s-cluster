# Upgrading Components

This guide covers upgrade procedures for each major component.
Always check the [compatibility matrix](#compatibility-matrix) before upgrading.

## Compatibility Matrix

| K3s Version | Cilium Version  | Longhorn Version |
|-------------|-----------------|------------------|
| v1.29.x     | 1.15.x          | 1.6.x            |
| v1.30.x     | 1.15.x, 1.16.x | 1.6.x, 1.7.x    |
| v1.31.x     | 1.16.x          | 1.7.x            |

Always check official compatibility documentation:
- [Cilium Kubernetes Compatibility](https://docs.cilium.io/en/stable/network/kubernetes/compatibility/)
- [Longhorn Kubernetes Compatibility](https://longhorn.io/docs/latest/deploy/important-notes/)

---

## Upgrading K3s

### Option 1: Manual Upgrade

**Important**: Always upgrade the control plane first, then workers.

#### Step 1: Upgrade Control Plane

```bash
# SSH to control plane node
ssh ubuntu@192.168.1.41

# Check current version
k3s --version

# Upgrade K3s (replace version as needed)
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<new-version> sh -s - server \
  --cluster-init \
  --data-dir /mnt/ssd/k3s \
  --flannel-backend=none \
  --disable-network-policy \
  --disable-kube-proxy \
  --disable servicelb

# Verify upgrade
k3s --version
kubectl get nodes
```

#### Step 2: Upgrade Worker Nodes

```bash
# SSH to each worker node (repeat for each worker)
ssh ubuntu@192.168.1.42

# Upgrade K3s agent
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<new-version> \
  K3S_URL=https://192.168.1.41:6443 \
  K3S_TOKEN=<node-token> sh -s - \
  --data-dir /mnt/ssd/k3s

# Verify on control plane
kubectl get nodes
```

### Option 2: Automated Upgrade with System Upgrade Controller

The System Upgrade Controller automates rolling upgrades across the cluster.

#### Install System Upgrade Controller

```bash
export KUBECONFIG=~/.kube/config-rpi

kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/latest/download/system-upgrade-controller.yaml

kubectl -n system-upgrade wait --for=condition=available deployment/system-upgrade-controller --timeout=120s
```

#### Create Upgrade Plans

Create `k3s-upgrade-plan.yaml`:

```yaml
---
# Control Plane Upgrade Plan
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: k3s-server
  namespace: system-upgrade
  labels:
    k3s-upgrade: server
spec:
  concurrency: 1
  cordon: true
  nodeSelector:
    matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
  serviceAccountName: system-upgrade
  upgrade:
    image: rancher/k3s-upgrade
  version: <new-version>
---
# Worker Node Upgrade Plan
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: k3s-agent
  namespace: system-upgrade
  labels:
    k3s-upgrade: agent
spec:
  concurrency: 1
  cordon: true
  nodeSelector:
    matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: DoesNotExist
  prepare:
    args:
      - prepare
      - k3s-server
    image: rancher/k3s-upgrade
  serviceAccountName: system-upgrade
  upgrade:
    image: rancher/k3s-upgrade
  version: <new-version>
```

Apply and monitor:

```bash
kubectl apply -f k3s-upgrade-plan.yaml
watch kubectl get nodes
kubectl -n system-upgrade get plans
```

### Rollback K3s

```bash
# SSH to the affected node and reinstall the previous version
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<previous-version> sh -s - server \
  --cluster-init \
  --data-dir /mnt/ssd/k3s \
  --flannel-backend=none \
  --disable-network-policy \
  --disable-kube-proxy \
  --disable servicelb
```

---

## Upgrading Cilium

### Pre-upgrade Checklist

```bash
export KUBECONFIG=~/.kube/config-rpi

kubectl -n kube-system exec ds/cilium -- cilium version
kubectl -n kube-system exec ds/cilium -- cilium status
```

### Upgrade via Helm

```bash
helm repo update

helm search repo cilium/cilium --versions

helm upgrade cilium cilium/cilium --version <new-version> \
  --namespace kube-system \
  --reuse-values

kubectl -n kube-system rollout status daemonset/cilium

# Verify
kubectl -n kube-system exec ds/cilium -- cilium version
kubectl -n kube-system exec ds/cilium -- cilium status
```

### Rollback Cilium

```bash
helm history cilium -n kube-system
helm rollback cilium <revision-number> -n kube-system
```

---

## Upgrading Longhorn

### Pre-upgrade Checklist

```bash
export KUBECONFIG=~/.kube/config-rpi

kubectl -n longhorn-system get daemonset longhorn-manager -o jsonpath='{.spec.template.spec.containers[0].image}'

# Ensure all volumes are healthy before upgrading
kubectl -n longhorn-system get volumes.longhorn.io

# Create a backup of critical volumes before upgrading
```

### Upgrade via Helm

```bash
helm repo update

helm search repo longhorn/longhorn --versions

helm upgrade longhorn longhorn/longhorn --version <new-version> \
  --namespace longhorn-system \
  --reuse-values

kubectl -n longhorn-system rollout status daemonset/longhorn-manager

kubectl -n longhorn-system get pods
```

### Rollback Longhorn

```bash
helm history longhorn -n longhorn-system
helm rollback longhorn <revision-number> -n longhorn-system
```

---

## Upgrading Multus and Whereabouts

These are deployed via pinned manifests in `03-addons.yml`, with a repo-local
post-install patch applied to `kube-multus-ds`. Upgrade by changing the version
variable in `group_vars/all.yml` and reapplying the playbook — do **not** apply
raw upstream manifests by hand:

```bash
ansible-playbook 03-addons.yml --tags multus,whereabouts
```
