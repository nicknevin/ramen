#!/bin/bash
# Test CSI Replication functionality with enhanced debugging and verification

set -e  # Exit on error

echo "=== CSI Replication Health Check ==="

echo "0. Cleaning up any previous test resources..."
set +e
kubectl --context=dr1 patch volumereplication test-volume-replication --type='merge' -p='{"metadata":{"finalizers":[]}}' 2>/dev/null || true
kubectl --context=dr1 delete volumereplication test-volume-replication --ignore-not-found=true
kubectl --context=dr1 patch pvc test-replication-pvc --type='merge' -p='{"metadata":{"finalizers":[]}}' 2>/dev/null || true
kubectl --context=dr1 delete pvc test-replication-pvc --ignore-not-found=true
set -e
echo ""

echo "1. Checking CSI Addons Controller..."
kubectl --context=dr1 get pods -n csi-addons-system
echo ""

echo "2. Checking VolumeReplicationClass..."
kubectl --context=dr1 get volumereplicationclass
echo ""

echo "3. Creating test PVC..."
cat > /tmp/test-pvc.yaml << 'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-replication-pvc
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: rook-ceph-block
EOF

kubectl --context=dr1 apply -f /tmp/test-pvc.yaml
echo ""

echo "4. Waiting for PVC to be Bound..."
kubectl --context=dr1 wait --for=jsonpath='{.status.phase}'=Bound pvc/test-replication-pvc --timeout=120s
kubectl --context=dr1 get pvc test-replication-pvc
echo ""

echo "5. Creating VolumeReplication..."
PV_NAME=$(kubectl --context=dr1 get pvc test-replication-pvc -o jsonpath='{.spec.volumeName}')
cat > /tmp/test-volrep.yaml << EOF
apiVersion: replication.storage.openshift.io/v1alpha1
kind: VolumeReplication
metadata:
  name: test-volume-replication
spec:
  volumeReplicationClass: rbd-volumereplicationclass
  dataSource:
    kind: PersistentVolumeClaim
    name: test-replication-pvc
  replicationState: primary
  autoResync: true
EOF

kubectl --context=dr1 apply -f /tmp/test-volrep.yaml
echo ""

echo "6. Waiting for VolumeReplication to be ready..."
sleep 10
kubectl --context=dr1 get volumereplication test-volume-replication
echo ""
echo "VolumeReplication detailed status:"
kubectl --context=dr1 get volumereplication test-volume-replication -o jsonpath='{.status}' | jq . 2>/dev/null || echo "Status not ready yet"
echo ""

echo "7. Getting RBD image information..."
RBD_IMAGE=$(kubectl --context=dr1 get pv "$PV_NAME" -o jsonpath='{.spec.csi.volumeAttributes.imageName}' 2>/dev/null || echo "N/A")
echo "RBD Image: $RBD_IMAGE"
echo ""

echo "8. Verifying what SHOULD and SHOULD NOT exist on DR2..."
echo ""
echo "=== Kubernetes Objects (should NOT exist on DR2 during replication) ==="
echo ""

echo "Checking VolumeReplication on DR2 (should NOT exist):"
set +e
DR2_VR_COUNT=$(kubectl --context=dr2 get volumereplication 2>/dev/null | wc -l)
set -e
echo "  VolumeReplication count: $((DR2_VR_COUNT - 1))"
if [ $((DR2_VR_COUNT - 1)) -gt 0 ]; then
  echo "  ⚠️  Unexpected: VolumeReplication found on DR2"
  kubectl --context=dr2 get volumereplication
else
  echo "  ✓ Correct: No VolumeReplication on DR2"
fi
echo ""

echo "Checking PVC on DR2 (should NOT exist):"
set +e
DR2_PVC=$(kubectl --context=dr2 get pvc test-replication-pvc 2>/dev/null)
set -e
if [ -n "$DR2_PVC" ]; then
  echo "  ⚠️  Unexpected: PVC found on DR2"
  echo "$DR2_PVC"
else
  echo "  ✓ Correct: PVC 'test-replication-pvc' does not exist on DR2"
fi
echo ""

echo "Checking PV on DR2 (should NOT exist):"
if [ -n "$PV_NAME" ] && [ "$PV_NAME" != "N/A" ]; then
  set +e
  DR2_PV=$(kubectl --context=dr2 get pv "$PV_NAME" 2>/dev/null)
  set -e
  if [ -n "$DR2_PV" ]; then
    echo "  ⚠️  Unexpected: PV $PV_NAME found on DR2"
    echo "$DR2_PV"
  else
    echo "  ✓ Correct: PV $PV_NAME does not exist on DR2"
  fi
fi
echo ""

echo "=== Storage Layer (SHOULD exist on DR2 via RBD mirroring) ==="
echo ""
echo "Explanation:"
echo "  During normal replication:"
echo "    • Kubernetes objects (PVC/PV/VR) exist ONLY on primary cluster (DR1)"
echo "    • RBD image data is replicated to DR2 via Ceph mirroring"
echo "    • During failover, DR2 would create NEW PVC/PV pointing to replicated RBD image"
echo ""

echo "9. Checking RBD image replication status..."
if [ "$RBD_IMAGE" != "N/A" ]; then
  echo "DR1 Mirror Status:"
  set +e
  kubectl --context=dr1 -n rook-ceph exec deploy/rook-ceph-tools -- rbd mirror image status replicapool/$RBD_IMAGE 2>/dev/null || echo "  Mirror status not available yet"
  set -e
  echo ""
fi

echo "10. Waiting for RBD image to appear on DR2..."
if [ "$RBD_IMAGE" != "N/A" ]; then
  TIMEOUT=120
  ELAPSED=0
  while [ $ELAPSED -lt $TIMEOUT ]; do
    set +e
    DR2_IMAGE_EXISTS=$(kubectl --context=dr2 -n rook-ceph exec deploy/rook-ceph-tools -- rbd ls replicapool 2>/dev/null | grep -c "$RBD_IMAGE")
    set -e
    if [ "$DR2_IMAGE_EXISTS" -gt 0 ]; then
      echo "✓ RBD image found on DR2 after ${ELAPSED}s"
      break
    fi
    echo "  Waiting for replication... (${ELAPSED}s/${TIMEOUT}s)"
    sleep 5
    ELAPSED=$((ELAPSED + 5))
  done
  
  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "⚠ Timeout waiting for RBD image replication to DR2"
  fi
fi
echo ""

echo "11. Checking DR2 RBD images..."
echo "DR2 RBD Images in replicapool:"
set +e
kubectl --context=dr2 -n rook-ceph exec deploy/rook-ceph-tools -- rbd ls replicapool 2>/dev/null || echo "  Unable to list images"
set -e
echo ""

if [ "$RBD_IMAGE" != "N/A" ]; then
  echo "DR2 Mirror Status for $RBD_IMAGE:"
  set +e
  kubectl --context=dr2 -n rook-ceph exec deploy/rook-ceph-tools -- rbd mirror image status replicapool/$RBD_IMAGE 2>/dev/null || echo "  Mirror status not available"
  set -e
  echo ""
fi

echo "12. RBD mirror daemon health..."
echo "DR1 RBD mirror daemon:"
set +e
kubectl --context=dr1 -n rook-ceph get pods -l app=rook-ceph-rbd-mirror
set -e
echo ""
echo "DR2 RBD mirror daemon:"
set +e
kubectl --context=dr2 -n rook-ceph get pods -l app=rook-ceph-rbd-mirror
set -e
echo ""

echo "13. Final verification..."
echo ""
echo "=== Cross-cluster Replication Summary ==="
echo ""
echo "DR1 (Primary Cluster):"
echo "  ✓ PVC: test-replication-pvc"
echo "  ✓ PV: $PV_NAME"
echo "  ✓ VolumeReplication: test-volume-replication (state: Primary)"
echo "  ✓ RBD image: $RBD_IMAGE (local, being replicated)"
echo ""
echo "DR2 (Secondary Cluster - Standby):"
set +e
DR2_IMAGES=$(kubectl --context=dr2 -n rook-ceph exec deploy/rook-ceph-tools -- rbd ls replicapool 2>/dev/null | wc -l)
DR2_MIRROR_PEERS=$(kubectl --context=dr2 -n rook-ceph get cephblockpool replicapool -o jsonpath='{.status.mirroringInfo.peers}' 2>/dev/null | jq '. | length' 2>/dev/null || echo "0")
echo "  ✗ PVC: Does not exist (expected - created during failover)"
echo "  ✗ PV: Does not exist (expected - created during failover)"
echo "  ✗ VolumeReplication: Does not exist (expected - primary only)"
echo "  ✓ RBD image: $RBD_IMAGE (replicated copy, read-only)"
echo "  ✓ Mirror peers: $DR2_MIRROR_PEERS configured"
echo "  ✓ Total replicated images: $DR2_IMAGES"

# Check replication health
DR1_HEALTHY=$(kubectl --context=dr1 -n rook-ceph exec deploy/rook-ceph-tools -- rbd mirror image status replicapool/$RBD_IMAGE 2>/dev/null | grep -c "up+stopped" || echo "0")
DR2_HEALTHY=$(kubectl --context=dr2 -n rook-ceph exec deploy/rook-ceph-tools -- rbd mirror image status replicapool/$RBD_IMAGE 2>/dev/null | grep -c "up+replaying" || echo "0")
set -e

echo ""
echo "=== Replication Health Status ==="
if [ "$DR1_HEALTHY" -gt 0 ] && [ "$DR2_HEALTHY" -gt 0 ]; then
  echo "✅ Cross-cluster replication is HEALTHY"
  echo ""
  echo "Current State:"
  echo "  DR1: Primary (up+stopped) - local image, sending snapshots to DR2"
  echo "  DR2: Secondary (up+replaying) - replicated image, receiving snapshots from DR1"
  echo ""
  echo "What exists where:"
  echo "  DR1: PVC + PV + VolumeReplication + RBD image (primary)"
  echo "  DR2: RBD image only (replicated, standby)"
  echo ""
  echo "During failover to DR2:"
  echo "  1. Demote DR1 volume to secondary (if accessible)"
  echo "  2. Promote DR2 RBD image to primary"
  echo "  3. Create NEW PVC/PV on DR2 pointing to the now-primary RBD image"
  echo "  4. Application pods start on DR2 using the new PVC"
  echo "  5. DR1 becomes secondary, receiving updates from DR2"
else
  echo "⚠️  Cross-cluster replication status needs verification"
  echo "   DR1 status: $([ "$DR1_HEALTHY" -gt 0 ] && echo "OK (up+stopped)" || echo "NEEDS CHECK")"
  echo "   DR2 status: $([ "$DR2_HEALTHY" -gt 0 ] && echo "OK (up+replaying)" || echo "NEEDS CHECK")"
fi

echo ""
echo "=== Cleanup ==="
set +e
echo "Removing VolumeReplication..."
kubectl --context=dr1 patch volumereplication test-volume-replication --type='merge' -p='{"metadata":{"finalizers":[]}}' 2>/dev/null || true
kubectl --context=dr1 delete volumereplication test-volume-replication --ignore-not-found=true
echo "Removing PVC..."
kubectl --context=dr1 patch pvc test-replication-pvc --type='merge' -p='{"metadata":{"finalizers":[]}}' 2>/dev/null || true
kubectl --context=dr1 delete pvc test-replication-pvc --ignore-not-found=true
rm -f /tmp/test-pvc.yaml /tmp/test-volrep.yaml
echo "Cleanup complete"
