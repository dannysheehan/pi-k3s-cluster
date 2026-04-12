#!/usr/bin/env bash

set -euo pipefail

KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config-rpi}"
TARGET_NODE="${1:-}"
EVENT_LIMIT="${EVENT_LIMIT:-120}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required but not installed." >&2
  exit 1
fi

if [[ ! -f "$KUBECONFIG_PATH" ]]; then
  echo "Kubeconfig not found at: $KUBECONFIG_PATH" >&2
  echo "Set KUBECONFIG or place the cluster config at ~/.kube/config-rpi" >&2
  exit 1
fi

if [[ -z "$TARGET_NODE" ]]; then
  echo "Usage: $0 <node-name>" >&2
  echo "Example: $0 k3s-wrk-03-f118e128" >&2
  exit 1
fi

run_section() {
  local title="$1"
  shift
  printf '\n== %s ==\n' "$title"
  "$@"
}

run_section "Node Top" kubectl --kubeconfig "$KUBECONFIG_PATH" top nodes | awk -v node="$TARGET_NODE" 'NR==1 || $1==node'

run_section "Pods On Node" kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -A -o wide | awk -v node="$TARGET_NODE" '$8==node'

run_section "Joined Pod Top View" bash -lc '
  pods_file="$(mktemp)"
  top_file="$(mktemp)"
  trap "rm -f \"$pods_file\" \"$top_file\"" EXIT
  kubectl --kubeconfig "$1" get pods -A -o wide > "$pods_file"
  kubectl --kubeconfig "$1" top pods -A --sort-by=cpu > "$top_file"
  awk -v node="$2" "
    FNR==NR {
      if (FNR > 1) {
        key = \$1 \"/\" \$2;
        cpu[key] = \$3;
        mem[key] = \$4;
      }
      next;
    }
    FNR > 1 && \$8 == node {
      key = \$1 \"/\" \$2;
      printf \"%-20s %-48s %-10s %-10s %-10s %-10s\n\", \$1, \$2, \$4, \$5, cpu[key], mem[key];
    }
  " "$top_file" "$pods_file" | sort -k5 -hr
' bash "$KUBECONFIG_PATH" "$TARGET_NODE"

run_section "Recent Node Events" kubectl --kubeconfig "$KUBECONFIG_PATH" get events -A --sort-by=.lastTimestamp | tail -n "$EVENT_LIMIT" | grep "$TARGET_NODE" || true

run_section "Longhorn Volumes On Node" kubectl --kubeconfig "$KUBECONFIG_PATH" get volumes.longhorn.io -n longhorn-system -o wide | awk -v node="$TARGET_NODE" 'NR==1 || $7==node'

cat <<EOF

Interpretation:
1. If node CPU is persistently >80%, probe tuning alone will not stabilize the node.
2. If many Longhorn volumes are attached to one worker, spread storage-backed apps before adding more.
3. If node-scoped warnings line up with probe failures across unrelated workloads, debug the node before the app.
EOF
