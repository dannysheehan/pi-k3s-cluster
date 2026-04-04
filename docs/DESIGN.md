# **Architecting a Resilient and Automated ARM-Based Kubernetes Homelab**

> Note: This document captures the original design direction. The current implementation is defined by the Ansible playbooks and the operational docs in `../README.md` and `CLUSTER-SETUP-SUMMARY.md`, which now pin Multus/Whereabouts versions and use the current storage-network configuration.

## **Executive Summary: A Blueprint for Production-Grade Home Infrastructure**

This report provides a comprehensive architectural blueprint and step-by-step implementation guide for constructing a high-performance, resilient, and fully automated Kubernetes cluster using a fleet of four Raspberry Pi 4 8GB devices. The primary objective is to move beyond a simple experimental setup to a production-grade homelab environment that adheres to modern DevOps and Infrastructure as Code (IaC) principles.

The architecture employs a **Hybrid Storage Strategy** to balance cost and reliability. The **Ubuntu Server 24.04 LTS** operating system resides on the SD card, while all high-I/O operations—including system logs, the Kubernetes state, and persistent application storage—are physically offloaded to the attached USB SSDs. This approach mitigates the risk of SD card corruption caused by frequent write operations.

The network architecture is bifurcated to maximize performance: a primary network for control plane and application traffic, and a dedicated, physically separate storage network for high-bandwidth data replication. The Kubernetes layer is implemented using **K3s**, configured in a high-availability (HA) topology. **Cilium** serves as the primary CNI for advanced networking and load balancing, while **Multus CNI** manages the secondary storage interfaces. **Longhorn** provides distributed block storage, explicitly configured to utilize the dedicated storage network and the SSDs. The entire infrastructure is provisioned via **Ansible** and application delivery is managed through a **Flux CD** GitOps pipeline.

## **Part I: The Foundational Layer: Hardware Preparation and Storage Strategy**

The stability of the cluster relies on protecting the SD cards from write exhaustion. This section details the setup of the Hybrid Storage Strategy, ensuring that while the OS boots from the SD, the heavy lifting is done by the SSD.

### **1.1 Operating System Installation**

**Ubuntu Server 24.04 LTS (64-bit)** is the recommended choice for its stability and broad support.1

1. **Flash OS to SD Cards:** Use Raspberry Pi Imager to flash Ubuntu Server 24.04 LTS to the 32GB SD cards.
2. **Pre-configure:** Use the "Advanced Options" (gear icon) in the Imager to:
   * Enable SSH.
   * Set a hostname (e.g., k3s-ctl-01, k3s-wrk-1, k3s-wrk-2, k3s-wrk-3).
   * Configure a user (e.g., ubuntu) and password/keys.
   * Configure Wi-Fi (optional, wired Ethernet is strongly recommended).

### **1.2 SSD Preparation and I/O Offloading**

This is the most critical step for the hybrid strategy. We will format the SSDs and configure the system to mount them as the primary data stores, using **bind mounts** to seamlessly offload standard system directories like /var/log.

1. Format the SSD:
   Boot the Raspberry Pi with the SSD attached. Identify the drive (usually /dev/sda) and format it to ext4.
   ```bash
   sudo mkfs.ext4 /dev/sda1
   ```

2. Configure the Mount Point:
   Create a directory to serve as the root of your SSD storage (e.g., /mnt/ssd).
   ```bash
   sudo mkdir -p /mnt/ssd
   ```

3. Offload System Logs (/var/log):
   Moving /var/log to the SSD prevents system logging from wearing out the SD card.1
   * **Stop Logging Services:** `sudo systemctl stop rsyslog`
   * **Sync Data:** Copy existing logs to the SSD.
     ```bash
     sudo mount /dev/sda1 /mnt/ssd
     sudo mkdir -p /mnt/ssd/var_log
     sudo rsync -av /var/log/ /mnt/ssd/var_log/
     ```

   * **Clean Up:** (Optional) Delete old logs on the SD card to free space, leaving the directory structure intact.
4. Update /etc/fstab:
   Configure the system to mount the SSD and bind the log directory automatically at boot. Add the following lines to /etc/fstab:
   ```fstab
   # Mount USB SSD
   /dev/sda1       /mnt/ssd        ext4    defaults,noatime  0 2

   # Bind mount logs from SSD to system path
   /mnt/ssd/var_log  /var/log      none    defaults,bind     0 0
   ```

   *Note: noatime reduces write operations by not updating access times on files.*
5. Apply and Verify:
   Run `sudo mount -a`. Verify that /var/log is now writing to the SSD by creating a test file.

### **1.3 Network Configuration (Primary and Storage)**

We must standardize the network interfaces to support automation, especially for the dedicated storage network.

1. Standardize Secondary Interface Names:
   Identify the MAC address of your USB Ethernet adapter (storage network) using `ip link`. Create a Netplan configuration to rename this interface to eth1 on every node.
   **Example /etc/netplan/60-storage.yaml:**
   ```yaml
   network:
     version: 2
     ethernets:
       eth1:
         match:
           macaddress: "xx:xx:xx:xx:xx:xx" # Replace with node specific MAC
         set-name: eth1
         dhcp4: false
         addresses:
           - 192.168.10.51/24 # Storage IP (do not use 10.x.x.x to avoid CNI conflicts)
   ```

   Apply with `sudo netplan apply`.
2. **Primary Static IPs:** Ensure the built-in Ethernet (eth0) has a static IP reservation on your router (e.g., 192.168.1.41).

## **Part II: The Kubernetes Core: Distribution and Data Path Configuration**

### **2.1 Deployment Strategy**

We will use **K3s** for its efficiency.4 To fully implement the storage strategy, we will direct K3s to store *all* its data (container images, volumes, database) on the SSD.

### **2.2 Installing K3s with SSD Data Path**

The \--data-dir flag is the key to protecting your SD card. It redirects the entire K3s state (including the embedded etcd and containerd storage) to the SSD.5

Installation Command:
When running the installation script, use the following flags. Note the data-dir pointing to the mount created in Part 1\.

* \--data-dir /mnt/ssd/k3s: **Critical.** Writes all K8s data to the SSD.
* \--flannel-backend=none: Prepare for Cilium.
* \--disable-network-policy: Let Cilium handle policies.
* \--disable-kube-proxy: Let Cilium replace kube-proxy.
* \--disable servicelb: Disable default load balancer.

**Master Node 1 Example:**

```bash
# Create the directory on the SSD first
sudo mkdir -p /mnt/ssd/k3s

# Install
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --data-dir /mnt/ssd/k3s \
  --flannel-backend=none \
  --disable-network-policy \
  --disable-kube-proxy \
  --disable servicelb
```

*(Repeat for other nodes using the appropriate join tokens and URLs, always including `--data-dir /mnt/ssd/k3s`).*

## **Part III: Advanced Cluster Services: Networking and Storage**

### **3.1 Primary Networking: Cilium**

**Cilium** will manage the primary Kubernetes network overlay on eth0.7

1. **Prerequisites:** Install `linux-modules-extra-raspi` on all nodes.  
2. **Install Cilium:**  
   ```bash
   helm repo add cilium https://helm.cilium.io/  
   helm install cilium cilium/cilium --version 1.15.5 \
     --namespace kube-system \
     --set kubeProxyReplacement=true \
     --set l2announcements.enabled=true \
     --set externalIPs.enabled=true \
     --set k8sServiceHost=192.168.1.41 \
     --set k8sServicePort=6443
   ```

### **3.2 Storage Networking: Node IP Annotations**

To utilize the dedicated storage network (br-storage/192.168.10.0/24) for Longhorn replication traffic, we use **node annotations** instead of Multus NetworkAttachmentDefinition.

**Why Node Annotations Instead of Multus?**

Initially, we attempted to use Multus with macvlan/ipvlan to attach Longhorn pods to the storage network. However, this approach failed because:
1. Longhorn engine pods use the host network namespace for iSCSI connections
2. macvlan/ipvlan interfaces cannot communicate with the host's bridge interface (a fundamental limitation)
3. This caused "No route to host" errors when Longhorn tried to establish iSCSI connections

The solution is to use Longhorn's native `longhorn.io/storage-ip` node annotation, which tells Longhorn to use the node's br-storage IP directly for replication traffic.

**Configuration Steps:**

1. Ensure each node has a br-storage bridge interface with a static IP:
   ```bash
   # Example: Node k3s-ctl-01 has 192.168.10.41 on br-storage
   ip addr show br-storage
   ```

2. Annotate each Longhorn node with its storage IP:
   ```bash
   kubectl annotate nodes.longhorn.io <node-name> -n longhorn-system \
     longhorn.io/storage-ip=192.168.10.XX --overwrite
   ```

3. Verify the annotations:
   ```bash
   kubectl get nodes.longhorn.io -n longhorn-system \
     -o jsonpath='{range .items[*]}{.metadata.name}: {.metadata.annotations.longhorn\.io/storage-ip}{"\n"}{end}'
   ```

**Note:** Multus and Whereabouts are still installed for potential future use with other workloads that need secondary network interfaces, but they are not used for Longhorn storage networking.

### **3.3 Distributed Storage: Longhorn on SSD**

We configure **Longhorn** to store its block data on the SSD and replicate traffic over the dedicated storage network using node annotations.

1. Prepare SSD Directory:
   On each node, create the directory for Longhorn volumes.
   ```bash
   sudo mkdir -p /mnt/ssd/longhorn
   ```

2. Install Longhorn:
   Use Helm to install, configuring the default data path to the SSD. Note that storageNetwork is NOT set - we use node annotations instead.
   ```bash
   helm repo add longhorn https://charts.longhorn.io
   helm install longhorn longhorn/longhorn --namespace longhorn-system \
     --set defaultSettings.defaultDataPath="/mnt/ssd/longhorn"
   ```

3. Configure Storage Network via Node Annotations:
   After Longhorn is installed, annotate each node with its storage IP:
   ```bash
   # For each node, set the storage IP annotation
   kubectl annotate nodes.longhorn.io k3s-ctl-01 -n longhorn-system longhorn.io/storage-ip=192.168.10.41
   kubectl annotate nodes.longhorn.io k3s-wrk-01 -n longhorn-system longhorn.io/storage-ip=192.168.10.42
   # ... repeat for all nodes
   ```

## **Part IV: Automation with Ansible**

To automate the "Hybrid Storage" setup, your Ansible playbooks must handle the partitioning and mounting before installing Kubernetes.

### **4.1 Automating Storage Prep**

Add a pre_tasks section to your Ansible playbook to handle the drive setup.

```yaml
- name: Filesystem Setup  
  hosts: all  
  become: yes  
  tasks:  
    - name: Create ext4 filesystem on SSD  
      filesystem:  
        fstype: ext4  
        dev: /dev/sda1

    - name: Mount SSD to /mnt/ssd  
      mount:  
        path: /mnt/ssd  
        src: /dev/sda1  
        fstype: ext4  
        state: mounted

    - name: Create offload directories  
      file:  
        path: "{{ item }}"  
        state: directory  
      with_items:  
        - /mnt/ssd/var_log  
        - /mnt/ssd/k3s  
        - /mnt/ssd/longhorn

    - name: Bind mount /var/log  
      mount:  
        path: /var/log  
        src: /mnt/ssd/var_log  
        opts: bind  
        state: mounted  
        fstype: none
```

### **4.2 Automating K3s Install**

Update the k3s_server and k3s_agent roles variables to include the data directory flag.

```yaml
k3s_server_extra_args: >-  
  --data-dir /mnt/ssd/k3s  
  --flannel-backend=none  
  --disable-network-policy  
  --disable servicelb
```

## **Part V: Complete Ansible Automation Guide**

This section provides the full, step-by-step Ansible configuration to bootstrap your 4-node cluster from a fresh OS install to a fully functioning Kubernetes cluster with Hybrid Storage and Dedicated Networking.

### **5.1 Control Node Prerequisites**

On your laptop or management machine (the control node):

1. **Install Ansible and Python Dependencies:**  
   ```bash
   pip install ansible netaddr  
   ansible-galaxy collection install kubernetes.core
   ```

2. **Project Directory:** Create a folder `rpi-k8s-cluster` and cd into it.

### **5.2 Inventory Setup (hosts.ini)**

Create a hosts.ini file. Replace the MAC addresses (storage_mac) with the actual MAC addresses of your USB Ethernet adapters.

```ini
[masters]  
k3s-ctl-01 ansible_host=192.168.1.41 storage_ip=192.168.10.51 storage_mac=00:e0:4c:xx:xx:01

[workers]  
k3s-wrk-1 ansible_host=192.168.1.42 storage_ip=192.168.10.52 storage_mac=00:e0:4c:xx:xx:02  
k3s-wrk-2 ansible_host=192.168.1.43 storage_ip=192.168.10.53 storage_mac=00:e0:4c:xx:xx:03  
k3s-wrk-3 ansible_host=192.168.1.44 storage_ip=192.168.10.54 storage_mac=00:e0:4c:xx:xx:04

[k3s_cluster:children]  
masters  
workers

[all:vars]  
ansible_user=ubuntu  
ansible_ssh_private_key_file=~/.ssh/id_rsa  
k3s_version=v1.29.0+k3s1  
master_ip=192.168.1.41
```

### **5.3 Infrastructure Playbook (01-infra-prep.yml)**

This playbook handles OS configuration, Hybrid Storage setup, and Network renaming.

**Key improvements:**
- **Dynamic SSD detection:** Automatically finds USB storage devices instead of hardcoding `/dev/sda1`
- **Idempotent filesystem creation:** Only formats the SSD if no filesystem exists (prevents data loss on re-runs)
- **noatime mount option:** Reduces unnecessary write operations

```yaml
---
- name: Prepare Raspberry Pi Nodes
  hosts: all
  become: yes
  vars:
    # SSD device - can be overridden per host in inventory
    ssd_device: "{{ ssd_device_override | default('') }}"
  tasks:
    # --- OS PREP ---
    - name: Enable cgroups in cmdline.txt (Required for K3s on RPi)
      replace:
        path: /boot/firmware/cmdline.txt
        regexp: '^(.*console=tty1.*)$'
        replace: '\1 cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1'
      notify: Reboot

    - name: Install essential packages
      apt:
        name: ['open-iscsi', 'nfs-common', 'linux-modules-extra-raspi']
        state: present
        update_cache: yes

    # --- HYBRID STORAGE SETUP ---
    # Dynamic USB SSD detection (avoids hardcoding /dev/sda1)
    - name: Find USB storage device by-id (if not specified)
      shell: |
        for dev in /dev/disk/by-id/usb-*; do
          if [ -e "$dev" ] && [ ! -L "${dev}-part1" ]; then
            realpath "$dev"
            exit 0
          elif [ -L "${dev}-part1" ]; then
            realpath "${dev}-part1"
            exit 0
          fi
        done
        echo "/dev/sda1"
      register: detected_ssd
      changed_when: false
      when: ssd_device == ''

    - name: Set SSD device path
      set_fact:
        ssd_path: "{{ ssd_device if ssd_device != '' else detected_ssd.stdout | trim }}"

    - name: Display detected SSD device
      debug:
        msg: "Using SSD device: {{ ssd_path }}"

    # Idempotent filesystem creation (prevents data loss on re-runs)
    - name: Check if SSD already has a filesystem
      command: blkid {{ ssd_path }}
      register: blkid_result
      failed_when: false
      changed_when: false

    - name: Format USB SSD (only if no filesystem exists)
      filesystem:
        fstype: ext4
        dev: "{{ ssd_path }}"
      when: blkid_result.rc != 0

    - name: Mount SSD to /mnt/ssd
      mount:
        path: /mnt/ssd
        src: "{{ ssd_path }}"
        fstype: ext4
        opts: defaults,noatime
        state: mounted

    - name: Create offload directories
      file:
        path: "{{ item }}"
        state: directory
        mode: '0755'
      loop:
        - /mnt/ssd/var_log
        - /mnt/ssd/k3s
        - /mnt/ssd/longhorn

    - name: Stop rsyslog before moving logs
      service:
        name: rsyslog
        state: stopped

    - name: Sync /var/log to SSD (first run only)
      command: rsync -a /var/log/ /mnt/ssd/var_log/
      args:
        creates: /mnt/ssd/var_log/syslog

    - name: Bind mount /var/log from SSD
      mount:
        path: /var/log
        src: /mnt/ssd/var_log
        opts: bind
        state: mounted
        fstype: none

    - name: Start rsyslog
      service:
        name: rsyslog
        state: started

    # --- NETWORK PREP ---
    - name: Configure Netplan for dedicated storage network
      copy:
        dest: /etc/netplan/60-storage.yaml
        content: |
          network:
            version: 2
            ethernets:
              eth1:
                match:
                  macaddress: {{ storage_mac }}
                set-name: eth1
                dhcp4: false
                addresses:
                  - {{ storage_ip }}/24
      notify: Apply Netplan

  handlers:
    - name: Apply Netplan
      command: netplan apply
    - name: Reboot
      reboot:
```

### **5.4 K3s Installation Playbook (02-k3s-install.yml)**

This playbook installs K3s with the custom flags required for Cilium and SSD offloading.

**Key improvements:**
- **`--cluster-init` flag:** Initialises embedded etcd for potential future HA expansion
- **Version pinning:** Uses `k3s_version` variable from inventory for reproducible deployments
- **Health checks:** Waits for K3s and nodes to be ready before proceeding
- **Additional TLS SANs:** Includes hostname for flexible cluster access

```yaml
---
- name: Install K3s Control Plane
  hosts: masters
  become: yes
  vars:
    # Common flags for control plane (includes --cluster-init for etcd)
    k3s_args: >-
      --cluster-init
      --data-dir /mnt/ssd/k3s
      --flannel-backend=none
      --disable-network-policy
      --disable-kube-proxy
      --disable servicelb
  tasks:
    - name: Install K3s on Control Plane
      shell: |
        curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION={{ k3s_version }} sh -s - server \
        --tls-san {{ master_ip }} \
        --tls-san {{ inventory_hostname }} \
        {{ k3s_args }}
      args:
        creates: /mnt/ssd/k3s/server/node-token

    - name: Wait for K3s to be ready
      command: kubectl get nodes
      environment:
        KUBECONFIG: /etc/rancher/k3s/k3s.yaml
      register: k3s_ready
      until: k3s_ready.rc == 0
      retries: 30
      delay: 10

    - name: Get Node Token
      command: cat /mnt/ssd/k3s/server/node-token
      register: node_token
      changed_when: false

- name: Install K3s Workers
  hosts: workers
  become: yes
  vars:
    k3s_args: "--data-dir /mnt/ssd/k3s"
  tasks:
    - name: Get Node Token
      command: cat /mnt/ssd/k3s/server/node-token
      register: node_token
      delegate_to: "{{ groups['masters'][0] }}"
      run_once: true
      changed_when: false

    - name: Install K3s Agent
      shell: |
        curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION={{ k3s_version }} \
        K3S_URL=https://{{ master_ip }}:6443 \
        K3S_TOKEN={{ node_token.stdout }} sh -s - \
        {{ k3s_args }}
      args:
        creates: /mnt/ssd/k3s/agent/kubelet.kubeconfig

    - name: Wait for agent to join cluster
      command: kubectl get node {{ inventory_hostname }}
      environment:
        KUBECONFIG: /etc/rancher/k3s/k3s.yaml
      delegate_to: "{{ groups['masters'][0] }}"
      register: node_joined
      until: node_joined.rc == 0
      retries: 30
      delay: 10

- name: Fetch Kubeconfig to Control Node
  hosts: "{{ groups['masters'][0] }}"
  become: yes
  tasks:
    - name: Copy kubeconfig to user home
      fetch:
        src: /etc/rancher/k3s/k3s.yaml
        dest: ~/.kube/config-rpi
        flat: yes
```

### **5.5 Cluster Add-ons Playbook (03-addons.yml)**

This playbook configures the internal Kubernetes services. Ensure you run this *after* you have set up your local kubeconfig from the previous step.

**Key improvements:**
- **Version pinning:** Cilium and Longhorn versions are explicitly specified for reproducibility
- **Namespace ordering:** Creates `longhorn-system` namespace before the NetworkAttachmentDefinition
- **Health checks:** Waits for Cilium and Longhorn DaemonSets to be ready before proceeding

```yaml
---
- name: Install Cluster Add-ons
  hosts: localhost
  connection: local
  vars:
    kubeconfig: ~/.kube/config-rpi
    cilium_version: "1.15.5"
    longhorn_version: "1.6.0"
  tasks:
    # --- CILIUM CNI ---
    - name: Add Cilium Helm Repo
      kubernetes.core.helm_repository:
        name: cilium
        repo_url: "https://helm.cilium.io/"

    - name: Install Cilium
      kubernetes.core.helm:
        name: cilium
        chart_ref: cilium/cilium
        chart_version: "{{ cilium_version }}"
        release_namespace: kube-system
        kubeconfig: "{{ kubeconfig }}"
        values:
          kubeProxyReplacement: true
          k8sServiceHost: "{{ master_ip | default('192.168.1.41') }}"
          k8sServicePort: 6443
          l2announcements:
            enabled: true
          externalIPs:
            enabled: true
          # Fix for RPi4/Ubuntu MTU issues if present
          mtu: 1450

    - name: Wait for Cilium to be ready
      kubernetes.core.k8s_info:
        kubeconfig: "{{ kubeconfig }}"
        kind: DaemonSet
        namespace: kube-system
        name: cilium
      register: cilium_ds
      until: >
        cilium_ds.resources | length > 0 and
        cilium_ds.resources[0].status.numberReady | default(0) ==
        cilium_ds.resources[0].status.desiredNumberScheduled | default(1)
      retries: 30
      delay: 10

    # --- MULTUS CNI ---
    - name: Install Multus (Manifest)
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        state: present
        definition: "{{ lookup('url', 'https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/v4.1.3/deployments/multus-daemonset-thick.yml', split_lines=False) }}"

    - name: Install Whereabouts (Manifest)
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        state: present
        definition: "{{ lookup('url', 'https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/v0.7.0/doc/crds/daemonset-install.yaml', split_lines=False) }}"

    - name: Create IP Pool for Whereabouts
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        state: present
        definition: "{{ lookup('url', 'https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/v0.7.0/doc/crds/whereabouts.cni.cncf.io_ippools.yaml', split_lines=False) }}"

    # --- LONGHORN STORAGE ---
    # Create namespace BEFORE NetworkAttachmentDefinition
    - name: Create longhorn-system namespace
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        state: present
        definition:
          apiVersion: v1
          kind: Namespace
          metadata:
            name: longhorn-system

    - name: Create Storage Network Attachment Definition
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        state: present
        definition:
          apiVersion: "k8s.cni.cncf.io/v1"
          kind: NetworkAttachmentDefinition
          metadata:
            name: storage-network
            namespace: longhorn-system
          spec:
            config: '{
              "cniVersion": "0.3.1",
              "type": "macvlan",
              "master": "eth1",
              "mode": "bridge",
              "ipam": {
                "type": "whereabouts",
                "range": "192.168.10.0/24"
              }
            }'

    - name: Add Longhorn Helm Repo
      kubernetes.core.helm_repository:
        name: longhorn
        repo_url: "https://charts.longhorn.io"

    - name: Install Longhorn
      kubernetes.core.helm:
        name: longhorn
        chart_ref: longhorn/longhorn
        chart_version: "{{ longhorn_version }}"
        release_namespace: longhorn-system
        create_namespace: no  # Already created above
        kubeconfig: "{{ kubeconfig }}"
        values:
          defaultSettings:
            defaultDataPath: "/mnt/ssd/longhorn"
            storageNetwork: "longhorn-system/storage-network"

    - name: Wait for Longhorn to be ready
      kubernetes.core.k8s_info:
        kubeconfig: "{{ kubeconfig }}"
        kind: DaemonSet
        namespace: longhorn-system
        name: longhorn-manager
      register: longhorn_ds
      until: >
        longhorn_ds.resources | length > 0 and
        longhorn_ds.resources[0].status.numberReady | default(0) ==
        longhorn_ds.resources[0].status.desiredNumberScheduled | default(1)
      retries: 30
      delay: 10
```

### **5.6 Execution Instructions**

1. **Run Infra Prep:** `ansible-playbook -i hosts.ini 01-infra-prep.yml`  
   * *Wait for all nodes to reboot.*  
2. **Run K3s Install:** `ansible-playbook -i hosts.ini 02-k3s-install.yml`  
3. Fix Local Kubeconfig:  
   The fetched kubeconfig will point to 127.0.0.1. Update it to your master's IP:  
   ```bash
   sed -i 's/127.0.0.1/192.168.1.41/g' ~/.kube/config-rpi
   ```

4. **Run Add-ons:** `ansible-playbook 03-addons.yml`

## **Conclusion**

This updated architecture meets your specific requirement to keep the base OS on the SD card while rigorously protecting it from write exhaustion. By mounting the SSD to /mnt/ssd and using bind mounts for /var/log, along with configuring K3s and Longhorn to write directly to the SSD, you ensure that the high-frequency I/O operations (logging, container layers, database replication) never touch the SD card. Combined with the dedicated storage network (192.168.10.0/24) and full Ansible automation, this setup provides a robust single control plane with three worker nodes, maximizing both the lifespan of your boot media and the performance of your storage layer.

**Note:** This configuration uses a single control plane node (k3s-ctl-01). While this is suitable for a homelab environment, it does not provide high availability for the control plane. If the control plane node fails, the cluster will be unavailable until it is restored. For production environments requiring high availability, consider running multiple control plane nodes with an external load balancer.

#### **Works cited**

1. Install Ubuntu on a Raspberry Pi, accessed September 8, 2025, [https://ubuntu.com/download/raspberry-pi](https://ubuntu.com/download/raspberry-pi)  
2. downfalls to using ubuntu server over raspberry pi os lite?, accessed September 8, 2025, [https://forums.raspberrypi.com/viewtopic.php?t=328591](https://forums.raspberrypi.com/viewtopic.php?t=328591)  
3. Best Kubernetes Distributions for Home Lab Enthusiasts in 2025 \- Virtualization Howto, accessed September 8, 2025, [https://www.virtualizationhowto.com/2025/03/best-kubernetes-distributions-for-home-lab-enthusiasts-in-2025/](https://www.virtualizationhowto.com/2025/03/best-kubernetes-distributions-for-home-lab-enthusiasts-in-2025/)  
4. K3s \- Lightweight Kubernetes | K3s, accessed September 8, 2025, [https://docs.k3s.io/](https://docs.k3s.io/)  
5. K3s server \- K3s \- Lightweight Kubernetes, accessed September 8, 2025, [https://docs.k3s.io/cli/server](https://docs.k3s.io/cli/server)  
6. Part 3 \- K3s Zero to Hero : Mastering K3s Configuration \- From YAML to CLI, accessed September 8, 2025, [https://blog.alphabravo.io/part-3-k3s-zero-to-hero-mastering-k3s-configuration-from-yaml-to-cli/](https://blog.alphabravo.io/part-3-k3s-zero-to-hero-mastering-k3s-configuration-from-yaml-to-cli/)  
7. Kubernetes Cluster on Raspberry Pi using Ubuntu 22.04 LTS, K3s, and Cilium\! | Armand.nz, accessed September 8, 2025, [https://www.armand.nz/notes/k3s/Kubernetes%20Cluster%20on%20Raspberry%20Pi%20using%20Ubuntu%2022.04%20LTS,%20K3s,%20and%20Cilium\!](https://www.armand.nz/notes/k3s/Kubernetes%20Cluster%20on%20Raspberry%20Pi%20using%20Ubuntu%2022.04%20LTS,%20K3s,%20and%20Cilium!)
