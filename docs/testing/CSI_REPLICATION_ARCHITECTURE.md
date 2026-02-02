# CSI Replication: What Gets Replicated and Where

## Summary

**PVC and PV are NOT replicated to DR2 during normal operation.** Only the underlying RBD image data is replicated via Ceph mirroring.

## Architecture

### During Normal Replication (DR1 as Primary)

```
┌─────────────────────────────────────────────────────────────────┐
│ DR1 (Primary Cluster)                                           │
├─────────────────────────────────────────────────────────────────┤
│ ✅ Kubernetes Objects:                                          │
│    • PVC (test-replication-pvc)                                 │
│    • PV (pvc-xxxx)                                              │
│    • VolumeReplication (state: Primary)                         │
│                                                                 │
│ ✅ Storage Layer:                                               │
│    • RBD image (csi-vol-xxxx) - READ/WRITE                      │
│    • Ceph RBD mirroring agent - sending snapshots →            │
└─────────────────────────────────────────────────────────────────┘
                                 │
                                 │ Snapshot Replication
                                 │ (via RBD mirroring)
                                 ↓
┌─────────────────────────────────────────────────────────────────┐
│ DR2 (Secondary Cluster)                                         │
├─────────────────────────────────────────────────────────────────┤
│ ❌ Kubernetes Objects:                                          │
│    • NO PVC                                                     │
│    • NO PV                                                      │
│    • NO VolumeReplication                                       │
│                                                                 │
│ ✅ Storage Layer:                                               │
│    • RBD image (csi-vol-xxxx) - READ-ONLY replica               │
│    • Ceph RBD mirroring agent - receiving snapshots ←          │
└─────────────────────────────────────────────────────────────────┘
```

## Why PVC/PV Are NOT Replicated

### 1. **Different Cluster Contexts**
- PV/PVC are cluster-specific Kubernetes resources
- Each cluster has its own API server and etcd
- No automatic cross-cluster Kubernetes resource replication

### 2. **Storage vs. Control Plane Separation**
- **Control Plane (Kubernetes)**: PVC, PV, VolumeReplication objects
- **Data Plane (Ceph)**: Actual storage blocks, RBD images
- Ceph handles data replication, Kubernetes handles orchestration

### 3. **Failover Flexibility**
- During failover, DR2 needs to create **new** PVC/PV specific to its cluster
- PV names, UIDs, and references must be unique to DR2
- Allows for different configurations (storage class, access modes, etc.)

## Failover Process

### Step 1: Pre-Failover State
```
DR1: PVC → PV → RBD image (primary, read/write)
                    ↓ (mirroring)
DR2:            RBD image (secondary, read-only)
```

### Step 2: Demote DR1 (if accessible)
```bash
kubectl --context=dr1 patch volumereplication test-volume-replication \
  --type=merge -p '{"spec":{"replicationState":"secondary"}}'
```
Result: DR1 RBD image becomes secondary

### Step 3: Promote DR2
```bash
kubectl --context=dr2 patch volumereplication test-volume-replication \
  --type=merge -p '{"spec":{"replicationState":"primary"}}'
```
Result: DR2 RBD image becomes primary (read/write)

### Step 4: Create PVC/PV on DR2
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-replication-pvc  # Same name as DR1
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: rook-ceph-block
  # CSI driver will bind to the existing RBD image
```

### Step 5: Post-Failover State
```
DR1:            RBD image (secondary, read-only)
                    ↑ (reverse mirroring)
DR2: PVC → PV → RBD image (primary, read/write)
```

## Test Verification

The enhanced test script verifies this model:

```bash
make test-csi-replication
```

### Expected Output

```
8. Verifying what SHOULD and SHOULD NOT exist on DR2...

=== Kubernetes Objects (should NOT exist on DR2 during replication) ===

Checking VolumeReplication on DR2 (should NOT exist):
  ✓ Correct: No VolumeReplication on DR2

Checking PVC on DR2 (should NOT exist):
  ✓ Correct: PVC 'test-replication-pvc' does not exist on DR2

Checking PV on DR2 (should NOT exist):
  ✓ Correct: PV pvc-xxxx does not exist on DR2

=== Storage Layer (SHOULD exist on DR2 via RBD mirroring) ===

Explanation:
  During normal replication:
    • Kubernetes objects (PVC/PV/VR) exist ONLY on primary cluster (DR1)
    • RBD image data is replicated to DR2 via Ceph mirroring
    • During failover, DR2 would create NEW PVC/PV pointing to replicated RBD image
```

## Ramen DR Orchestration

Ramen automates this process:

1. **DRPlacementControl** resource declares desired cluster
2. Ramen detects failover intent
3. Ramen:
   - Demotes volumes on source cluster
   - Promotes volumes on target cluster
   - Recreates PVC/PV on target cluster
   - Updates application placement

## Common Misconceptions

### ❌ "PVC should be visible on DR2"
**Wrong.** Only RBD image is replicated. PVC is cluster-specific.

### ❌ "VolumeReplication should exist on both clusters"
**Wrong.** VolumeReplication exists only on the cluster with the primary volume.

### ❌ "I need to manually copy PVC/PV to DR2"
**Wrong.** During failover, new PVC/PV are created that bind to the replicated RBD image.

### ✅ "Only the RBD image data is replicated"
**Correct.** Ceph handles block-level replication. Kubernetes objects are recreated during failover.

## Verification Commands

### Check DR1 (Primary)
```bash
# Kubernetes objects
kubectl --context=dr1 get pvc test-replication-pvc
kubectl --context=dr1 get pv
kubectl --context=dr1 get volumereplication

# Storage layer
kubectl --context=dr1 -n rook-ceph exec -it deploy/rook-ceph-tools -- \
  rbd ls replicapool
kubectl --context=dr1 -n rook-ceph exec -it deploy/rook-ceph-tools -- \
  rbd mirror image status replicapool/<image-name>
```

### Check DR2 (Secondary)
```bash
# Kubernetes objects (should be empty)
kubectl --context=dr2 get pvc test-replication-pvc  # Not found
kubectl --context=dr2 get volumereplication          # Empty

# Storage layer (should have replicated image)
kubectl --context=dr2 -n rook-ceph exec -it deploy/rook-ceph-tools -- \
  rbd ls replicapool  # Should show replicated image
kubectl --context=dr2 -n rook-ceph exec -it deploy/rook-ceph-tools -- \
  rbd mirror image status replicapool/<image-name>  # up+replaying
```

## Summary

| Component | DR1 (Primary) | DR2 (Secondary) | Notes |
|-----------|---------------|-----------------|-------|
| PVC | ✅ Exists | ❌ Does not exist | Created during failover |
| PV | ✅ Exists | ❌ Does not exist | Created during failover |
| VolumeReplication | ✅ Exists (Primary) | ❌ Does not exist | Primary-only resource |
| RBD Image (data) | ✅ Primary (R/W) | ✅ Replica (R/O) | Replicated by Ceph |
| RBD Mirror Status | up+stopped | up+replaying | Healthy replication |

**Key Takeaway:** Replication happens at the **storage layer** (Ceph), not the **Kubernetes layer**. PVC/PV are recreated during failover to bind to the replicated storage.
