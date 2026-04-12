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

replicas_file="$(mktemp)"
volumes_file="$(mktemp)"
nodes_file="$(mktemp)"
trap 'rm -f "$replicas_file" "$volumes_file" "$nodes_file"' EXIT

kubectl --kubeconfig "$KUBECONFIG_PATH" get replicas.longhorn.io -n longhorn-system -o wide --no-headers > "$replicas_file"
kubectl --kubeconfig "$KUBECONFIG_PATH" get volumes.longhorn.io -n longhorn-system -o wide --no-headers > "$volumes_file"
kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes.longhorn.io -n longhorn-system -o json \
  | jq -r '
      .items[]
      | .metadata.name as $node
      | (.status.diskStatus // {})
      | to_entries[]
      | "\($node)\t\(.value.storageScheduled // 0)"
    ' > "$nodes_file"

printf '\n== Longhorn Volumes ==\n'
kubectl --kubeconfig "$KUBECONFIG_PATH" get volumes.longhorn.io -n longhorn-system -o wide

printf '\n== Replica Count By Node ==\n'
awk '
  { count[$4]++ }
  END {
    for (node in count) {
      printf "%4d  %s\n", count[node], node
    }
  }
' "$replicas_file" | sort -k2

printf '\n== Scheduled Replica Bytes By Node ==\n'
awk '{ printf "%15s  %s\n", $2, $1 }' "$nodes_file" | sort -nr

printf '\n== Replica Placement By Volume ==\n'
awk '
  {
    split($1, parts, "-r-");
    vol = parts[1];
    placements[vol] = placements[vol] sprintf("%s%s", (placements[vol] ? ", " : ""), $4);
  }
  END {
    for (vol in placements) {
      printf "%-40s %s\n", vol, placements[vol]
    }
  }
' "$replicas_file" | sort

printf '\n== Multi-Replica Volumes Missing Node Spread ==\n'
awk '
  {
    split($1, parts, "-r-");
    vol = parts[1];
    key = vol SUBSEP $4;
    if (!(key in seen)) {
      seen[key] = 1;
      uniq_nodes[vol]++
    }
    replicas[vol]++
  }
  END {
    for (vol in replicas) {
      if (replicas[vol] > 1 && uniq_nodes[vol] < replicas[vol]) {
        printf "%-40s replicas=%d unique_nodes=%d\n", vol, replicas[vol], uniq_nodes[vol]
      }
    }
  }
' "$replicas_file" | sort

cat <<EOF

Interpretation:
1. Compare attached volume owners in 'Longhorn Volumes' with replica placement; owner concentration can still overload one node even when replicas are spread.
2. High scheduled bytes on one node means future rebuilds and replica syncs will also hit that node harder.
3. If this output stays skewed after rebalancing windows, enable or keep replica auto-balance and reduce rebuild concurrency.
EOF
