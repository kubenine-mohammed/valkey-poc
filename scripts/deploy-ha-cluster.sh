#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

check_prereqs

log_info "deploying Valkey HA cluster (${VALKEY_NAME})"

kubectl create namespace "$VALKEY_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

apply_valkey_manifest

wait_for_valkey_cluster

log_info "Valkey cluster is healthy"
kubectl get valkeys "$VALKEY_NAME" -n "$VALKEY_NAMESPACE" -o wide || true
kubectl get pods -n "$VALKEY_NAMESPACE" -l "$POD_LABEL_SELECTOR" -o wide || true

echo "---"
kubectl get valkeys "$VALKEY_NAME" -n "$VALKEY_NAMESPACE" -o yaml
