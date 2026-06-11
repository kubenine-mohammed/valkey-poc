# Valkey Operator — Civo K3s HA Test Report

## Install Method

```sh
helm repo add valkey https://valkey.io/valkey-helm   # not used — hyperspike operator
kubectl create namespace valkey-operator-system --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f https://github.com/hyperspike/valkey-operator/releases/download/v0.0.61/install.yaml
kubectl wait --for=condition=Established --timeout=120s crd/valkeys.hyperspike.io
kubectl wait --for=condition=Available --timeout=300s deployment/controller-manager -n valkey-operator-system
kubectl wait --for=condition=Ready --timeout=120s pod -l control-plane=controller-manager -n valkey-operator-system
```

- Operator: [hyperspike/valkey-operator](https://github.com/hyperspike/valkey-operator)
- Release: `v0.0.61` (commit pinned in `vendor/valkey-operator/`)
- Install artifact: release `install.yaml` (Helm OCI alternative: `oci://ghcr.io/hyperspike/valkey-operator --version v0.0.61-chart`)

## Civo-Specific Findings

- **Storage class:** `civo-volume` (Civo block storage, ReadWriteOnce). Scripts fall back to the cluster default StorageClass if `civo-volume` is absent and log a warning.
- **Volume permissions:** `volumePermissions: true` on the Valkey CR avoids permission errors on Civo CSI mounts.
- **K3s:** No LoadBalancer or Ingress required; all tests use in-cluster ClusterIP services and `kubectl port-forward`.
- **Admission webhooks:** hyperspike `install.yaml` ships operator TLS/webhook configuration; first install may take ~30s before the controller Deployment becomes Available.
- **WSL runner PATH:** non-login shells may omit `/snap/bin`; export `PATH="/snap/bin:$PATH"` before running scripts, or use `bash -lc`.
- **Failover port-forward:** `kubectl port-forward` to a Service can stick to a deleted primary's endpoint; `failover-test.sh` restarts the forward after pod kill (required for reliable recovery measurement).

## Cluster Topology

```yaml
apiVersion: hyperspike.io/v1
kind: Valkey
metadata:
  name: valkey-ha
  namespace: valkey
spec:
  nodes: 1          # 1 shard (primary slot owner)
  replicas: 2       # 2 replicas per shard → 3 pods total
  anonymousAuth: false
  prometheus: false
  serviceMonitor: false
  volumePermissions: true
  clusterDomain: cluster.local
  storage:
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: civo-volume
      resources:
        requests:
          storage: 1Gi
```

- **Workload:** single StatefulSet `valkey-ha` (3 replicas)
- **Services:** `valkey-ha` (ClusterIP), `valkey-ha-headless`
- **Auth:** operator-generated Secret `valkey-ha` / key `password`

## Replication Verification

- **Key written:** `valkey-test:replication` (on current primary pod)
- **Replicas checked:** all non-primary pods (`kubectl` label selector `app.kubernetes.io/instance=valkey-ha`)
- **Result:** PASS — key read from replicas `valkey-ha-0` and `valkey-ha-2` after `WAIT 2 5000` on primary `valkey-ha-1`

## Failover Test Results

| Run | Recovery Time (s) | Promoted Replica | Write Success |
|-----|-------------------|-----------------|---------------|
| 1   | 1                 | valkey-ha-1     | yes           |

## Restart Survival

- **Result:** PASS
- **Evidence:** key `valkey-test:persistence` matched after StatefulSet scale 0 → 3; `cluster_state:ok` confirmed before read

## Go / No-Go Assessment

**Decision:** GO

**Rationale:** All five scripts passed on Civo K3s (`kubenine-intern-pinniped`): replication verified on both replicas, automatic failover recovered writes in 1 s after primary pod deletion, and persistence survived a full StatefulSet restart.

## Out of Scope (Follow-up in seperate repo)

- Multi-cluster federation
- Istio mesh integration
- Production sizing recommendations
