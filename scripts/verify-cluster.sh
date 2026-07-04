#!/usr/bin/env bash

set -euo pipefail

KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config-rpi}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required but not installed." >&2
  exit 1
fi

if [[ ! -f "$KUBECONFIG_PATH" ]]; then
  echo "Kubeconfig not found at: $KUBECONFIG_PATH" >&2
  echo "Set KUBECONFIG or place the cluster config at ~/.kube/config-rpi" >&2
  exit 1
fi

run_section() {
  local title="$1"
  shift
  printf '\n== %s ==\n' "$title"
  "$@"
}

failures=0

record_failure() {
  local message="$1"
  printf 'FAIL: %s\n' "$message" >&2
  failures=$((failures + 1))
}

record_ok() {
  local message="$1"
  printf 'OK: %s\n' "$message"
}

record_warn() {
  local message="$1"
  printf 'WARN: %s\n' "$message" >&2
}

kubectl_rpi() {
  kubectl --kubeconfig "$KUBECONFIG_PATH" "$@"
}

check_node_readiness() {
  local not_ready
  not_ready="$(
    kubectl_rpi get nodes --no-headers 2>/dev/null |
      awk '$2 != "Ready" { printf "%s(%s) ", $1, $2 }'
  )"

  if [[ -z "$not_ready" ]]; then
    record_ok "All nodes are Ready."
  else
    record_failure "Node(s) not Ready: ${not_ready}"
    kubectl_rpi describe nodes | grep -A6 '^Conditions:' || true
  fi
}

# node_filesystem_device_error flips to 1 the moment a mounted filesystem
# starts returning I/O errors — hours or days before workloads visibly fail
# (2026-06-30 k3s-wrk-01 SSD disconnect went unnoticed for 4.5 days).
check_filesystem_device_errors() {
  local response

  if ! response="$(
    kubectl_rpi exec -n monitoring deploy/vmagent-victoria-metrics-agent -- \
      wget -qO- --post-data 'query=node_filesystem_device_error{mountpoint=~"/|/mnt/ssd|/var"} > 0' \
      http://vmsingle-victoria-metrics-single-server.monitoring.svc:8428/api/v1/query 2>/dev/null
  )"; then
    record_warn "Unable to query VictoriaMetrics for filesystem device errors."
    return
  fi

  if ! printf '%s' "$response" | grep -q '"status":"success"'; then
    record_warn "Filesystem device error query did not return success: ${response}"
    return
  fi

  if printf '%s' "$response" | grep -q '"result":\[\]'; then
    record_ok "No filesystem device errors reported on monitored mounts."
  else
    record_failure "Filesystem device error(s) detected: $(
      printf '%s' "$response" |
        grep -oE '"(instance|mountpoint|device)":"[^"]*"' | tr '\n' ' '
    )"
  fi
}

check_vmsingle_endpoints() {
  local endpoint_count

  endpoint_count="$(
    kubectl_rpi get endpoints -n monitoring vmsingle-victoria-metrics-single-server \
      -o jsonpath='{range .subsets[*].addresses[*]}1{"\n"}{end}' 2>/dev/null | wc -l
  )"

  if [[ "$endpoint_count" -gt 0 ]]; then
    record_ok "VictoriaMetrics vmsingle has $endpoint_count ready endpoint(s)."
  else
    record_failure "VictoriaMetrics vmsingle has no ready Service endpoints."
    kubectl_rpi get pods,endpoints -n monitoring -l app.kubernetes.io/instance=vmsingle -o wide || true
  fi
}

check_vmagent_queue() {
  local metrics pending_values max_pending warn_bytes critical_bytes

  if ! kubectl_rpi get deployment -n monitoring vmagent-victoria-metrics-agent >/dev/null 2>&1; then
    record_warn "VMAgent deployment not found; skipping queue checks."
    return
  fi

  if ! kubectl_rpi get pods -n monitoring -l app.kubernetes.io/instance=vmagent \
    -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' | grep -q .; then
    record_failure "VMAgent has no running pod for queue checks."
    kubectl_rpi get pods -n monitoring -l app.kubernetes.io/instance=vmagent -o wide || true
    return
  fi

  if ! metrics="$(
    kubectl_rpi exec -n monitoring deploy/vmagent-victoria-metrics-agent -- \
      wget -qO- http://127.0.0.1:8429/metrics
  )"; then
    record_failure "Unable to read VMAgent self-metrics from http://127.0.0.1:8429/metrics."
    return
  fi

  pending_values="$(
    printf '%s\n' "$metrics" |
      awk '
        /^vmagent_remotewrite_pending_data_bytes\{/ { print int($2) }
        /^vm_persistentqueue_bytes_pending\{/ { print int($2) }
      '
  )"

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

  printf '%s\n' "$metrics" |
    awk '
      /^vmagent_remotewrite_pending_data_bytes\{/ ||
      /^vm_persistentqueue_bytes_pending\{/ ||
      /^vmagent_remotewrite_requests_total\{/ ||
      /^vmagent_remotewrite_retries_count_total\{/ {
        print
      }
    '
}

run_section "Nodes" kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes -o wide
run_section "Pods" kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -A
run_section "Services" kubectl --kubeconfig "$KUBECONFIG_PATH" get svc -A
run_section "Persistent Volumes" kubectl --kubeconfig "$KUBECONFIG_PATH" get pvc -A
run_section "Ingress And Gateway Resources" kubectl --kubeconfig "$KUBECONFIG_PATH" get ingressroute,gateway,httproute -A
run_section "Node Readiness" check_node_readiness
run_section "Filesystem Device Errors" check_filesystem_device_errors
run_section "VictoriaMetrics Endpoint Health" check_vmsingle_endpoints
run_section "VMAgent Queue Health" check_vmagent_queue
run_section "Recent Events" kubectl --kubeconfig "$KUBECONFIG_PATH" get events -A --sort-by=.lastTimestamp

if [[ "$failures" -gt 0 ]]; then
  printf '\nCluster verification failed with %d failure(s).\n' "$failures" >&2
  exit 1
fi

printf '\nCluster verification completed successfully.\n'
