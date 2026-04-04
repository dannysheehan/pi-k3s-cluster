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

run_section "Nodes" kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes -o wide
run_section "Pods" kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -A
run_section "Services" kubectl --kubeconfig "$KUBECONFIG_PATH" get svc -A
run_section "Persistent Volumes" kubectl --kubeconfig "$KUBECONFIG_PATH" get pvc -A
run_section "Ingress And Gateway Resources" kubectl --kubeconfig "$KUBECONFIG_PATH" get ingressroute,gateway,httproute -A
run_section "Recent Events" kubectl --kubeconfig "$KUBECONFIG_PATH" get events -A --sort-by=.lastTimestamp
