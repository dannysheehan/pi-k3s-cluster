#!/usr/bin/env bash

# Verify the rebuilt cluster's externally observable invariants. This script is
# intentionally read-only: it does not create probes or change cluster state.
set -euo pipefail

KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config-rpi}"
API_VIP="192.168.1.40"
EXPECTED_NODES=(pi-ctl-01 pi-ctl-02 pi-ctl-03 pi-wrk-01 pi-wrk-02)
EXPECTED_STORAGE_NODES=(pi-ctl-03 pi-wrk-01 pi-wrk-02)

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required but not installed." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not installed." >&2
  exit 1
fi

if [[ ! -f "$KUBECONFIG_PATH" ]]; then
  echo "Kubeconfig not found at: $KUBECONFIG_PATH" >&2
  echo "Set KUBECONFIG or place the cluster config at ~/.kube/config-rpi" >&2
  exit 1
fi

failures=0

record_failure() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

record_ok() {
  printf 'OK: %s\n' "$1"
}

record_warn() {
  printf 'WARN: %s\n' "$1" >&2
}

run_section() {
  local title="$1"
  shift
  printf '\n== %s ==\n' "$title"
  "$@"
}

kubectl_rpi() {
  kubectl --kubeconfig "$KUBECONFIG_PATH" "$@"
}

json_items() {
  kubectl_rpi "$@" -o json
}

check_api_vip() {
  local server
  server="$(kubectl_rpi config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  if [[ "$server" == "https://${API_VIP}:6443" ]]; then
    record_ok "Kubeconfig uses API VIP https://${API_VIP}:6443."
  else
    record_failure "Kubeconfig server is ${server:-unset}; expected https://${API_VIP}:6443."
  fi
}

check_topology() {
  local nodes expected joined_names ready_count schedulable_count control_plane_count etcd_count control_plane_names etcd_names expected_servers
  nodes="$(json_items get nodes)"
  joined_names="$(printf '%s' "$nodes" | jq -r '.items[].metadata.name' | sort | tr '\n' ' ')"
  expected="$(printf '%s\n' "${EXPECTED_NODES[@]}" | sort | tr '\n' ' ')"

  if [[ "$joined_names" == "$expected" ]]; then
    record_ok "Canonical five-node inventory is present."
  else
    record_failure "Node names are '${joined_names}', expected '${expected}'."
  fi

  ready_count="$(printf '%s' "$nodes" | jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length')"
  schedulable_count="$(printf '%s' "$nodes" | jq '[.items[] | select(.spec.unschedulable != true)] | length')"
  if [[ "$ready_count" == 5 && "$schedulable_count" == 5 ]]; then
    record_ok "Exactly five nodes are Ready and schedulable."
  else
    record_failure "Expected 5 Ready and schedulable nodes; found Ready=${ready_count}, schedulable=${schedulable_count}."
  fi

  control_plane_count="$(printf '%s' "$nodes" | jq '[.items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] != null)] | length')"
  etcd_count="$(printf '%s' "$nodes" | jq '[.items[] | select(.metadata.labels["node-role.kubernetes.io/etcd"] != null)] | length')"
  control_plane_names="$(printf '%s' "$nodes" | jq -r '.items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] != null) | .metadata.name' | sort | tr '\n' ' ')"
  etcd_names="$(printf '%s' "$nodes" | jq -r '.items[] | select(.metadata.labels["node-role.kubernetes.io/etcd"] != null) | .metadata.name' | sort | tr '\n' ' ')"
  expected_servers="$(printf '%s\n' pi-ctl-01 pi-ctl-02 pi-ctl-03 | sort | tr '\n' ' ')"
  if [[ "$control_plane_count" == 3 && "$etcd_count" == 3 && "$control_plane_names" == "$expected_servers" && "$etcd_names" == "$expected_servers" ]]; then
    record_ok "pi-ctl-01 through pi-ctl-03 are the three embedded-etcd control-plane servers."
  else
    record_failure "Expected pi-ctl-01 through pi-ctl-03 as 3 control-plane/etcd nodes; found control-plane='${control_plane_names}', etcd='${etcd_names}'."
  fi
}

check_daemonset_coverage() {
  local name="$1" namespace="$2" desired ready available
  if ! kubectl_rpi get daemonset -n "$namespace" "$name" >/dev/null 2>&1; then
    record_failure "DaemonSet ${namespace}/${name} is missing."
    return
  fi
  read -r desired ready available < <(kubectl_rpi get daemonset -n "$namespace" "$name" -o json |
    jq -r '[.status.desiredNumberScheduled // 0, .status.numberReady // 0, .status.numberAvailable // 0] | @tsv')
  if [[ "$desired" == 5 && "$ready" == 5 && "$available" == 5 ]]; then
    record_ok "DaemonSet ${namespace}/${name} covers all five nodes."
  else
    record_failure "DaemonSet ${namespace}/${name} coverage is desired=${desired}, ready=${ready}, available=${available}; expected 5 each."
  fi
}

check_vmsingle_endpoints() {
  local endpoint_count
  endpoint_count="$(kubectl_rpi get endpoints -n monitoring vmsingle-stable \
    -o jsonpath='{range .subsets[*].addresses[*]}1{"\n"}{end}' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$endpoint_count" -gt 0 ]]; then
    record_ok "VictoriaMetrics vmsingle-stable has ${endpoint_count} ready endpoint(s)."
  else
    record_failure "VictoriaMetrics vmsingle-stable has no ready Service endpoints."
    kubectl_rpi get pods,endpoints -n monitoring -l app.kubernetes.io/instance=vmsingle -o wide || true
  fi
}

check_longhorn_storage() {
  local nodes eligible names sc_replicas sc_selector
  nodes="$(json_items get nodes.longhorn.io -n longhorn-system)"
  eligible="$(printf '%s' "$nodes" | jq '[.items[] | select((.spec.allowScheduling // false) == true and ((.spec.tags // []) | index("storage-network")) != null)] | length')"
  names="$(printf '%s' "$nodes" | jq -r '.items[] | select((.spec.allowScheduling // false) == true and ((.spec.tags // []) | index("storage-network")) != null) | .metadata.name' | sort | tr '\n' ' ')"
  if [[ "$eligible" == 3 && "$names" == "$(printf '%s\n' "${EXPECTED_STORAGE_NODES[@]}" | sort | tr '\n' ' ')" ]]; then
    record_ok "Longhorn has exactly the three intended eligible tagged nodes."
  else
    record_failure "Longhorn eligible storage-network nodes are '${names}' (${eligible}); expected pi-ctl-03, pi-wrk-01, pi-wrk-02."
  fi
  sc_replicas="$(kubectl_rpi get storageclass longhorn-rpi -o jsonpath='{.parameters.numberOfReplicas}' 2>/dev/null || true)"
  sc_selector="$(kubectl_rpi get storageclass longhorn-rpi -o jsonpath='{.parameters.nodeSelector}' 2>/dev/null || true)"
  if [[ "$sc_replicas" == 2 && "$sc_selector" == storage-network ]]; then
    record_ok "StorageClass longhorn-rpi uses two replicas on storage-network nodes."
  else
    record_failure "StorageClass longhorn-rpi has replicas='${sc_replicas:-missing}', nodeSelector='${sc_selector:-missing}'; expected 2 and storage-network."
  fi
}

check_network_invariants() {
  local nad_type nad_bridge cilium_exclusive traefik_ready gateway_classes
  nad_type="$(kubectl_rpi get network-attachment-definition -n longhorn-system storage-network -o json |
    jq -r '.spec.config | fromjson | .type' 2>/dev/null || true)"
  nad_bridge="$(kubectl_rpi get network-attachment-definition -n longhorn-system storage-network -o json |
    jq -r '.spec.config | fromjson | .bridge' 2>/dev/null || true)"
  if [[ "$nad_type" == bridge && "$nad_bridge" == br-storage ]]; then
    record_ok "storage-network NAD uses bridge CNI on br-storage."
  else
    record_failure "storage-network NAD is type='${nad_type:-missing}', bridge='${nad_bridge:-missing}'; expected bridge/br-storage."
  fi
  cilium_exclusive="$(kubectl_rpi -n kube-system get configmap cilium-config -o jsonpath='{.data.cni-exclusive}' 2>/dev/null || true)"
  if [[ "$cilium_exclusive" == false ]]; then
    record_ok "Cilium cni-exclusive is false for Multus coexistence."
  else
    record_failure "Cilium cni-exclusive is '${cilium_exclusive:-missing}', expected false."
  fi
  check_daemonset_coverage kube-multus-ds kube-system
  check_daemonset_coverage whereabouts kube-system
  traefik_ready="$(kubectl_rpi -n traefik get deployment traefik -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  if [[ "${traefik_ready:-0}" -ge 1 ]]; then
    record_ok "Traefik has ${traefik_ready} ready replica(s)."
  else
    record_failure "Traefik has no ready replicas."
  fi
  gateway_classes="$(kubectl_rpi get gatewayclass -o jsonpath='{range .items[*]}{.metadata.name}{"\\n"}{end}' 2>/dev/null || true)"
  if [[ -n "$gateway_classes" ]]; then
    record_ok "Gateway API is available (${gateway_classes//$'\n'/, })."
  else
    record_failure "No GatewayClass found; Gateway API CRDs/controller are not usable."
  fi
}

check_filesystem_device_errors() {
  local response
  if ! response="$(kubectl_rpi exec -n monitoring deploy/vmagent-victoria-metrics-agent -- \
    wget -qO- --post-data 'query=node_filesystem_device_error{mountpoint="/"} > 0' \
    http://vmsingle-stable.monitoring.svc:8428/api/v1/query 2>/dev/null)"; then
    record_warn "Unable to query VictoriaMetrics for root filesystem device errors."
    return
  fi
  if ! printf '%s' "$response" | grep -q '"status":"success"'; then
    record_warn "Filesystem device error query did not return success: ${response}"
  elif printf '%s' "$response" | grep -q '"result":\[\]'; then
    record_ok "No filesystem device errors reported for root filesystems."
  else
    record_failure "Root filesystem device error(s) detected: $(printf '%s' "$response" | grep -oE '"(instance|mountpoint|device)":"[^"]*"' | tr '\n' ' ')"
  fi
}

check_pi_health_metrics() {
  local response unhealthy_count collector_count
  if ! response="$(kubectl_rpi exec -n monitoring deploy/vmagent-victoria-metrics-agent -- \
    wget -qO- --post-data 'query=(pi_health_metrics_scrape_success == 0) or (pi_root_disk_smart_healthy == 0) or (pi_cpu_temperature_celsius > 80)' \
    http://vmsingle-stable.monitoring.svc:8428/api/v1/query 2>/dev/null)"; then
    record_failure "Unable to query Raspberry Pi temperature and SMART metrics."
    return
  fi
  unhealthy_count="$(jq -r '.data.result | length' <<<"$response" 2>/dev/null || echo -1)"
  if [[ "$unhealthy_count" == 0 ]]; then
    record_ok "No critical Raspberry Pi temperature, SMART, or collector failures reported."
  else
    record_failure "Raspberry Pi health query returned ${unhealthy_count} unhealthy series."
  fi

  if ! response="$(kubectl_rpi exec -n monitoring deploy/vmagent-victoria-metrics-agent -- \
    wget -qO- --post-data 'query=count(pi_health_metrics_scrape_success)' \
    http://vmsingle-stable.monitoring.svc:8428/api/v1/query 2>/dev/null)"; then
    record_failure "Unable to count Raspberry Pi health collectors."
    return
  fi
  collector_count="$(jq -r '.data.result[0].value[1] // "0"' <<<"$response" 2>/dev/null || echo 0)"
  if [[ "$collector_count" == 5 ]]; then
    record_ok "Raspberry Pi health metrics cover all five nodes."
  else
    record_failure "Raspberry Pi health metrics cover ${collector_count} node(s); expected 5."
  fi
}

check_vmagent_queue() {
  local metrics pending_values max_pending warn_bytes critical_bytes
  if ! kubectl_rpi get deployment -n monitoring vmagent-victoria-metrics-agent >/dev/null 2>&1; then
    record_warn "VMAgent deployment not found; skipping queue checks."
    return
  fi
  if ! metrics="$(kubectl_rpi exec -n monitoring deploy/vmagent-victoria-metrics-agent -- wget -qO- http://127.0.0.1:8429/metrics)"; then
    record_failure "Unable to read VMAgent self-metrics."
    return
  fi
  pending_values="$(printf '%s\n' "$metrics" | awk '/^vmagent_remotewrite_pending_data_bytes\{/ { print int($2) } /^vm_persistentqueue_bytes_pending\{/ { print int($2) }')"
  if [[ -z "$pending_values" ]]; then
    record_warn "VMAgent queue metrics were not present in self-metrics output."
    return
  fi
  max_pending="$(printf '%s\n' "$pending_values" | sort -nr | head -n1)"
  warn_bytes=$((256 * 1024 * 1024))
  critical_bytes=$((1024 * 1024 * 1024))
  if [[ "$max_pending" -ge "$critical_bytes" ]]; then
    record_failure "VMAgent remote-write queue is critically high: ${max_pending} bytes pending."
  elif [[ "$max_pending" -ge "$warn_bytes" ]]; then
    record_warn "VMAgent remote-write queue is elevated: ${max_pending} bytes pending."
  else
    record_ok "VMAgent remote-write queue is healthy: ${max_pending} bytes pending."
  fi
}

check_external_secrets() {
  local ready
  if ! kubectl_rpi get clustersecretstore onepassword >/dev/null 2>&1; then
    record_failure "1Password ClusterSecretStore is missing."
    return
  fi
  ready="$(kubectl_rpi get clustersecretstore onepassword \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "$ready" == True ]]; then
    record_ok "1Password ClusterSecretStore is Ready."
  else
    record_failure "1Password ClusterSecretStore is not Ready (status=${ready:-missing})."
  fi
}

check_flux() {
  local source_json source_url source_ready root_ready controller
  if ! source_json="$(kubectl_rpi get gitrepository -n flux-system flux-system -o json 2>/dev/null)"; then
    record_failure "Flux GitRepository flux-system/flux-system is missing."
    return
  fi
  source_url="$(printf '%s' "$source_json" | jq -r '.spec.url // ""')"
  source_ready="$(printf '%s' "$source_json" | jq -r '.status.conditions[]? | select(.type == "Ready") | .status')"
  if [[ "$source_url" == "http://nas.home.ftmon.org:3000/dsheehan/home-gitops.git" && "$source_ready" == True ]]; then
    record_ok "Flux Git source is Ready from the canonical NAS repository."
  else
    record_failure "Flux source URL/status is '${source_url:-missing}'/'${source_ready:-missing}'."
  fi

  root_ready="$(kubectl_rpi get kustomization -n flux-system flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "$root_ready" == True ]]; then
    record_ok "Flux root Kustomization is Ready."
  else
    record_failure "Flux root Kustomization is not Ready (status=${root_ready:-missing})."
  fi

  for controller in source-controller kustomize-controller helm-controller notification-controller; do
    if kubectl_rpi rollout status -n flux-system "deployment/${controller}" --timeout=1s >/dev/null 2>&1; then
      record_ok "Flux controller ${controller} is available."
    else
      record_failure "Flux controller ${controller} is not available."
    fi
  done
}

run_section "Nodes" kubectl_rpi get nodes -o wide
run_section "Pods" kubectl_rpi get pods -A
run_section "Services" kubectl_rpi get svc -A
run_section "Persistent Volumes" kubectl_rpi get pvc -A
run_section "Ingress And Gateway Resources" kubectl_rpi get ingressroute,gateway,httproute -A
run_section "API VIP" check_api_vip
run_section "Topology" check_topology
run_section "Monitoring Daemon Coverage" check_daemonset_coverage node-exporter-prometheus-node-exporter monitoring
run_section "Monitoring Daemon Coverage" check_daemonset_coverage fluent-bit monitoring
run_section "VictoriaMetrics Endpoint Health" check_vmsingle_endpoints
run_section "Longhorn Storage Eligibility" check_longhorn_storage
run_section "CNI, Ingress, And Gateway Invariants" check_network_invariants
run_section "Filesystem Device Errors" check_filesystem_device_errors
run_section "Raspberry Pi And Root SSD Health" check_pi_health_metrics
run_section "VMAgent Queue Health" check_vmagent_queue
run_section "External Secrets And 1Password" check_external_secrets
run_section "Flux NAS Reconciliation" check_flux
run_section "Recent Events" kubectl_rpi get events -A --sort-by=.lastTimestamp

if [[ "$failures" -gt 0 ]]; then
  printf '\nCluster verification failed with %d failure(s).\n' "$failures" >&2
  exit 1
fi

printf '\nCluster verification completed successfully.\n'
