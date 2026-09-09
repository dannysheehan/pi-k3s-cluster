#!/usr/bin/env bash

# Validate the alerting pipeline. The default mode is read-only. Pass --live to
# send temporary ntfy alerts and a healthchecks.io failure/recovery pair.
set -euo pipefail

KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config-rpi}"
LIVE_TEST=false

usage() {
  cat <<'EOF'
Usage: ./scripts/test-alerting.sh [--live]

Without --live, verify Watchdog, Alertmanager webhook counters, and the latest
cluster heartbeat. With --live, also send and resolve temporary warning and
critical alerts, verify them on ntfy, signal heartbeat failure/recovery, and
run a disposable in-cluster heartbeat Job.
EOF
}

case "${1:-}" in
  "") ;;
  --live) LIVE_TEST=true ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

for command in kubectl jq curl sed; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf '%s is required but not installed.\n' "$command" >&2
    exit 1
  fi
done

if [[ ! -f "$KUBECONFIG_PATH" ]]; then
  printf 'Kubeconfig not found at %s.\n' "$KUBECONFIG_PATH" >&2
  exit 1
fi

kubectl_rpi() {
  kubectl --kubeconfig "$KUBECONFIG_PATH" "$@"
}

alertmanager_pod="$(kubectl_rpi -n monitoring get pod \
  -l app.kubernetes.io/component=alertmanager \
  -o jsonpath='{.items[0].metadata.name}')"
vmalert_pod="$(kubectl_rpi -n monitoring get pod \
  -l 'app.kubernetes.io/component=server,app.kubernetes.io/instance=vmalert' \
  -o jsonpath='{.items[0].metadata.name}')"

alertmanager_metrics="$(kubectl_rpi -n monitoring exec "$alertmanager_pod" -- \
  wget -qO- http://127.0.0.1:9093/metrics)"
reload_ok="$(printf '%s\n' "$alertmanager_metrics" | \
  awk '/^alertmanager_config_last_reload_successful / { print int($2) }')"
webhook_total="$(printf '%s\n' "$alertmanager_metrics" | \
  awk '/^alertmanager_notifications_total\{integration="webhook"\}/ { print int($2) }')"
webhook_failures="$(printf '%s\n' "$alertmanager_metrics" | \
  awk '/^alertmanager_notifications_failed_total\{integration="webhook"/ { sum += $2 } END { print int(sum) }')"

[[ "$reload_ok" == 1 ]] || { printf 'Alertmanager config reload is unhealthy.\n' >&2; exit 1; }
[[ "${webhook_total:-0}" -gt 0 ]] || { printf 'Alertmanager has sent no webhook notifications.\n' >&2; exit 1; }
[[ "$webhook_failures" == 0 ]] || { printf 'Alertmanager has %s webhook notification failure(s).\n' "$webhook_failures" >&2; exit 1; }

watchdog_count="$(kubectl_rpi -n monitoring exec "$vmalert_pod" -- \
  wget -qO- http://127.0.0.1:8880/api/v1/alerts | \
  jq '[.data.alerts[] | select(.name == "Watchdog" and .state == "firing")]|length')"
[[ "$watchdog_count" == 1 ]] || { printf 'Expected one firing Watchdog alert; found %s.\n' "$watchdog_count" >&2; exit 1; }

last_heartbeat="$(kubectl_rpi -n monitoring get cronjob cluster-heartbeat \
  -o jsonpath='{.status.lastSuccessfulTime}')"
[[ -n "$last_heartbeat" ]] || { printf 'cluster-heartbeat has no successful run.\n' >&2; exit 1; }

printf 'OK: Alertmanager config is healthy; webhook notifications=%s, failures=0.\n' "$webhook_total"
printf 'OK: Watchdog is firing and the cluster heartbeat last succeeded at %s.\n' "$last_heartbeat"

if [[ "$LIVE_TEST" != true ]]; then
  printf 'Read-only alerting checks passed. Use --live to exercise external notifications.\n'
  exit 0
fi

test_id="phase-g-$(date -u +%Y%m%dT%H%M%SZ)"
heartbeat_url="$(kubectl_rpi -n monitoring get cronjob cluster-heartbeat \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].args[-1]}')"
case "$heartbeat_url" in
  https://hc-ping.com/*|https://healthchecks.io/*) ;;
  *) printf 'Unexpected heartbeat URL host; refusing live test.\n' >&2; exit 1 ;;
esac

alertmanager_config="$(kubectl_rpi -n monitoring exec "$alertmanager_pod" -- \
  cat /config/alertmanager.yaml)"
ntfy_base="$(printf '%s\n' "$alertmanager_config" | \
  sed -nE 's|.*(https://ntfy\.sh/[^?"[:space:]]+).*|\1|p' | head -n1)"
[[ -n "$ntfy_base" ]] || { printf 'Could not locate the configured ntfy endpoint.\n' >&2; exit 1; }

job_name=""
heartbeat_failed=false
alerts_active=false

post_test_alerts() {
  local starts_at="$1" ends_at="$2" payload
  payload="$(jq -nc \
    --arg id "$test_id" --arg start "$starts_at" --arg end "$ends_at" '[
      {labels:{alertname:"PhaseGWarningTest",severity:"warning",test_id:$id},annotations:{summary:("Phase G temporary warning notification test " + $id)},startsAt:$start,endsAt:$end},
      {labels:{alertname:"PhaseGCriticalTest",severity:"critical",test_id:$id},annotations:{summary:("Phase G temporary critical notification test " + $id)},startsAt:$start,endsAt:$end}
    ]')"
  kubectl_rpi -n monitoring exec "$alertmanager_pod" -- \
    wget -qO- --header='Content-Type: application/json' --post-data="$payload" \
    http://127.0.0.1:9093/api/v2/alerts >/dev/null
}

cleanup() {
  local now
  set +e
  if [[ "$alerts_active" == true ]]; then
    now="$(date -u +%FT%TZ)"
    post_test_alerts "$now" "$now"
  fi
  if [[ "$heartbeat_failed" == true ]]; then
    curl -fsS --connect-timeout 5 --max-time 15 -o /dev/null "$heartbeat_url"
  fi
  if [[ -n "$job_name" ]]; then
    kubectl_rpi -n monitoring delete job "$job_name" --wait=false >/dev/null
  fi
}
trap cleanup EXIT INT TERM

starts_at="$(date -u +%FT%TZ)"
ends_at="$(date -u -d '+10 minutes' +%FT%TZ)"
post_test_alerts "$starts_at" "$ends_at"
alerts_active=true

for _ in $(seq 1 15); do
  active_count="$(kubectl_rpi -n monitoring exec "$alertmanager_pod" -- \
    wget -qO- http://127.0.0.1:9093/api/v2/alerts | \
    jq --arg id "$test_id" '[.[] | select(.labels.test_id == $id and .status.state == "active")]|length')"
  [[ "$active_count" == 2 ]] && break
  sleep 2
done
[[ "$active_count" == 2 ]] || { printf 'Temporary alerts did not become active.\n' >&2; exit 1; }

# Alertmanager's configured group_wait is 30 seconds.
sleep 35
ntfy_messages="$(curl -fsS --connect-timeout 5 --max-time 15 \
  "${ntfy_base}/json?poll=1&since=10m")"
warning_matches="$(printf '%s\n' "$ntfy_messages" | jq -s --arg id "$test_id" \
  '[.[] | select((.title // "") | contains("PhaseGWarningTest")) | select((.message // "") | contains($id)) | select(.priority == 3)]|length')"
critical_matches="$(printf '%s\n' "$ntfy_messages" | jq -s --arg id "$test_id" \
  '[.[] | select((.title // "") | contains("PhaseGCriticalTest")) | select((.message // "") | contains($id)) | select(.priority == 5)]|length')"
[[ "$warning_matches" -ge 1 && "$critical_matches" -ge 1 ]] || {
  printf 'Expected ntfy warning and critical deliveries were not both observed.\n' >&2
  exit 1
}
printf 'OK: ntfy received warning/default and critical/urgent alerts for %s.\n' "$test_id"

now="$(date -u +%FT%TZ)"
post_test_alerts "$now" "$now"
alerts_active=false

failure_status="$(curl -sS --connect-timeout 5 --max-time 15 \
  -o /dev/null -w '%{http_code}' "${heartbeat_url%/}/fail")"
[[ "$failure_status" == 200 ]] || { printf 'External heartbeat failure ping returned HTTP %s.\n' "$failure_status" >&2; exit 1; }
heartbeat_failed=true
sleep 30
recovery_status="$(curl -sS --connect-timeout 5 --max-time 15 \
  -o /dev/null -w '%{http_code}' "$heartbeat_url")"
[[ "$recovery_status" == 200 ]] || { printf 'External heartbeat recovery ping returned HTTP %s.\n' "$recovery_status" >&2; exit 1; }
heartbeat_failed=false
printf 'OK: External heartbeat accepted failure and recovery signals.\n'

job_name="cluster-heartbeat-test-$(date -u +%H%M%S)"
kubectl_rpi -n monitoring create job --from=cronjob/cluster-heartbeat "$job_name" >/dev/null
kubectl_rpi -n monitoring wait --for=condition=Complete "job/$job_name" --timeout=120s >/dev/null
kubectl_rpi -n monitoring delete job "$job_name" --wait=true >/dev/null
job_name=""
printf 'OK: Disposable in-cluster heartbeat Job completed and was removed.\n'
printf 'Live alerting smoke test passed; temporary alerts were resolved.\n'
