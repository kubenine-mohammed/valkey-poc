#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

check_prereqs

wait_for_valkey_cluster

KEY="valkey-test:replication"
VAL="ok-$(date +%s)"
PASS="$(valkey_password)"

PRIMARY="$(get_primary_pod)"
log_info "primary pod: ${PRIMARY}"

log_info "writing ${KEY}=${VAL} on primary ${PRIMARY}"
valkey_cli_cluster_in_pod "$PRIMARY" SET "$KEY" "$VAL"

log_info "waiting for replica acknowledgement (WAIT 2 5000)"
valkey_cli_cluster_in_pod "$PRIMARY" WAIT 2 5000

REPLICAS="$(get_replica_pods "$PRIMARY")"
if [[ -z "$REPLICAS" ]]; then
  log_error "no replica pods found"
  diagnose_cluster_roles
  exit 1
fi

FAILURES=0
while IFS= read -r replica; do
  [[ -z "$replica" ]] && continue
  log_info "reading ${KEY} from replica ${replica}"
  GOT="$(valkey_exec "$replica" sh -c "printf 'READONLY\r\nGET ${KEY}\r\n' | valkey-cli --no-auth-warning -a '${PASS}' -h 127.0.0.1 -p 6379 2>/dev/null | tail -n1")"
  if [[ "$GOT" != "$VAL" ]]; then
    log_error "replica ${replica}: expected '${VAL}', got '${GOT}'"
    FAILURES=$((FAILURES + 1))
  else
    log_info "replica ${replica}: OK"
  fi
done <<< "$REPLICAS"

if (( FAILURES > 0 )); then
  log_error "${FAILURES} replica(s) failed replication check"
  diagnose_cluster_roles
  exit 1
fi

log_info "replication verification passed"
