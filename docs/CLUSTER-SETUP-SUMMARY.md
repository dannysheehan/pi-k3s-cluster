# Pi K3s Cluster - Final Configuration Summary

This document summarizes the final working configuration of the Raspberry Pi K3s cluster.

## Cluster Architecture

### Nodes
- **Control Plane**: k3s-ctl-01 (192.168.1.41)
- **Workers**: k3s-wrk-01/02/03 (192.168.1.42-44)
- **Storage Network**: 192.168.10.41-44 (dedicated 10Gbps USB Ethernet)
- **Scheduling Policy**: Control plane is tainted `NoSchedule`; Longhorn storage scheduling is worker-only

### Network Layout

#### Primary Network (192.168.1.0/24)
- **Control Plane**: 192.168.1.41-44 (Nodes)
- **LoadBalancer Pool**: 192.168.1.200-201 (Cilium L2)
  - 192.168.1.200: Traefik (Ingress + Gateway API)
  - 192.168.1.201: Available

#### Storage Network (192.168.10.0/24)
- **Nodes**: 192.168.10.41-44
- **Dynamic Pool**: 192.168.10.45-254 (Whereabouts IPAM)
- **Purpose**: Longhorn replication traffic only
- **Routing**: No gateway; addresses are statically assigned on an isolated L2 segment

## Installed Components

### Core Kubernetes
- **K3s**: v1.30.x
- **Container Runtime**: containerd
- **Data Directory**: /mnt/ssd/k3s (USB SSD)

### Networking
- **Cilium**: v1.16.4
  - eBPF-based kube-proxy replacement
  - L2 LoadBalancer announcements
  - Hubble observability (UI + metrics)
- **Multus**: v4.1.3
  - Multi-network interface support
- **Whereabouts**: v0.7.0
  - IPAM for secondary networks

### Storage
- **Longhorn**: v1.7.2
  - Distributed block storage
  - 3-replica default
  - Storage path: /mnt/ssd/longhorn
  - Dedicated storage network via node IP annotations (see Storage Network section)

### Ingress
- **Traefik**: v30.1.0
  - Dual-mode: IngressRoute (Traefik CRD) + Gateway API
  - LoadBalancer IP: 192.168.1.200
  - Dashboard enabled (port-forward)
  - Prometheus metrics enabled

### Monitoring (Optional)
- **Victoria Metrics**: Lightweight monitoring stack (no CRDs, 3x less memory)
  - VMSingle (7-day retention, 10Gi storage) - replaces Prometheus
  - VMAgent (metrics scraper, 256Mi request / 512Mi limit)
  - Grafana (2Gi storage, accessible at /grafana)
  - Node Exporter (DaemonSet)
- **Scrape Targets**: K3s API, Kubelet, Longhorn, Traefik, Cilium, Hubble
- **Pre-configured Dashboards** (100% PromQL compatible):
  - Node Exporter Full (ID: 1860)
  - Kubernetes Cluster Overview (ID: 7249)
  - Longhorn (ID: 16888)
  - Traefik (ID: 17346)
  - Cilium Agent (ID: 16611)
  - Hubble (ID: 16612)

## Key Features

### 1. Dual-Mode Traefik
Traefik supports both Traefik IngressRoute and modern Gateway API on the same LoadBalancer IP:

**IngressRoute (Traefik CRD):**
```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: my-app
  namespace: my-namespace
spec:
  entryPoints:
    - web
  routes:
  - match: Host(`myapp.local`)
    kind: Rule
    services:
    - name: my-app
      port: 80
```

**Gateway API:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
spec:
  parentRefs:
  - name: traefik-gateway
  hostnames:
  - "myapp.local"
  rules:
  - backendRefs:
    - name: my-app
      port: 80
```

Both accessed via: `curl -H "Host: myapp.local" http://192.168.1.200`

### 2. Cilium L2 LoadBalancer
- Replaces K3s's Klipper LoadBalancer
- Provides external IPs via L2 ARP announcements
- No external load balancer required
- IP pool: 192.168.1.200-201 (2 IPs)

### 3. Dedicated Storage Network
- Longhorn uses node storage IPs for replication traffic
- Each node has a br-storage bridge interface (192.168.10.41-45)
- Replication traffic isolated from application traffic
- 10Gbps USB Ethernet for high throughput
- **Configuration**: Node annotations with `longhorn.io/storage-ip`
- **Implementation**: Multus `bridge` attachment on `br-storage` plus Longhorn `storage-ip` annotations
- **Node Scope**: Longhorn data scheduling is intentionally limited to worker nodes; the control plane is reserved for cluster services
- **Controller Scope**: Longhorn CSI controller deployments are intended to run on workers; the CSI node plugin may still run on the control plane as a DaemonSet

## Configuration Files

### Ansible Playbooks
1. **01-infra-prep.yml**: Infrastructure preparation
   - Time sync configuration
   - USB SSD formatting and mounting
   - Storage network bridge setup
   - cgroups enablement

2. **02-k3s-install.yml**: K3s installation
   - Control plane with embedded etcd
   - Worker nodes
   - Custom flags (no Flannel, no kube-proxy, no Traefik)
   - Kubeconfig fetch and update

3. **03-addons.yml**: Cluster add-ons
   - Cilium CNI with L2 announcements
   - Multus + Whereabouts (pinned versions)
   - Longhorn with Multus storage network and node storage IP annotations
   - Traefik with Gateway API

4. **04-monitoring.yml**: Monitoring stack (optional)
   - Victoria Metrics (VMSingle + VMAgent) - lightweight alternative to Prometheus
   - Grafana with pre-configured dashboards
   - Node Exporter for host metrics
   - Scrape configs for Longhorn, Traefik, Cilium, Hubble
   - Traefik IngressRoute for Grafana access at /grafana

### Test Files
- **`../tests/test-longhorn.yml`**: Longhorn storage test
- **`../tests/test-traefik-ingress.yml`**: Traefik IngressRoute test
- **`../tests/test-gateway-api.yml`**: Gateway API test

## Access Points

### Kubeconfig
```bash
export KUBECONFIG=~/.kube/config-rpi
kubectl get nodes
```

### Grafana (Monitoring Dashboards)
```bash
# Direct access via Traefik IngressRoute
# http://192.168.1.200/grafana
# Username: admin, Password: admin
```

### Victoria Metrics (Metrics Database)
```bash
kubectl port-forward -n monitoring svc/vmsingle-victoria-metrics-single-server 8428:8428
# http://localhost:8428
```

### Hubble UI (Network Observability)
```bash
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
# http://localhost:12000
```

### Traefik Dashboard
```bash
kubectl port-forward -n traefik svc/traefik 9000:9000
# http://localhost:9000/dashboard/
```

### Longhorn UI
```bash
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
# http://localhost:8080
```

## Troubleshooting Tips

### Nodes Not Ready
- Wait for Cilium to be fully deployed
- Check: `kubectl get pods -n kube-system -l k8s-app=cilium`

### LoadBalancer Pending
- Verify Cilium L2 resources exist:
  ```bash
  kubectl get ciliumloadbalancerippool
  kubectl get ciliuml2announcementpolicy
  ```

### Longhorn Not Starting
- Check node storage IP annotations:
  ```bash
  kubectl get nodes.longhorn.io -n longhorn-system -o jsonpath='{range .items[*]}{.metadata.name}: {.metadata.annotations.longhorn\.io/storage-ip}{"\n"}{end}'
  ```
- Verify nodes have br-storage interface with correct IP:
  ```bash
  ssh ubuntu@192.168.1.41 ip addr show br-storage
  ```
- Check Longhorn volumes and engines:
  ```bash
  kubectl get volumes.longhorn.io -n longhorn-system
  kubectl get engines.longhorn.io -n longhorn-system
  ```
- If storage network issues persist, verify the `storage-network` setting is configured:
  ```bash
  kubectl get settings.longhorn.io storage-network -n longhorn-system -o jsonpath='{.value}'
  # Should be longhorn-system/storage-network
  ```

### Gateway API Not Working
- Ensure Gateway uses correct ports (8000/8443):
  ```bash
  kubectl get gateway -A
  ```
- Check HTTPRoute status:
  ```bash
  kubectl describe httproute <name> -n <namespace>
  ```

## Maintenance

### Update Kubeconfig
```bash
kubectl config use-context default --kubeconfig=~/.kube/config-rpi
```

### Scale Worker Nodes
```bash
# Add new worker to hosts.ini
ansible-playbook 02-k3s-install.yml --limit new-worker
```

### Update Components
```bash
# Update Cilium
helm upgrade cilium cilium/cilium --version <new-version> --namespace kube-system --reuse-values

# Update Traefik
helm upgrade traefik traefik/traefik --version <new-version> --namespace traefik --reuse-values

# Update Longhorn
helm upgrade longhorn longhorn/longhorn --version <new-version> --namespace longhorn-system --reuse-values
```

## Performance Notes

- **Cilium eBPF**: ~20% better network performance vs kube-proxy
- **Storage Network**: Dedicated 10Gbps reduces impact on application traffic
- **USB SSD**: 10x faster than SD card for etcd and container storage
- **L2 LoadBalancer**: No external dependencies, instant IP allocation

## Security Considerations

- All components run with default RBAC
- Storage network is isolated from primary network
- Traefik dashboard requires port-forward (not exposed publicly)
- Kubeconfig has 600 permissions

## Future Enhancements

- [ ] Add cert-manager for automatic TLS certificates
- [ ] Configure Longhorn backups to external storage
- [x] Set up Prometheus + Grafana for monitoring (04-monitoring.yml)
- [ ] Implement NetworkPolicies with Cilium
- [ ] Add external DNS integration
