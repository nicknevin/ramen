#!/bin/bash
# Test CSI Replication functionality

echo "=== CSI Replication Health Check ==="

echo "0. Cleaning up any previous test resources..."
kubectl --context=dr1 patch volumereplication test-volume-replication --type='merge' -p='{"metadata":{"finalizers":[]}}' 2>/dev/null || true
kubectl --context=dr1 delete volumereplication test-volume-replication --ignore-not-found=true
kubectl --context=dr1 patch pvc test-replication-pvc --type='merge' -p='{"metadata":{"finalizers":[]}}' 2>/dev/null || true
kubectl --context=dr1 delete pvc test-replication-pvc --ignore-not-found=true
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
kubectl --context=dr1 get pvc test-replication-pvc
kubectl --context=dr1 wait --for=jsonpath='{.status.phase}'=Bound pvc/test-replication-pvc --timeout=120s
echo ""

echo "5. Creating VolumeReplication..."
PV_NAME=$(kubectl --context=dr1 get pvc test-replication-pvc -o jsonpath='{.spec.volumeName}')
cat > /tmp/test-volrep.yaml << EOF
apiVersion: replication.storage.openshift.io/v1alpha1
kind: VolumeReplication
metadata:
  name: test-volume-replication
spec:
  volumeReplicationClass: vrc-1m
  dataSource:
    kind: PersistentVolumeClaim
    name: test-replication-pvc
  replicationState: primary
  autoResync: true
EOF

kubectl --context=dr1 apply -f /tmp/test-volrep.yaml
echo ""

echo "6. Checking VolumeReplication status..."
sleep 10
kubectl --context=dr1 get volumereplication test-volume-replication
echo ""
echo "VolumeReplication detailed status:"
kubectl --context=dr1 get volumereplication test-volume-replication -o yaml | grep -A 10 status: || echo "Status not ready yet"
echo ""
echo "7. Checking RBD image replication status..."
RBD_IMAGE=$(kubectl --context=dr1 get pv $(kubectl --context=dr1 get pvc test-replication-pvc -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.csi.volumeAttributes.imageName}' 2>/dev/null || echo "N/A")
echo "RBD Image: $RBD_IMAGE"
if [ "$RBD_IMAGE" != "N/A" ]; then
  echo ""
  echo "DR1 Mirror Status:"
  kubectl --context=dr1 -n rook-ceph exec -it deploy/rook-ceph-tools -- rbd mirror image status replicapool/$RBD_IMAGE 2>/dev/null || echo "Mirror status not available yet"
fi

echo ""
echo "8. Waiting for cross-cluster replication to sync..."
echo ""

# Wait for RBD image to appear on DR2
echo "Waiting for RBD image to be replicated to DR2..."
TIMEOUT=120  # 2 minutes timeout
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  DR2_IMAGE_EXISTS=$(kubectl --context=dr2 -n rook-ceph exec -it deploy/rook-ceph-tools -- rbd ls replicapool 2>/dev/null | grep -c "$RBD_IMAGE" || echo "0")
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

echo ""
echo "9. Verifying cross-cluster replication status..."

# Wait for mirror status to be healthy
echo "Waiting for mirror replication to stabilize..."
TIMEOUT=90  # 1.5 minutes timeout
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  DR1_STATUS=$(kubectl --context=dr1 -n rook-ceph exec -it deploy/rook-ceph-tools -- rbd mirror image status replicapool/$RBD_IMAGE 2>/dev/null | grep "state:" | head -1 || echo "")
  DR2_STATUS=$(kubectl --context=dr2 -n rook-ceph exec -it deploy/rook-ceph-tools -- rbd mirror image status replicapool/$RBD_IMAGE 2>/dev/null | grep "state:" | head -1 || echo "")
  
  # Check if both sides are in stable states
  if echo "$DR1_STATUS" | grep -q "up+stopped" && echo "$DR2_STATUS" | grep -q "up+replaying"; then
    echo "✓ Mirror replication stabilized after ${ELAPSED}s"
    break
  fi
  
  echo "  DR1: $(echo $DR1_STATUS | sed 's/.*state:[[:space:]]*//' | head -1)"
  echo "  DR2: $(echo $DR2_STATUS | sed 's/.*state:[[:space:]]*//' | head -1)"
  echo "  Waiting for stable replication... (${ELAPSED}s/${TIMEOUT}s)"
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

echo ""
echo "Checking DR2 cluster for replicated resources..."

# Check if RBD image exists on DR2
echo "DR2 RBD Images:"
kubectl --context=dr2 -n rook-ceph exec -it deploy/rook-ceph-tools -- rbd ls replicapool 2>/dev/null | grep -E "(csi-vol|$RBD_IMAGE)" || echo "No replicated RBD images found"

echo ""
if [ "$RBD_IMAGE" != "N/A" ]; then
  echo "DR2 Mirror Status for $RBD_IMAGE:"
  kubectl --context=dr2 -n rook-ceph exec -it deploy/rook-ceph-tools -- rbd mirror image status replicapool/$RBD_IMAGE 2>/dev/null || echo "Mirror status not available on DR2"
fi

echo ""
echo "10. Final cross-cluster replication verification..."
echo "DR2 Storage Resources Status:"
echo "Storage Classes:"
kubectl --context=dr2 get storageclass | grep rook || echo "No rook storage classes found"
echo ""
echo "Volume Replication Classes:"
kubectl --context=dr2 get volumereplicationclass 2>/dev/null | tail -n +2 || echo "No VRCs found on DR2"

echo ""
echo "DR2 Ceph Mirror Pool Status:"
kubectl --context=dr2 -n rook-ceph exec -it deploy/rook-ceph-tools -- rbd mirror pool status replicapool 2>/dev/null || echo "Mirror pool status not available"

echo ""
echo "Cross-cluster replication summary:"
echo "✓ Primary volume on DR1: $(kubectl --context=dr1 get pvc test-replication-pvc -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo 'N/A')"
echo "✓ RBD image being replicated: $RBD_IMAGE"
DR2_IMAGES=$(kubectl --context=dr2 -n rook-ceph exec -it deploy/rook-ceph-tools -- rbd ls replicapool 2>/dev/null | wc -l)
echo "✓ DR2 RBD images count: $DR2_IMAGES"
DR2_MIRROR_STATUS=$(kubectl --context=dr2 -n rook-ceph exec -it deploy/rook-ceph-tools -- rbd mirror pool status replicapool 2>/dev/null | grep -c "peer sites" || echo "0")
echo "✓ DR2 mirror peers configured: $DR2_MIRROR_STATUS"

# Check replication health
DR1_HEALTHY=$(kubectl --context=dr1 -n rook-ceph exec -it deploy/rook-ceph-tools -- rbd mirror image status replicapool/$RBD_IMAGE 2>/dev/null | grep -c "up+stopped" || echo "0")
DR2_HEALTHY=$(kubectl --context=dr2 -n rook-ceph exec -it deploy/rook-ceph-tools -- rbd mirror image status replicapool/$RBD_IMAGE 2>/dev/null | grep -c "up+replaying" || echo "0")

if [ "$DR1_HEALTHY" -gt 0 ] && [ "$DR2_HEALTHY" -gt 0 ]; then
  echo "✅ Cross-cluster replication is HEALTHY"
  echo "   - DR1: Primary (up+stopped) - sending replication data"
  echo "   - DR2: Secondary (up+replaying) - receiving replication data"
else
  echo "⚠️  Cross-cluster replication status needs verification"
  echo "   - Run 'kubectl --context=dr1 -n rook-ceph exec -it deploy/rook-ceph-tools -- rbd mirror image status replicapool/$RBD_IMAGE' to check status"
fi

echo ""
echo "=== Cleanup ==="
echo "Removing VolumeReplication (with finalizer cleanup)..."
kubectl --context=dr1 patch volumereplication test-volume-replication --type='merge' -p='{"metadata":{"finalizers":[]}}' 2>/dev/null || echo "VolumeReplication already gone"
kubectl --context=dr1 delete volumereplication test-volume-replication --ignore-not-found=true
echo "Removing PVC (with finalizer cleanup)..."
kubectl --context=dr1 patch pvc test-replication-pvc --type='merge' -p='{"metadata":{"finalizers":[]}}' 2>/dev/null || echo "PVC already gone"
kubectl --context=dr1 delete pvc test-replication-pvc --ignore-not-found=true
rm -f /tmp/test-pvc.yaml /tmp/test-volrep.yaml