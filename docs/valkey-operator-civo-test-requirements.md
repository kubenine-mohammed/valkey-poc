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
- **Upstream replica caveat:** [hyperspike/valkey-operator#186](https://github.com/hyperspike/valkey-operator/issues/186) — on some releases all pods may report `role:master` instead of primary+replica. `verify-replication.sh` fails with a `CLUSTER NODES` dump if replication topology is wrong (not a Civo-specific issue).

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
- **Result:** TBD

## Failover Test Results

| Run | Recovery Time (s) | Promoted Replica | Write Success |
|-----|-------------------|-----------------|---------------|
| 1   | TBD               | TBD             | TBD           |

## Restart Survival

- **Result:** TBD
- **Evidence:** TBD (key `valkey-test:persistence` before/after StatefulSet scale 0 → N)

## Go / No-Go Assessment

**Decision:** TBD

**Rationale:** TBD — populated after CI run completes `verify-replication.sh`, `failover-test.sh`, and `restart-survival.sh`.

## Out of Scope (Follow-up in seperate repo)

- Multi-cluster federation
- Istio mesh integration
- Production sizing recommendations
