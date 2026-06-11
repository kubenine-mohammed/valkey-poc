#!/usr/bin/env bash
# Shared helpers for valkey-poc scripts.
set -euo pipefail

VALKEY_OPERATOR_VERSION="${VALKEY_OPERATOR_VERSION:-v0.0.61}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-valkey-operator-system}"
VALKEY_NAMESPACE="${VALKEY_NAMESPACE:-valkey}"
VALKEY_NAME="${VALKEY_NAME:-valkey-ha}"
STORAGE_CLASS="${STORAGE_CLASS:-civo-volume}"
INSTALL_YAML_URL="https://github.com/hyperspike/valkey-operator/releases/download/${VALKEY_OPERATOR_VERSION}/install.yaml"
HELM_CHART="oci://ghcr.io/hyperspike/valkey-operator"
EXPECTED_REPLICAS="${EXPECTED_REPLICAS:-3}"
POD_LABEL_SELECTOR="app.kubernetes.io/instance=${VALKEY_NAME},app.kubernetes.io/name=valkey"

_VALKEY_POC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

repo_root() {
  printf '%s' "$_VALKEY_POC_ROOT"
}

ensure_tmp_dir() {
  mkdir -p "$(repo_root)/.tmp"
}

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

log_info() {
  log "INFO: $*"
}

log_warn() {
  log "WARN: $*" >&2
}

log_error() {
  log "ERROR: $*" >&2
}

check_prereqs() {
  local require_helm="${1:-false}"
  local missing=()
  local cmd

  for cmd in kubectl jq valkey-cli; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [[ "$require_helm" == "true" ]] && ! command -v helm >/dev/null 2>&1; then
    missing+=("helm")
  fi

  if (( ${#missing[@]} > 0 )); then
    log_error "missing required tools: ${missing[*]}"
    log_error "See docs/README.md#prerequisites for install instructions."
    exit 1
  fi
}

valkey_password() {
  kubectl get secret "$VALKEY_NAME" -n "$VALKEY_NAMESPACE" \
    -o jsonpath='{.data.password}' | base64 -d
}

list_valkey_pods() {
  kubectl get pods -n "$VALKEY_NAMESPACE" -l "$POD_LABEL_SELECTOR" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort
}

get_any_valkey_pod() {
  local pod
  pod="$(list_valkey_pods | head -n1 || true)"
  if [[ -z "$pod" ]]; then
    log_error "no running Valkey pods found in namespace ${VALKEY_NAMESPACE}"
    exit 1
  fi
  printf '%s' "$pod"
}

valkey_exec() {
  local pod="$1"
  shift
  kubectl exec -n "$VALKEY_NAMESPACE" "$pod" -c valkey -- "$@"
}

valkey_cli_in_pod() {
  local pod="$1"
  shift
  local pass
  pass="$(valkey_password)"
  valkey_exec "$pod" valkey-cli --no-auth-warning -a "$pass" "$@"
}

valkey_cli_cluster_in_pod() {
  local pod="$1"
  shift
  local pass
  pass="$(valkey_password)"
  valkey_exec "$pod" valkey-cli --no-auth-warning -a "$pass" -c "$@"
}

pod_ip() {
  local pod="$1"
  kubectl get pod "$pod" -n "$VALKEY_NAMESPACE" -o jsonpath='{.status.podIP}'
}

cluster_nodes_from_pod() {
  local pod="$1"
  valkey_cli_cluster_in_pod "$pod" CLUSTER NODES
}

is_primary_pod() {
  local pod="$1"
  local nodes myself_line
  nodes="$(cluster_nodes_from_pod "$pod")"
  myself_line="$(echo "$nodes" | grep 'myself,' || true)"
  [[ -n "$myself_line" ]] || return 1
  echo "$myself_line" | grep -q 'myself,slave' && return 1
  echo "$myself_line" | grep -qE '[0-9]+-[0-9]+'
}

get_primary_pod() {
  local pod primary_count=0 primary=""
  for pod in $(list_valkey_pods); do
    if is_primary_pod "$pod"; then
      primary="$pod"
      primary_count=$((primary_count + 1))
    fi
  done
  if [[ "$primary_count" -eq 1 ]]; then
    printf '%s' "$primary"
    return 0
  fi
  log_error "expected exactly one primary pod, found ${primary_count}"
  diagnose_cluster_roles
  exit 1
}

get_replica_pods() {
  local primary="$1"
  local pod
  for pod in $(list_valkey_pods); do
    if [[ "$pod" != "$primary" ]]; then
      printf '%s\n' "$pod"
    fi
  done
}

diagnose_cluster_roles() {
  local pod
  log_info "CLUSTER NODES snapshot:"
  for pod in $(list_valkey_pods); do
    log_info "--- ${pod} ---"
    cluster_nodes_from_pod "$pod" || true
  done
}

resolve_storage_class() {
  if kubectl get storageclass "$STORAGE_CLASS" >/dev/null 2>&1; then
    log_info "using storage class: ${STORAGE_CLASS}"
    printf '%s' "$STORAGE_CLASS"
    return 0
  fi

  local fallback
  fallback="$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$fallback" ]]; then
    fallback="$(kubectl get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  fi

  if [[ -z "$fallback" ]]; then
    log_error "storage class ${STORAGE_CLASS} not found and no fallback storage class detected"
    exit 1
  fi

  log_warn "storage class ${STORAGE_CLASS} not found; falling back to ${fallback}"
  printf '%s' "$fallback"
}

apply_valkey_manifest() {
  local root manifest resolved_sc tmp_manifest
  root="$(repo_root)"
  manifest="${root}/manifests/valkey-ha.yaml"
  resolved_sc="$(resolve_storage_class)"
  tmp_manifest="$(mktemp)"
  sed "s/storageClassName: ${STORAGE_CLASS}/storageClassName: ${resolved_sc}/" "$manifest" > "$tmp_manifest"
  kubectl apply -f "$tmp_manifest"
  rm -f "$tmp_manifest"
}

wait_for_operator() {
  log_info "waiting for CRD valkeys.hyperspike.io to become Established (120s timeout)"
  kubectl wait --for=condition=Established --timeout=120s crd/valkeys.hyperspike.io

  log_info "waiting for operator deployment(s) in ${OPERATOR_NAMESPACE} (300s timeout)"
  local deployments
  deployments="$(kubectl get deployment -n "$OPERATOR_NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
  if [[ -z "$deployments" ]]; then
    log_error "no deployments found in namespace ${OPERATOR_NAMESPACE}"
    exit 1
  fi

  local dep
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    kubectl wait --for=condition=Available --timeout=300s \
      "deployment/${dep}" -n "$OPERATOR_NAMESPACE"
  done <<< "$deployments"

  log_info "waiting for operator pod Ready (120s timeout)"
  kubectl wait --for=condition=Ready --timeout=120s \
    pod -l control-plane=controller-manager -n "$OPERATOR_NAMESPACE"
}

wait_for_valkey_cluster() {
  log_info "waiting for Valkey CR status.ready=true (600s timeout)"
  kubectl wait --for=jsonpath='{.status.ready}'=true --timeout=600s \
    "valkeys/${VALKEY_NAME}" -n "$VALKEY_NAMESPACE"

  log_info "waiting for ${EXPECTED_REPLICAS} Valkey pods Ready (600s timeout)"
  local ready_count=0
  local deadline=$((SECONDS + 600))
  while (( SECONDS < deadline )); do
    ready_count="$(kubectl get pods -n "$VALKEY_NAMESPACE" -l "$POD_LABEL_SELECTOR" \
      --field-selector=status.phase=Running \
      -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready")].status=="True")]}{.metadata.name}{"\n"}{end}' | wc -l | tr -d ' ')"
    if [[ "$ready_count" -ge "$EXPECTED_REPLICAS" ]]; then
      break
    fi
    sleep 5
  done

  if [[ "$ready_count" -lt "$EXPECTED_REPLICAS" ]]; then
    log_error "expected ${EXPECTED_REPLICAS} ready pods, found ${ready_count}"
    kubectl get pods -n "$VALKEY_NAMESPACE" -l "$POD_LABEL_SELECTOR" -o wide || true
    exit 1
  fi

  local sts_ready
  sts_ready="$(kubectl get sts "$VALKEY_NAME" -n "$VALKEY_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [[ "$sts_ready" != "$EXPECTED_REPLICAS" ]]; then
    log_error "StatefulSet ${VALKEY_NAME} readyReplicas=${sts_ready}, expected ${EXPECTED_REPLICAS}"
    exit 1
  fi
}

start_port_forward() {
  local local_port="${1:-6379}"
  local pass
  pass="$(valkey_password)"
  kubectl port-forward -n "$VALKEY_NAMESPACE" "svc/${VALKEY_NAME}" "${local_port}:6379" >/dev/null 2>&1 &
  PORT_FORWARD_PID=$!
  local i
  for i in $(seq 1 30); do
    if valkey-cli -h 127.0.0.1 -p "$local_port" --no-auth-warning -a "$pass" ping 2>/dev/null | grep -q PONG; then
      return 0
    fi
    sleep 0.2
  done
  log_error "port-forward to svc/${VALKEY_NAME} did not become ready"
  kill "$PORT_FORWARD_PID" 2>/dev/null || true
  exit 1
}

stop_port_forward() {
  if [[ -n "${PORT_FORWARD_PID:-}" ]]; then
    kill "$PORT_FORWARD_PID" 2>/dev/null || true
    wait "$PORT_FORWARD_PID" 2>/dev/null || true
  fi
}

emit_doc_row() {
  local recovery_time="$1"
  local promoted_replica="$2"
  local write_success="$3"
  ensure_tmp_dir
  local csv
  csv="$(repo_root)/.tmp/failover-results.csv"
  if [[ ! -f "$csv" ]]; then
    echo "run,recovery_time_seconds,promoted_replica,write_success" > "$csv"
  fi
  local run
  run="$(($(wc -l < "$csv") ))"
  echo "${run},${recovery_time},${promoted_replica},${write_success}" >> "$csv"
}

log_install_method() {
  local method="$1"
  ensure_tmp_dir
  {
    echo "install_method=${method}"
    echo "operator_version=${VALKEY_OPERATOR_VERSION}"
    echo "timestamp=$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  } > "$(repo_root)/.tmp/install-method.log"
}
