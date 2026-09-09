#!/usr/bin/env bash

# Source-level guardrails for the clean-slate rebuild. This deliberately avoids
# Ansible, kubectl, and network access so it is useful before a cluster exists.
set -euo pipefail

if ! command -v rg >/dev/null 2>&1; then
  printf 'rg (ripgrep) is required for offline invariant checks.\n' >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
failures=0

pass() { printf 'OK: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
require() {
  local description="$1" pattern="$2"; shift 2
  if rg -U -q --pcre2 "$pattern" "$@"; then pass "$description"; else fail "$description"; fi
}
forbid() {
  local description="$1" pattern="$2"; shift 2
  if rg -U -q --pcre2 "$pattern" "$@"; then fail "$description"; else pass "$description"; fi
}

cd "$repo_root"

forbid 'Active automation does not use /mnt/ssd' '/mnt/ssd' 01-infra-prep.yml 02-k3s-install.yml 03-addons.yml 04-monitoring.yml group_vars/all.yml
forbid 'Active automation does not use snapshot-thick' 'snapshot-thick' 01-infra-prep.yml 02-k3s-install.yml 03-addons.yml 04-monitoring.yml group_vars/all.yml
forbid 'Active automation does not use plaintext admin passwords' 'grafana_admin_password:\s*(?![!])[^\s#]' group_vars/all.yml 04-monitoring.yml
require 'Inventory has exactly three canonical servers' '(?ms)^\[masters\]\npi-ctl-01\b.*\npi-ctl-02\b.*\npi-ctl-03\b.*\n\n\[workers\]' hosts.ini
require 'Inventory has exactly two canonical agents' '(?ms)^\[workers\]\npi-wrk-01\b.*\npi-wrk-02\b.*\n\n(?:#\[edge_nodes\]|\[k3s_cluster:children\])' hosts.ini
require 'API VIP is 192.168.1.40 and master_ip aliases it' '(?ms)^api_vip:\s*192\.168\.1\.40\s*$.*^master_ip:\s*"\{\{ api_vip \}\}"\s*$' group_vars/all.yml
require 'kube-vip disables Service handling' '(?ms)name: svc_enable\s*\n\s*value: "false"' templates/k3s/kube-vip-daemonset.yaml.j2
require 'Storage NAD uses bridge CNI on br-storage' '(?ms)type:\s*"bridge".*bridge:\s*"br-storage"' 03-addons.yml
require 'Cilium permits Multus coexistence' '(?ms)cni:\s*\n\s*exclusive:\s*false' 03-addons.yml
require 'Cilium cluster-pool CIDR follows k3s_cluster_cidr' '(?ms)clusterPoolIPv4PodCIDRList:\s*\n\s*- "\{\{ k3s_cluster_cidr \}\}"' 03-addons.yml
forbid 'Monitoring helm repo update does not name individual repos' 'helm repo update vm grafana' 04-monitoring.yml
require 'Multus image is digest pinned' '^multus_image:.*\n\s+.*@sha256:[a-f0-9]{64}' group_vars/all.yml
require 'Multus upstream manifest has a checksum' '^multus_manifest_checksum:.*\n\s+sha256:[a-f0-9]{64}' group_vars/all.yml
require 'Multus uses a versioned local patch' 'files/patches/multus-daemonset-thick-v4\.3\.0\.yml\.j2' 03-addons.yml
require 'Multus patch mounts host netns at /var/run/netns' '(?ms)name:\s*host-var-run-netns.*mountPath:\s*/var/run/netns' files/patches/multus-daemonset-thick-v4.3.0.yml.j2
require 'Storage NAD bridge plugin is installed into /opt/cni/bin' 'dest:\s*/opt/cni/bin/bridge' tasks/install-storage-cni-plugins.yml
require 'Whereabouts image is digest pinned' '^whereabouts_image:.*\n\s+.*@sha256:[a-f0-9]{64}' group_vars/all.yml
require 'Longhorn uses SSD-root data path' '^longhorn_default_data_path:\s*"/var/lib/longhorn"\s*$' group_vars/all.yml
require 'Longhorn uses the K3s kubelet root' 'kubeletRootDir:\s*"/var/lib/kubelet"' 03-addons.yml
require 'Longhorn eligibility names exactly three nodes' '(?ms)longhorn_storage_nodes:\s*\n\s*- pi-ctl-03\s*\n\s*- pi-wrk-01\s*\n\s*- pi-wrk-02' group_vars/all.yml
require 'Longhorn replica count is two' '^longhorn_default_replica_count:\s*2\s*$' group_vars/all.yml
require 'Longhorn StorageClass selects tagged nodes with two replicas' '(?ms)numberOfReplicas: "\{\{ longhorn_default_replica_count \| string \}\}".*nodeSelector: "storage-network"' 03-addons.yml
require 'Longhorn repo-managed StorageClass is the single default candidate' '(?ms)name: "\{\{ storage_class \}\}".*storageclass\.kubernetes\.io/is-default-class: "true"' 03-addons.yml
require 'Fluent Bit maps log to _msg' 'Rename\s+log _msg' 04-monitoring.yml
require 'Grafana VictoriaLogs datasource UID is stable' 'uid:\s*victorialogs' 04-monitoring.yml
require 'Grafana metrics datasource UID is stable' 'uid:\s*VictoriaMetrics' 04-monitoring.yml
require 'Raspberry Pi health dashboard uses collected metrics' '(?ms)pi_cpu_temperature_celsius.*pi_root_disk_smart_healthy.*pi_health_metrics_scrape_success' dashboards/pi-health-configmap.yaml
require 'Grafana VictoriaLogs plugin is version-pinned' 'victoriametrics-logs-datasource@[0-9]+\.[0-9]+\.[0-9]+' 04-monitoring.yml
require 'VictoriaMetrics stable Service is declared and used' '(?ms)name: vmsingle-stable.*remoteWrite:.*vmsingle-stable\.monitoring\.svc' 04-monitoring.yml
require 'VictoriaMetrics has measured recovery headroom' '(?ms)name: Install Victoria Metrics Single.*?resources:\s*\n\s+requests:\s*\n\s+cpu: 250m\s*\n\s+memory: 512Mi\s*\n\s+limits:.*?cpu: "1"\s*\n\s+memory: 1Gi' 04-monitoring.yml
require 'Each monitoring repo task has a matching repo-update tag set' 'tags: \[monitoring, repositories, vmsingle, victorialogs, vmagent, vmalert, node_exporter, kube-state-metrics, grafana, fluent-bit\]' 04-monitoring.yml
require 'crictl uses the K3s containerd socket' '(?ms)runtime-endpoint: unix:///run/k3s/containerd/containerd\.sock.*image-endpoint: unix:///run/k3s/containerd/containerd\.sock' tasks/configure-crictl.yml
require 'Existing clusters have a safe crictl configuration playbook' '(?ms)hosts: k3s_cluster.*include_tasks: tasks/configure-crictl\.yml' k3s-configure-crictl.yml
require 'node-exporter reads host Pi health textfiles' '(?ms)collector\.textfile\.directory=.*pi_health_textfile_directory.*extraHostVolumeMounts:.*pi-health-textfiles' 04-monitoring.yml
require 'Pi health collection defaults to SCSI SMART' '^pi_health_smart_device_type:\s*scsi$' group_vars/all.yml
require 'USB SSD UAS quirk uses the fleet bridge ID' '^usb_ssd_bridge_vid_pid:\s*"0930:1400"\s*$' group_vars/all.yml
require 'USB SSD tune targets Ubuntu tryboot cmdline' '/boot/firmware/current' tasks/tune-usb-ssd.yml
require 'Existing clusters have a safe USB SSD tune playbook' '(?ms)hosts: k3s_cluster.*include_tasks: tasks/tune-usb-ssd\.yml' k3s-tune-usb-ssd.yml
require 'External Secrets chart is exactly pinned' '^external_secrets_version:\s*"[0-9]+\.[0-9]+\.[0-9]+"$' group_vars/all.yml
require 'Fluent Bit floating test hook is disabled' '(?ms)name: Install Fluent Bit.*?testFramework:\s*\n\s+enabled: false' 04-monitoring.yml
require '1Password uses the direct SDK provider' '(?ms)kind: ClusterSecretStore.*onepasswordSDK:.*serviceAccountSecretRef:' 05-secrets.yml
require '1Password token format is validated before use' "match\\('\^ops_'\\)" 05-secrets.yml
forbid '1Password bootstrap token is not stored in group vars' 'onepassword_(service_account_)?token:' group_vars/all.yml
require 'Flux version is exactly pinned' '^flux_version:\s*"v[0-9]+\.[0-9]+\.[0-9]+"$' group_vars/all.yml
require 'Flux canonical source is the NAS' '^home_gitops_repository_url:.*\n\s+http://nas\.home\.ftmon\.org:3000/dsheehan/home-gitops\.git$' group_vars/all.yml
require 'Flux controller manifest is checksum pinned' '^flux_components_manifest_checksum:.*\n\s+sha256:[a-f0-9]{64}$' group_vars/all.yml
require 'Flux sync manifest is checksum pinned' '^flux_sync_manifest_checksum:.*\n\s+sha256:[a-f0-9]{64}$' group_vars/all.yml
require 'Flux bootstrap rejects authenticated Git source' "'secretRef:' not in flux_sync_manifest.content" 06-flux.yml
require 'Flux bootstrap waits for source readiness' 'name: Wait for canonical Git source readiness' 06-flux.yml
require 'Flux exposes a source-only preflight tag' 'tags: \[flux, gitops, preflight\]' 06-flux.yml
require 'Live verification checks canonical Flux source' 'Flux Git source is Ready from the canonical NAS repository' scripts/verify-cluster.sh
require 'Live verification checks 1Password retrieval canary' '1Password retrieval canary is Ready with the expected target key' scripts/verify-cluster.sh
require 'Live verification checks Traefik from the LAN client path' '(?ms)TRAEFIK_LB_IP="192\.168\.1\.200".*HOMEPAGE_HOST="homepage\.local".*check_lan_ingress' scripts/verify-cluster.sh
# The following source-invariant regexes intentionally match literal shell
# variable references rather than expanding variables in this test process.
# shellcheck disable=SC2016
require 'Alert smoke test requires explicit live mode' '(?ms)LIVE_TEST=false.*--live\) LIVE_TEST=true.*if \[\[ "\$LIVE_TEST" != true \]\]' scripts/test-alerting.sh
# shellcheck disable=SC2016
require 'Alert smoke test restores external heartbeat on exit' '(?ms)cleanup\(\).*heartbeat_failed.*curl .*"\$heartbeat_url".*trap cleanup EXIT INT TERM' scripts/test-alerting.sh
forbid 'Alert smoke test does not print external endpoint secrets' 'echo .*heartbeat_url|printf .*heartbeat_url|echo .*ntfy_base|printf .*ntfy_base' scripts/test-alerting.sh

if (( failures )); then
  printf '\nOffline rebuild invariant checks failed: %d.\n' "$failures" >&2
  exit 1
fi
printf '\nOffline rebuild invariant checks passed.\n'
