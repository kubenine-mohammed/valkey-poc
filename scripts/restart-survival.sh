#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

check_prereqs

wait_for_valkey_cluster

KEY="valkey-test:persistence"
VAL="before-restart-$(date +%s)"
PASS="$(valkey_password)"
POD="$(get_any_valkey_pod)"
SERVICE_HOST="${VALKEY_NAME}.${VALKEY_NAMESPACE}.svc.cluster.local"

log_info "writing persistence key via service ${SERVICE_HOST}"
valkey_exec "$POD" valkey-cli --no-auth-warning -a "$PASS" -h "$SERVICE_HOST" -c SET "$KEY" "$VAL"

ORIG_REPLICAS="$(kubectl get sts "$VALKEY_NAME" -n "$VALKEY_NAMESPACE" -o jsonpath='{.spec.replicas}')"
log_info "scaling StatefulSet ${VALKEY_NAME} from ${ORIG_REPLICAS} to 0"
kubectl scale sts "$VALKEY_NAME" -n "$VALKEY_NAMESPACE" --replicas=0

log_info "waiting for Valkey pods to be deleted (180s timeout)"
deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
  remaining="$(kubectl get pods -n "$VALKEY_NAMESPACE" -l "$POD_LABEL_SELECTOR" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$remaining" -eq 0 ]]; then
    break
  fi
  sleep 2
done

remaining="$(kubectl get pods -n "$VALKEY_NAMESPACE" -l "$POD_LABEL_SELECTOR" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$remaining" -ne 0 ]]; then
  log_error "expected all Valkey pods deleted, ${remaining} remain"
  kubectl get pods -n "$VALKEY_NAMESPACE" -l "$POD_LABEL_SELECTOR" -o wide || true
  exit 1
fi

log_info "scaling StatefulSet ${VALKEY_NAME} back to ${ORIG_REPLICAS}"
kubectl scale sts "$VALKEY_NAME" -n "$VALKEY_NAMESPACE" --replicas="$ORIG_REPLICAS"

wait_for_valkey_cluster

POD="$(get_any_valkey_pod)"
log_info "reading persistence key back via service ${SERVICE_HOST}"
GOT="$(valkey_exec "$POD" valkey-cli --no-auth-warning -a "$PASS" -h "$SERVICE_HOST" -c GET "$KEY")"

if [[ "$GOT" != "$VAL" ]]; then
  log_error "persistence mismatch: expected '${VAL}', got '${GOT}'"
  exit 1
fi

log_info "restart survival test passed"
