#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

USE_HELM=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [--helm]

Install hyperspike valkey-operator ${VALKEY_OPERATOR_VERSION} on the current cluster.

Options:
  --helm   Install via Helm OCI chart instead of release install.yaml
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --helm)
      USE_HELM=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

check_prereqs "$USE_HELM"

log_info "installing hyperspike valkey-operator ${VALKEY_OPERATOR_VERSION}"

kubectl create namespace "$OPERATOR_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if [[ "$USE_HELM" == "true" ]]; then
  if [[ -f "${ROOT}/vendor/valkey-operator/Chart.yaml" ]]; then
    log_info "Chart.yaml found in vendor/valkey-operator; using Helm OCI chart"
  fi
  helm upgrade --install valkey-operator "$HELM_CHART" \
    --namespace "$OPERATOR_NAMESPACE" \
    --create-namespace \
    --version "${VALKEY_OPERATOR_VERSION}-chart" \
    --wait --timeout 5m
  log_install_method "helm upgrade --install valkey-operator ${HELM_CHART} --namespace ${OPERATOR_NAMESPACE} --create-namespace --version ${VALKEY_OPERATOR_VERSION}-chart"
else
  if [[ -f "${ROOT}/vendor/valkey-operator/install.yaml" ]]; then
    log_info "applying vendor/valkey-operator/install.yaml"
    kubectl apply -f "${ROOT}/vendor/valkey-operator/install.yaml"
    log_install_method "kubectl apply -f vendor/valkey-operator/install.yaml"
  elif [[ -f "${ROOT}/vendor/valkey-operator/dist/install.yaml" ]]; then
    log_info "applying vendor/valkey-operator/dist/install.yaml"
    kubectl apply -f "${ROOT}/vendor/valkey-operator/dist/install.yaml"
    log_install_method "kubectl apply -f vendor/valkey-operator/dist/install.yaml"
  else
    log_info "applying release install.yaml from ${INSTALL_YAML_URL}"
    kubectl apply -f "$INSTALL_YAML_URL"
    log_install_method "kubectl apply -f ${INSTALL_YAML_URL}"
  fi
fi

wait_for_operator

log_info "operator install complete"
kubectl get pods -n "$OPERATOR_NAMESPACE" -o wide
cat "$(repo_root)/.tmp/install-method.log"
