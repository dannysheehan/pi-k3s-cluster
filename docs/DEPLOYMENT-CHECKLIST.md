# Pi K3s Cluster - Deployment Checklist

This checklist ensures all components are properly configured and functioning.

## Pre-Deployment

### Hardware
- [ ] 4x Raspberry Pi 4 (8GB RAM recommended)
- [ ] 4x USB SSDs (connected and detected)
- [ ] 4x USB Ethernet adapters for storage network
- [ ] Network cables connected to appropriate switches
- [ ] Power supply adequate for all components

### Software
- [ ] Ubuntu Server 24.04 LTS 64-bit installed on all nodes
- [ ] SSH key-based authentication configured
- [ ] Static IP addresses assigned (192.168.1.41-44)
- [ ] Storage network IPs configured (192.168.10.41-44)
- [ ] Ansible installed on control machine
- [ ] Python 3 available on all nodes
- [ ] `helm diff` plugin installed on control machine

### Inventory Configuration
- [ ] `hosts.ini` updated with correct IP addresses
- [ ] `master_ip` variable set correctly
- [ ] `storage_network_range` set correctly if not using `192.168.10.0/24`
- [ ] `ssd_device_override` set if needed for specific nodes
- [ ] Ansible can connect: `ansible all -m ping`

## Deployment Steps

### 1. Infrastructure Preparation
```bash
ansible-playbook 01-infra-prep.yml
```

**Verification:**
- [ ] All nodes show "Reboot" in PLAY RECAP (or already had cgroups)
- [ ] After reboot, SSH reconnects successfully
- [ ] USB SSDs mounted: `ansible all -a "df -h /mnt/ssd"`
- [ ] Storage network: `ansible all -a "ip addr show br-storage"`

### 2. K3s Installation
```bash
ansible-playbook 02-k3s-install.yml
```

**Verification:**
- [ ] K3s service running on all nodes: `ansible all -a "systemctl status k3s"`
- [ ] Kubeconfig fetched to `~/.kube/config-rpi`
- [ ] Kubeconfig server address points to 192.168.1.41 (not 127.0.0.1)
- [ ] All nodes show Ready: `kubectl get nodes --kubeconfig ~/.kube/config-rpi`

### 3. Cluster Add-ons
```bash
ansible-playbook 03-addons.yml
```

**Verification:**
- [ ] Cilium pods running: `kubectl get pods -n kube-system -l k8s-app=cilium`
- [ ] Hubble relay running: `kubectl get pods -n kube-system -l k8s-app=hubble-relay`
- [ ] Multus DaemonSet ready: `kubectl get ds -n kube-system kube-multus-ds`
- [ ] Whereabouts DaemonSet ready: `kubectl get ds -n kube-system whereabouts`
- [ ] Longhorn pods running: `kubectl get pods -n longhorn-system`
- [ ] Traefik pod running: `kubectl get pods -n traefik`
- [ ] Traefik has LoadBalancer IP: `kubectl get svc -n traefik traefik`
  - Expected: EXTERNAL-IP = 192.168.1.200

## Post-Deployment Testing

### LoadBalancer Functionality
```bash
kubectl get svc -n traefik traefik
# Should show EXTERNAL-IP: 192.168.1.200
```
- [ ] External IP assigned
- [ ] IP is from pool 192.168.1.200-201
- [ ] Ping responds: `ping 192.168.1.200`

### Cilium Network
```bash
kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy
```
- [ ] IPPool shows 2 IPs available
- [ ] L2AnnouncementPolicy exists
- [ ] Cilium status healthy: `cilium status` (if CLI installed)

### Storage Network
```bash
kubectl get network-attachment-definitions -n longhorn-system
kubectl exec -n longhorn-system <longhorn-pod> -- ip addr
```
- [ ] NetworkAttachmentDefinition `storage-network` exists
- [ ] Longhorn pods have net1 interface (192.168.10.x)
- [ ] Longhorn `storage-network` setting is `longhorn-system/storage-network`

### Traefik IngressRoute Test
```bash
kubectl apply -f ../tests/test-traefik-ingress.yml
curl -H "Host: hello.local" http://192.168.1.200
```
- [ ] Test app deploys successfully
- [ ] IngressRoute created
- [ ] Curl returns "hello from <pod-name>"
- [ ] Multiple curls show load balancing (different pod names)

### Gateway API Test
```bash
kubectl apply -f ../tests/test-gateway-api.yml
curl -H "Host: traefik-gw.local" http://192.168.1.200
```
- [ ] Gateway status shows Accepted: True
- [ ] HTTPRoute status shows Accepted: True
- [ ] Curl returns "hello from <pod-name>"
- [ ] Multiple curls show load balancing

### Longhorn Storage Test
```bash
kubectl apply -f ../tests/test-longhorn.yml
kubectl get pvc -n test-longhorn
kubectl exec -n test-longhorn longhorn-test -- df -h /data
```
- [ ] PVC bound successfully
- [ ] Pod running
- [ ] Volume mounted at /data
- [ ] Longhorn UI accessible (port-forward on 8080)

## Service Access

### Hubble UI (Network Observability)
```bash
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
```
- [ ] UI loads at http://localhost:12000
- [ ] Network flows visible
- [ ] Can filter by namespace/pod

### Traefik Dashboard
```bash
kubectl port-forward -n traefik svc/traefik 9000:9000
```
- [ ] Dashboard loads at http://localhost:9000/dashboard/
- [ ] Shows routers for Ingress
- [ ] Shows routers for Gateway API

### Longhorn UI
```bash
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
```
- [ ] UI loads at http://localhost:8080
- [ ] Shows 4 nodes
- [ ] Shows volumes (if any created)
- [ ] All nodes schedulable

## Troubleshooting Common Issues

### Cilium Pods Not Starting
**Symptom:** Cilium DaemonSet not ready
**Check:**
```bash
kubectl logs -n kube-system -l k8s-app=cilium --tail=50
```
**Solution:** Usually resolves after waiting 2-3 minutes for initialization

### LoadBalancer Stuck Pending
**Symptom:** Traefik service shows `<pending>` for EXTERNAL-IP
**Check:**
```bash
kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy
```
**Solution:** Ensure both resources exist; may need to recreate Traefik service

### Longhorn Pods CrashLoopBackOff
**Symptom:** Longhorn pods restarting constantly
**Check:**
```bash
kubectl logs -n longhorn-system <longhorn-pod> -c longhorn-manager
kubectl get network-attachment-definitions -n longhorn-system
```
**Solution:** Verify storage network configuration and br-storage interface exists on all nodes

### Pods Stuck In ContainerCreating
**Symptom:** New workloads never leave `ContainerCreating`
**Check:**
```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl get events -A --sort-by=.lastTimestamp | tail -50
```
**Solution:** If events show `FailedCreatePodSandBox`, verify Multus/Whereabouts rollout, `/etc/cni/net.d` on each node, and confirm Cilium remained healthy after the secondary-network install.

### Gateway API Not Working
**Symptom:** 404 or connection refused on Gateway API host
**Check:**
```bash
kubectl describe gateway traefik-gateway -n test-traefik-gateway
kubectl describe httproute hello-route -n test-traefik-gateway
kubectl logs -n traefik deployment/traefik
```
**Solution:** Ensure Gateway uses ports 8000/8443, not 80/443

### Nodes Not Ready
**Symptom:** `kubectl get nodes` shows NotReady
**Check:**
```bash
kubectl describe node <node-name>
journalctl -u k3s -n 100
```
**Solution:** Usually waiting for Cilium; check Cilium logs

### Namespace Stuck Terminating (test-traefik)
**Symptom:** `Error ... namespace ... is being terminated`
**Check:**
```bash
kubectl get ns test-traefik -o json | jq '.spec.finalizers'
```
**Fix:** Remove finalizers to force deletion, then reapply:
```bash
kubectl get ns test-traefik -o json | jq 'del(.spec.finalizers)' > /tmp/ns.json
kubectl replace --raw "/api/v1/namespaces/test-traefik/finalize" -f /tmp/ns.json
kubectl apply -f ../tests/test-traefik-ingress.yml
```
If jq is unavailable, edit the JSON to remove `spec.finalizers` and run the same replace command.

## Cleanup (If Needed)

### Remove Test Applications
```bash
kubectl delete -f ../tests/test-traefik-ingress.yml
kubectl delete -f ../tests/test-gateway-api.yml
kubectl delete -f ../tests/test-longhorn.yml
```

### Uninstall K3s (Destructive!)
```bash
ansible all -a "/usr/local/bin/k3s-uninstall.sh" -b
```

### Reset Infrastructure
```bash
# Unmount SSDs
ansible all -a "umount /mnt/ssd" -b
# Remove from fstab manually if needed
```

## Success Criteria

✅ **Cluster is fully operational when:**
- All nodes show Ready status
- All system pods running (Cilium, Multus, Longhorn, Traefik)
- LoadBalancer IP assigned to Traefik (192.168.1.200)
- Both Ingress and Gateway API routing working
- Longhorn storage functional with storage network
- Hubble UI accessible and showing network flows

## Next Steps After Deployment

1. **Set default kubeconfig**: 
   ```bash
   export KUBECONFIG=~/.kube/config-rpi
   # Or add to ~/.bashrc
   ```

2. **Deploy applications**: Use either Ingress or Gateway API for routing

3. **Configure monitoring**: Use `04-monitoring.yml` for the VictoriaMetrics-based stack

4. **Setup backups**: Configure Longhorn backup targets

5. **TLS certificates**: Install cert-manager for automatic HTTPS

6. **External access**: Configure router port forwarding if needed
