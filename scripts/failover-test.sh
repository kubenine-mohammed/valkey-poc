#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

check_prereqs

wait_for_valkey_cluster

ensure_tmp_dir
LOCAL_PORT="${LOCAL_PORT:-6379}"
PASS="$(valkey_password)"
PRIMARY="$(get_primary_pod)"
KILL_MARKER="$(repo_root)/.tmp/failover-kill-marker"
RECOVERY_FILE="$(repo_root)/.tmp/failover-recovery-time"
PROBE_LOG="$(repo_root)/.tmp/failover-probe.log"

rm -f "$KILL_MARKER" "$RECOVERY_FILE"
: > "$PROBE_LOG"

cleanup() {
  stop_port_forward
  rm -f "$KILL_MARKER"
}
trap cleanup EXIT

log_info "primary pod to delete: ${PRIMARY}"
log_info "starting port-forward on localhost:${LOCAL_PORT}"

start_port_forward "$LOCAL_PORT"

probe_loop() {
  local kill_seen=false
  local deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    if [[ -f "$KILL_MARKER" ]]; then
      kill_seen=true
    fi

    if valkey-cli -h 127.0.0.1 -p "$LOCAL_PORT" --no-auth-warning -a "$PASS" -c PING >>"$PROBE_LOG" 2>&1 \
      && valkey-cli -h 127.0.0.1 -p "$LOCAL_PORT" --no-auth-warning -a "$PASS" -c \
        SET "valkey-test:failover:$(date +%s%N)" ok >>"$PROBE_LOG" 2>&1; then
      if [[ "$kill_seen" == "true" && ! -f "$RECOVERY_FILE" ]]; then
        date +%s > "$RECOVERY_FILE"
        return 0
      fi
    fi
    sleep 0.5
  done
  return 1
}

probe_loop &
PROBE_PID=$!

sleep 1
T_KILL="$(date +%s)"
touch "$KILL_MARKER"
log_info "deleting primary pod ${PRIMARY} at epoch ${T_KILL}"
kubectl delete pod -n "$VALKEY_NAMESPACE" "$PRIMARY" --wait=false

if ! wait "$PROBE_PID"; then
  log_error "failover probe did not observe a successful write within the timeout window"
  log_error "probe log tail:"
  tail -n 20 "$PROBE_LOG" || true
  exit 1
fi

T_OK="$(cat "$RECOVERY_FILE")"
RECOVERY_TIME_SECONDS=$((T_OK - T_KILL))

wait_for_valkey_cluster

PROMOTED="$(get_primary_pod)"
WRITE_SUCCESS="yes"

log_info "RECOVERY_TIME_SECONDS=${RECOVERY_TIME_SECONDS}"
log_info "promoted replica (new primary pod): ${PROMOTED}"

emit_doc_row "$RECOVERY_TIME_SECONDS" "$PROMOTED" "$WRITE_SUCCESS"

if (( RECOVERY_TIME_SECONDS > 30 )); then
  log_error "recovery took ${RECOVERY_TIME_SECONDS}s (limit 30s)"
  exit 1
fi

log_info "failover test passed"
