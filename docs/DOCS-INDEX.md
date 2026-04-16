# Pi K3s Cluster - Documentation Index

This project deploys a production-ready Kubernetes cluster on Raspberry Pi hardware with custom networking and storage.

## 📚 Documentation Structure

### Quick Start
- **[README.md](../README.md)** - Main deployment guide
  - Architecture overview
  - Step-by-step deployment instructions
  - Testing procedures
  - Service access commands

- **[scripts/README.md](../scripts/README.md)** - Helper script usage
  - Quick cluster verification helper
  - Kubeconfig override pattern

### Reference Documents
- **[CLUSTER-SETUP-SUMMARY.md](CLUSTER-SETUP-SUMMARY.md)** - Final configuration reference
  - Complete architecture details
  - Network layout and IP assignments
  - Component versions and configurations
  - Access points and maintenance procedures

- **[OPERATIONS.md](OPERATIONS.md)** - Narrative architecture and day-2 operations guide
  - How the deployment layers fit together
  - Component responsibilities and dependencies
  - Safe rerun and upgrade patterns
  - Failure boundaries and operator mental model

- **[DEPLOYMENT-CHECKLIST.md](DEPLOYMENT-CHECKLIST.md)** - Deployment verification
  - Pre-deployment requirements checklist
  - Step-by-step verification procedures
  - Post-deployment testing guide
  - Troubleshooting common issues

- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** - Operator troubleshooting guide
  - Component overview and dependency map
  - Kubernetes commands for diagnosing each layer
  - Safe targeted reruns for common repairs

- **[RUNBOOKS.md](RUNBOOKS.md)** - Copy-paste recovery procedures
  - Common failure recovery steps
  - Focused repair commands by symptom
  - Safe verification after a fix

- **[UPGRADING.md](UPGRADING.md)** - Component upgrade procedures
  - K3s manual and automated upgrades
  - Cilium, Longhorn, Multus/Whereabouts upgrades
  - Compatibility matrix
  - Rollback procedures

- **[MAINTENANCE.md](MAINTENANCE.md)** - Routine maintenance
  - etcd backup and restore
  - SD card and SSD health monitoring
  - Storage usage examples

### Design Documents
- **[DESIGN.md](DESIGN.md)** - Original architectural design
  - Initial requirements and goals
  - Component selection rationale

- **[NMSTATE-EVALUATION.md](NMSTATE-EVALUATION.md)** - Future design note for Kubernetes NMState
  - Where NMState would fit in this cluster
  - Why it should be day-2 only, not bootstrap
  - Example policy and setting-by-setting rationale

- **[DESIGN-REVIEW.md](DESIGN-REVIEW.md)** - Design evolution notes
  - Changes from original design
  - Lessons learned during implementation

## 🚀 Quick Deployment

For experienced users, the complete deployment is:

```bash
# 1. Setup Python environment
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
ansible-galaxy install -r requirements.yml

# 2. Configure inventory
# Edit hosts.ini with your node IPs

# 3. Deploy cluster
ansible-playbook 01-infra-prep.yml
# Wait for reboot
ansible-playbook 02-k3s-install.yml
ansible-playbook 03-addons.yml

# 4. Verify
export KUBECONFIG=~/.kube/config-rpi
kubectl get nodes
kubectl get svc -n traefik traefik  # Should show 192.168.1.200
```

See [DEPLOYMENT-CHECKLIST.md](DEPLOYMENT-CHECKLIST.md) for detailed verification.

## 📖 Documentation Usage Guide

### For First-Time Deployment
1. Start with [README.md](../README.md) - Follow step-by-step instructions
2. Use [DEPLOYMENT-CHECKLIST.md](DEPLOYMENT-CHECKLIST.md) - Verify each step
3. Reference [CLUSTER-SETUP-SUMMARY.md](CLUSTER-SETUP-SUMMARY.md) - For troubleshooting

### For Understanding Architecture
1. Read [OPERATIONS.md](OPERATIONS.md) - How the live system fits together
2. Read [CLUSTER-SETUP-SUMMARY.md](CLUSTER-SETUP-SUMMARY.md) - Current architecture
3. Review [DESIGN.md](DESIGN.md) - Original design goals
4. Check [DESIGN-REVIEW.md](DESIGN-REVIEW.md) - Design evolution

### For Troubleshooting
1. Check [DEPLOYMENT-CHECKLIST.md](DEPLOYMENT-CHECKLIST.md) - Common issues section
2. Use [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Component relationships and diagnosis commands
3. Read [OPERATIONS.md](OPERATIONS.md) - Which layer to inspect first
4. Use [RUNBOOKS.md](RUNBOOKS.md) - Recovery steps when you already know the symptom
5. Reference [CLUSTER-SETUP-SUMMARY.md](CLUSTER-SETUP-SUMMARY.md) - Maintenance section
6. Review playbook comments in `*.yml` files - Implementation details

### For Maintenance
1. Use [CLUSTER-SETUP-SUMMARY.md](CLUSTER-SETUP-SUMMARY.md) - Update procedures
2. Reference [README.md](../README.md) - Service access commands

## 🔧 Ansible Playbooks

All playbooks include comprehensive header comments explaining their purpose and configuration.

### 01-infra-prep.yml
- **Purpose**: Prepares hardware infrastructure
- **What it does**:
  - Configures time synchronization
  - Formats and mounts USB SSDs
  - Sets up storage network bridge
  - Enables cgroups for Kubernetes
- **Duration**: ~5 minutes + reboot time
- **Verification**: `ansible all -a "df -h /mnt/ssd && ip addr show br-storage"`

### 02-k3s-install.yml
- **Purpose**: Installs K3s on all nodes
- **What it does**:
  - Installs K3s control plane with embedded etcd
  - Joins worker nodes
  - Disables default components (Flannel, Traefik, kube-proxy, servicelb)
  - Fetches and updates kubeconfig
- **Duration**: ~3 minutes
- **Verification**: `kubectl get nodes`

### 03-addons.yml
- **Purpose**: Installs networking, storage, and ingress stack
- **What it does**:
  - Installs Cilium CNI with Hubble and L2 LoadBalancer
  - Installs pinned Multus + Whereabouts for secondary networks
  - Installs Longhorn storage with dedicated `br-storage` network
  - Installs Traefik with dual-mode support (Ingress + Gateway API)
  - Installs Gateway API CRDs
- **Duration**: ~10 minutes (includes wait times)
- **Verification**: See [DEPLOYMENT-CHECKLIST.md](DEPLOYMENT-CHECKLIST.md)
- **Useful tags**: `cilium`, `multus`, `whereabouts`, `longhorn`, `traefik`

### 04-monitoring.yml
- **Purpose**: Installs the VictoriaMetrics-based monitoring stack
- **What it does**:
  - Enables Traefik metrics
  - Installs Node Exporter
  - Installs Victoria Metrics Single
  - Installs VMAgent
  - Installs Grafana and the `/grafana` route
- **Useful tags**: `vmsingle`, `vmagent`, `grafana`, `node_exporter`, `traefik_metrics`

## 🧪 Test Files

### `../tests/test-longhorn.yml`
Tests Longhorn distributed storage:
```bash
kubectl apply -f ../tests/test-longhorn.yml
kubectl get pvc -n test-longhorn  # Should show Bound
```

### `../tests/test-traefik-ingress.yml`
Tests Traefik IngressRoute (Traefik CRD provider):
```bash
kubectl apply -f ../tests/test-traefik-ingress.yml
curl -H "Host: hello.local" http://192.168.1.200
```

### `../tests/test-gateway-api.yml`
Tests Gateway API:
```bash
kubectl apply -f ../tests/test-gateway-api.yml
curl -H "Host: traefik-gw.local" http://192.168.1.200
```

## 📊 Cluster Architecture At-A-Glance

```
┌─────────────────────────────────────────────────────────┐
│                    Pi K3s Cluster                       │
├─────────────────────────────────────────────────────────┤
│                                                           │
│  Control Plane (192.168.1.41) + 3 Workers (.42-.44)     │
│                                                           │
│  ┌───────────────────────────────────────────────────┐  │
│  │ Networking (Cilium CNI)                           │  │
│  │  • eBPF kube-proxy replacement                    │  │
│  │  • L2 LoadBalancer (192.168.1.200-201)           │  │
│  │  • Hubble observability                           │  │
│  │  • Multi-network (Multus + Whereabouts)          │  │
│  └───────────────────────────────────────────────────┘  │
│                                                           │
│  ┌───────────────────────────────────────────────────┐  │
│  │ Storage (Longhorn)                                │  │
│  │  • 3-replica distributed storage                  │  │
│  │  • USB SSDs on all nodes                         │  │
│  │  • Dedicated storage network (192.168.10.0/24)   │  │
│  └───────────────────────────────────────────────────┘  │
│                                                           │
│  ┌───────────────────────────────────────────────────┐  │
│  │ Ingress (Traefik)                                 │  │
│  │  • IngressRoute (Traefik CRD) support             │  │
│  │  • Gateway API support                            │  │
│  │  • LoadBalancer IP: 192.168.1.200               │  │
│  └───────────────────────────────────────────────────┘  │
│                                                           │
└─────────────────────────────────────────────────────────┘
```

## 🎯 Key Features

- **Custom CNI**: Cilium with eBPF for high performance
- **No External Dependencies**: L2 LoadBalancer requires no external load balancer
- **Dual Ingress**: Support both Ingress and Gateway API on same IP
- **Fast Storage**: USB SSDs for etcd and persistent volumes
- **Isolated Storage Traffic**: Dedicated 10Gbps network for Longhorn
- **Observable**: Hubble UI for network flow visualization
- **Production Ready**: 3-replica storage, multi-node control plane capable

## 🛠️ Component Versions

| Component | Version | Purpose |
|-----------|---------|---------|
| K3s | v1.30+ | Kubernetes distribution |
| Cilium | 1.16.4 | CNI + LoadBalancer |
| Longhorn | 1.7.2 | Distributed storage |
| Traefik | 30.1.0 | Ingress controller |
| Multus | v4.1.3 | Multi-network CNI |
| Whereabouts | v0.7.0 | IPAM for secondary networks |
| Gateway API | 1.2.0 | Modern ingress standard |

## 📞 Getting Help

### Documentation Issues
- Check [DEPLOYMENT-CHECKLIST.md](DEPLOYMENT-CHECKLIST.md) troubleshooting section
- Review playbook comments (comprehensive inline documentation)
- Verify configuration in [CLUSTER-SETUP-SUMMARY.md](CLUSTER-SETUP-SUMMARY.md)

### Common Problems
1. **Nodes not ready**: Wait for Cilium (2-3 minutes)
2. **LoadBalancer pending**: Check Cilium L2 resources exist
3. **Longhorn or new pods stuck in `ContainerCreating`**: Verify Multus/Whereabouts host CNI state and `br-storage` configuration
4. **Gateway API not working**: Ensure Gateway uses ports 8000/8443

### Debug Commands
```bash
# Check Cilium
kubectl get pods -n kube-system -l k8s-app=cilium
kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy

# Check Longhorn
kubectl get pods -n longhorn-system
kubectl get network-attachment-definitions -n longhorn-system

# Check Traefik
kubectl get svc -n traefik traefik
kubectl logs -n traefik deployment/traefik

# Check Gateway API
kubectl get gateway -A
kubectl describe gateway <name> -n <namespace>
```

## 🔄 Maintenance

See [CLUSTER-SETUP-SUMMARY.md](CLUSTER-SETUP-SUMMARY.md) maintenance section for:
- Component update procedures
- Scaling worker nodes
- Backup configuration

## 📝 Contributing

When making changes:
1. Update relevant documentation files
2. Add/update comments in playbooks
3. Test deployment from scratch
4. Update [DEPLOYMENT-CHECKLIST.md](DEPLOYMENT-CHECKLIST.md) if needed

---

**Last Updated**: After successful deployment with all features operational
**Status**: ✅ Production Ready
