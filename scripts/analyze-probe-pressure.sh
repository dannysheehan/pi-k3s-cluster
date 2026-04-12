#!/usr/bin/env bash

set -euo pipefail

KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config-rpi}"
EVENT_LIMIT="${EVENT_LIMIT:-300}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required but not installed." >&2
  exit 1
fi

if [[ ! -f "$KUBECONFIG_PATH" ]]; then
  echo "Kubeconfig not found at: $KUBECONFIG_PATH" >&2
  echo "Set KUBECONFIG or place the cluster config at ~/.kube/config-rpi" >&2
  exit 1
fi

events_file="$(mktemp)"
pods_file="$(mktemp)"
trap 'rm -f "$events_file" "$pods_file"' EXIT

kubectl --kubeconfig "$KUBECONFIG_PATH" get events -A --sort-by=.lastTimestamp --no-headers > "$events_file"
kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -A --no-headers > "$pods_file"

printf '\n== Recent Warning Event Summary ==\n'
tail -n "$EVENT_LIMIT" "$events_file" | \
  awk '$3 == "Warning" { print $4 "\t" $5 }' | \
  sort | uniq -c | sort -nr | \
  awk '{ printf "%4s  %-24s %s\n", $1, $2, $3 }'

printf '\n== Recent Warning Events ==\n'
tail -n "$EVENT_LIMIT" "$events_file" | awk '$3 == "Warning"'

printf '\n== Pods Not Fully Ready ==\n'
awk '
  {
    split($3, ready, "/");
    if (ready[1] != ready[2] || $4 != "Running") {
      print $0;
    }
  }
' "$pods_file"

printf '\n== Pods With Restarts ==\n'
awk '
  {
    if ($5 != "0") {
      print $0;
    }
  }
' "$pods_file"

cat <<EOF

Best practice:
1. Increase readiness timeout and failureThreshold before touching liveness.
2. Add startup probes for slow-booting apps so liveness does not kill them during initialization.
3. Treat storage and CSI failures separately from app probes; mount failures often start there.
4. Tune workloads managed by this repo first, rerun this script, then compare the warning summary.
EOF
