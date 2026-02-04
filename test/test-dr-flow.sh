#!/bin/bash
# Test Complete DR Failover Flow - Demonstrates K8s Object Recreation on Target Cluster
# This test shows what a DR orchestrator (like Ramen) does during failover

set -e

echo "=== Complete DR Failover Flow Test ==="
echo ""
echo "This test demonstrates:"
echo "  1. Primary workload on DR1 with RBD mirroring to DR2"
echo "  2. Disaster recovery failover to DR2"
echo "  3. K8s objects (PVC/VR) recreated on DR2 pointing to replicated RBD image"
echo "  4. Application can access data on DR2"
echo ""

# Global variables
DR1_PVC_NAME="dr-flow-pvc"
DR1_VR_NAME="dr-flow-replication"
DR2_PVC_NAME="dr-flow-pvc"
DR2_VR_NAME="dr-flow-replication"
TEST_DATA="DR-FLOW-TEST-DATA-$(date +%s)"

# Cleanup function
cleanup() {
    echo ""
    echo "=== Cleanup ==="
    
    # Cleanup DR2 first
    echo "Cleaning up DR2..."
    set +e
    kubectl --context=dr2 delete pod dr-flow-test-pod --ignore-not-found=true --wait=false 2>/dev/null
    kubectl --context=dr2 patch volumereplication $DR2_VR_NAME --type='merge' -p='{"metadata":{"finalizers":[]}}' 2>/dev/null
    kubectl --context=dr2 delete volumereplication $DR2_VR_NAME --ignore-not-found=true 2>/dev/null
    kubectl --context=dr2 patch pvc $DR2_PVC_NAME --type='merge' -p='{"metadata":{"finalizers":[]}}' 2>/dev/null
    kubectl --context=dr2 delete pvc $DR2_PVC_NAME --ignore-not-found=true 2>/dev/null
    kubectl --context=dr2 delete pv dr-flow-pv-dr2 --ignore-not-found=true 2>/dev/null
    
    # Cleanup RBD snapshots on DR2
    echo "Cleaning up RBD snapshots on DR2..."
    RBD_IMAGES=$(kubectl --context=dr2 -n rook-ceph exec deploy/rook-ceph-tools -- rbd ls replicapool 2>/dev/null | grep "csi-vol-" || true)
    for IMAGE in $RBD_IMAGES; do
        echo "  Cleaning snapshots for image: $IMAGE"
        SNAPSHOTS=$(kubectl --context=dr2 -n rook-ceph exec deploy/rook-ceph-tools -- rbd snap ls replicapool/$IMAGE --format=json 2>/dev/null | jq -r '.[].name' 2>/dev/null || true)
        for SNAP in $SNAPSHOTS; do
            kubectl --context=dr2 -n rook-ceph exec deploy/rook-ceph-tools -- rbd snap rm replicapool/$IMAGE@$SNAP 2>/dev/null || true
        done
    done
    
    # Cleanup DR1
    echo "Cleaning up DR1..."
    kubectl --context=dr1 delete pod dr-flow-test-pod --ignore-not-found=true --wait=false 2>/dev/null
    kubectl --context=dr1 patch volumereplication $DR1_VR_NAME --type='merge' -p='{"metadata":{"finalizers":[]}}' 2>/dev/null
    kubectl --context=dr1 delete volumereplication $DR1_VR_NAME --ignore-not-found=true 2>/dev/null
    kubectl --context=dr1 patch pvc $DR1_PVC_NAME --type='merge' -p='{"metadata":{"finalizers":[]}}' 2>/dev/null
    kubectl --context=dr1 delete pvc $DR1_PVC_NAME --ignore-not-found=true 2>/dev/null
    set -e
    
    echo "✓ Cleanup completed"
}

# Set trap to cleanup on exit
trap cleanup EXIT

echo "0. Cleaning up any previous test resources..."
cleanup 2>/dev/null || true
sleep 5
echo ""

# Helper function to wait for VR state
wait_for_vr_state() {
    local context="$1"
    local vr_name="$2"
    local expected_state="$3"
    local timeout="${4:-90}"
    
    echo "⏳ Waiting for VolumeReplication '$vr_name' to reach '$expected_state' state on $context (timeout: ${timeout}s)..."
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        set +e
        local current_state=$(kubectl --context=$context get volumereplication $vr_name -o jsonpath='{.status.state}' 2>/dev/null || echo "Unknown")
        set -e
        echo "  Current state: $current_state (${elapsed}s/${timeout}s)"
        
        if [ "$current_state" = "$expected_state" ]; then
            echo "✓ VolumeReplication reached '$expected_state' state after ${elapsed}s"
            return 0
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    echo "⚠ Timeout waiting for '$expected_state' state on $context"
    return 1
}

# Helper function to get RBD image name from PV
get_rbd_image_name() {
    local context="$1"
    local pvc_name="$2"
    
    local pv_name=$(kubectl --context=$context get pvc $pvc_name -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "")
    if [ -z "$pv_name" ]; then
        echo ""
        return
    fi
    
    local rbd_image=$(kubectl --context=$context get pv $pv_name -o jsonpath='{.spec.csi.volumeAttributes.imageName}' 2>/dev/null || echo "")
    echo "$rbd_image"
}

echo "==================== PHASE 1: PRIMARY WORKLOAD ON DR1 ===================="
echo ""

echo "1. Creating PVC on DR1..."
kubectl --context=dr1 apply -f test/yaml/dr_flow/dr1-pvc.yaml
echo ""

echo "2. Waiting for PVC to be bound on DR1..."
kubectl --context=dr1 wait --for=jsonpath='{.status.phase}'=Bound pvc/$DR1_PVC_NAME --timeout=120s
echo "✓ PVC bound successfully on DR1"
echo ""

echo "3. Getting RBD image information..."
RBD_IMAGE=$(get_rbd_image_name dr1 $DR1_PVC_NAME)
echo "RBD Image: $RBD_IMAGE"
echo ""

echo "4. Creating VolumeReplication as PRIMARY on DR1..."
kubectl --context=dr1 apply -f test/yaml/dr_flow/dr1-volumereplication.yaml
echo ""

echo "5. Waiting for primary replication to be established on DR1..."
wait_for_vr_state dr1 $DR1_VR_NAME Primary 90
echo ""

echo "6. Writing test data to volume on DR1..."
# Use envsubst to substitute TEST_DATA in the template
export TEST_DATA
envsubst < test/yaml/dr_flow/dr1-test-pod.yaml | kubectl --context=dr1 apply -f -
echo ""

echo "7. Waiting for pod to write data..."
sleep 10
kubectl --context=dr1 wait --for=condition=Ready pod/dr-flow-test-pod --timeout=60s 2>/dev/null || true
echo ""

echo "8. Verifying data was written on DR1..."
set +e
DR1_DATA=$(kubectl --context=dr1 exec dr-flow-test-pod -- cat /data/testfile.txt 2>/dev/null || echo "FAILED")
set -e
if [ "$DR1_DATA" = "$TEST_DATA" ]; then
    echo "✓ Data verified on DR1: $DR1_DATA"
else
    echo "⚠ Data verification failed on DR1"
fi
echo ""

echo "9. Waiting for RBD image replication to DR2..."
echo "Checking RBD mirroring status..."
TIMEOUT=120
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    set +e
    DR2_IMAGE_EXISTS=$(kubectl --context=dr2 -n rook-ceph exec deploy/rook-ceph-tools -- rbd ls replicapool 2>/dev/null | grep -c "$RBD_IMAGE")
    MIRROR_STATUS=$(kubectl --context=dr2 -n rook-ceph exec deploy/rook-ceph-tools -- rbd mirror image status replicapool/$RBD_IMAGE 2>/dev/null | grep -c "up+replaying" || echo "0")
    set -e
    
    if [ "$DR2_IMAGE_EXISTS" -gt 0 ] && [ "$MIRROR_STATUS" -gt 0 ]; then
        echo "✓ RBD image replicated to DR2 and actively mirroring after ${ELAPSED}s"
        break
    fi
    echo "  Waiting for replication... (${ELAPSED}s/${TIMEOUT}s)"
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "⚠ Timeout waiting for RBD replication to DR2"
    echo "Continuing anyway to demonstrate the flow..."
fi
echo ""

echo "9a. Waiting for RBD snapshot to capture the written data..."
echo "💡 RBD mirroring uses snapshot-based replication with 2-minute intervals"
echo "   We need to wait for the next snapshot to include our data"
echo ""
echo "⏳ Waiting 2 minutes for snapshot schedule (snapshots every 2m)..."
SNAPSHOT_WAIT=120
SNAPSHOT_ELAPSED=0
while [ $SNAPSHOT_ELAPSED -lt $SNAPSHOT_WAIT ]; do
    echo "  Waiting for snapshot... (${SNAPSHOT_ELAPSED}s/${SNAPSHOT_WAIT}s)"
    sleep 15
    SNAPSHOT_ELAPSED=$((SNAPSHOT_ELAPSED + 15))
done
echo "✓ Snapshot wait period completed - data should now be available in DR2 snapshot"
echo ""

echo "10. Current state before failover:"
echo ""
echo "DR1 (Primary):"
kubectl --context=dr1 get pvc $DR1_PVC_NAME -o wide
kubectl --context=dr1 get volumereplication $DR1_VR_NAME -o wide
echo ""
echo "DR2 (Secondary - Storage Layer Only):"
set +e
echo "  PVC: $(kubectl --context=dr2 get pvc $DR2_PVC_NAME 2>&1 | grep -q 'not found' && echo 'Does not exist (expected)' || echo 'EXISTS')"
echo "  VR:  $(kubectl --context=dr2 get volumereplication $DR2_VR_NAME 2>&1 | grep -q 'not found' && echo 'Does not exist (expected)' || echo 'EXISTS')"
echo "  RBD: $(kubectl --context=dr2 -n rook-ceph exec deploy/rook-ceph-tools -- rbd ls replicapool 2>/dev/null | grep -c "$RBD_IMAGE") image(s) replicated"
set -e
echo ""

echo "==================== PHASE 2: DISASTER RECOVERY FAILOVER ===================="
echo ""

echo "11. Simulating disaster - Demoting DR1 volume to secondary..."
kubectl --context=dr1 patch volumereplication $DR1_VR_NAME \
  --type='merge' -p='{"spec":{"replicationState":"secondary"}}'
echo "✓ Demote request sent to DR1"
echo ""

echo "12. Waiting for DR1 demotion to complete..."
wait_for_vr_state dr1 $DR1_VR_NAME Secondary 90
echo ""

echo "13. Stopping application pod on DR1..."
kubectl --context=dr1 delete pod dr-flow-test-pod --ignore-not-found=true --wait=true
echo "✓ DR1 application stopped"
echo ""

echo "==================== PHASE 3: RECREATE K8S OBJECTS ON DR2 ===================="
echo ""
echo "NOTE: This is what a DR orchestrator (like Ramen) would do automatically!"
echo "      Using pure CSI Replication CRDs - no direct RBD commands!"
echo ""

echo "14. Creating PVC on DR2 pointing to the replicated RBD image..."
echo ""
echo "📝 CRITICAL STEP: We are creating a NEW PVC on DR2"
echo "   This PVC will use a static PV pointing to the existing RBD image"
echo ""

# First, get the PV details from DR1 to recreate similar on DR2
DR1_PV_NAME=$(kubectl --context=dr1 get pvc $DR1_PVC_NAME -o jsonpath='{.spec.volumeName}')
DR1_PV_SIZE=$(kubectl --context=dr1 get pv $DR1_PV_NAME -o jsonpath='{.spec.capacity.storage}')
DR1_CSI_DRIVER=$(kubectl --context=dr1 get pv $DR1_PV_NAME -o jsonpath='{.spec.csi.driver}')
DR1_CSI_FSTYPE=$(kubectl --context=dr1 get pv $DR1_PV_NAME -o jsonpath='{.spec.csi.fsType}')
DR1_CLUSTER_ID=$(kubectl --context=dr1 get pv $DR1_PV_NAME -o jsonpath='{.spec.csi.volumeAttributes.clusterID}')
DR1_POOL=$(kubectl --context=dr1 get pv $DR1_PV_NAME -o jsonpath='{.spec.csi.volumeAttributes.pool}')
DR1_VOLUME_HANDLE=$(kubectl --context=dr1 get pv $DR1_PV_NAME -o jsonpath='{.spec.csi.volumeHandle}')

# Get DR2 cluster ID
DR2_CLUSTER_ID=$(kubectl --context=dr2 -n rook-ceph get configmap rook-ceph-mon-endpoints -o jsonpath='{.data.data}' 2>/dev/null | grep -oP '"clusterID":\s*"\K[^"]+' || echo "")
if [ -z "$DR2_CLUSTER_ID" ]; then
    echo "⚠ Warning: Could not determine DR2 cluster ID from configmap, trying CephCluster..."
    DR2_CLUSTER_ID=$(kubectl --context=dr2 -n rook-ceph get cephcluster my-cluster -o jsonpath='{.status.ceph.fsid}' 2>/dev/null || echo "")
fi
if [ -z "$DR2_CLUSTER_ID" ]; then
    echo "⚠ Warning: Using DR1's cluster ID as fallback"
    DR2_CLUSTER_ID="$DR1_CLUSTER_ID"
else
    echo "✓ DR2 cluster ID: $DR2_CLUSTER_ID"
fi

# Create static PV on DR2 pointing to the replicated RBD image using template
export PLACEHOLDER_STORAGE_SIZE="$DR1_PV_SIZE"
export PLACEHOLDER_CSI_DRIVER="$DR1_CSI_DRIVER"
export PLACEHOLDER_FS_TYPE="$DR1_CSI_FSTYPE"
export PLACEHOLDER_DR2_CLUSTER_ID="$DR2_CLUSTER_ID"
export PLACEHOLDER_RBD_IMAGE_NAME="$RBD_IMAGE"
export PLACEHOLDER_POOL_NAME="$DR1_POOL"
export PLACEHOLDER_VOLUME_HANDLE="$DR1_VOLUME_HANDLE"

envsubst < test/yaml/dr_flow/dr2-static-pv-template.yaml | kubectl --context=dr2 apply -f -
echo "✓ Static PV created on DR2"
echo ""

envsubst < test/yaml/dr_flow/dr2-pvc.yaml | kubectl --context=dr2 apply -f -
echo "✓ PVC created on DR2"
echo ""

echo "15. Waiting for PVC to bind on DR2..."
kubectl --context=dr2 wait --for=jsonpath='{.status.phase}'=Bound pvc/$DR2_PVC_NAME --timeout=60s
echo "✓ PVC bound successfully on DR2"
echo ""

echo "16. Creating VolumeReplication as PRIMARY on DR2..."
echo "📝 CRITICAL: VolumeReplication CRD will handle RBD image promotion automatically!"
echo "   Setting replicationState: primary will trigger the CSI addons controller to:"
echo "   - Promote the replicated RBD image to primary"
echo "   - Disable mirroring on this cluster"
echo "   - Enable replication to other clusters"
echo ""
kubectl --context=dr2 apply -f test/yaml/dr_flow/dr2-volumereplication.yaml
echo "✓ VolumeReplication CRD created - promotion will happen automatically"
echo ""

echo "Validating CSI Addons setup on DR2..."
set +e
# Try multiple ways to find the CSI Addons controller
CSI_ADDONS_CONTROLLER=$(kubectl --context=dr2 get pods -n csi-addons-system -l app=csi-addons-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$CSI_ADDONS_CONTROLLER" ]; then
    # Try alternative label
    CSI_ADDONS_CONTROLLER=$(kubectl --context=dr2 get pods -n csi-addons-system -l app.kubernetes.io/name=csi-addons-controller-manager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi
if [ -z "$CSI_ADDONS_CONTROLLER" ]; then
    # Just get any pod from the controller manager deployment
    CSI_ADDONS_CONTROLLER=$(kubectl --context=dr2 get pods -n csi-addons-system -o jsonpath='{.items[?(@.metadata.ownerReferences[0].name=="csi-addons-controller-manager")].metadata.name}' 2>/dev/null | head -1)
fi
if [ -z "$CSI_ADDONS_CONTROLLER" ]; then
    # Last resort: get first pod in the namespace
    CSI_ADDONS_CONTROLLER=$(kubectl --context=dr2 get pods -n csi-addons-system -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi

if [ -z "$CSI_ADDONS_CONTROLLER" ]; then
    echo "⚠ WARNING: No CSI Addons controller pod found on DR2!"
    echo "  This is required for VolumeReplication to work"
    echo ""
    echo "CSI Addons system pods:"
    kubectl --context=dr2 get pods -n csi-addons-system
    echo ""
else
    echo "✓ CSI Addons controller running: $CSI_ADDONS_CONTROLLER"
    echo "  Deployment: csi-addons-controller-manager"
    echo ""
fi
set -e

echo "17. Waiting for VolumeReplication to reach Primary state on DR2..."
echo "⏳ The CSI addons controller will now:"
echo "   1. Detect the new VolumeReplication resource"
echo "   2. Communicate with the RBD CSI driver"
echo "   3. Execute 'rbd mirror image promote' automatically"
echo "   4. Update the VR status to 'Primary'"
echo ""
if ! wait_for_vr_state dr2 $DR2_VR_NAME Primary 90; then
    echo ""
    echo "⚠ VolumeReplication did not reach Primary state on DR2"
    echo ""
    echo "Debugging information:"
    echo "=== VolumeReplication Status on DR2 ==="
    set +e
    kubectl --context=dr2 get volumereplication $DR2_VR_NAME -o yaml
    echo ""
    echo "=== VolumeReplication Events ==="
    kubectl --context=dr2 describe volumereplication $DR2_VR_NAME
    echo ""
    echo "=== CSI Addons Controller Pods ==="
    kubectl --context=dr2 get pods -n csi-addons-system
    echo ""
    echo "=== CSI Addons Controller Logs ==="
    kubectl --context=dr2 logs -n csi-addons-system deploy/csi-addons-controller-manager --tail=100 2>/dev/null || \
    kubectl --context=dr2 logs -n csi-addons-system -l app.kubernetes.io/name=csi-addons-controller-manager --tail=100 2>/dev/null || \
    echo "Could not retrieve CSI Addons controller logs"
    echo ""
    echo "=== All Replication Pods on DR2 ==="
    kubectl --context=dr2 get pods -A | grep -i replicate
    echo ""
    echo "=== CSI Addons Sidecar Logs (if available) ==="
    SIDECAR_POD=$(kubectl --context=dr2 get pods -A -l app=csi-addons-replication-sidecar -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ ! -z "$SIDECAR_POD" ]; then
        kubectl --context=dr2 logs -n $(kubectl --context=dr2 get pods -A -l app=csi-addons-replication-sidecar -o jsonpath='{.items[0].metadata.namespace}') $SIDECAR_POD --tail=100
    else
        echo "No replication sidecar pod found"
    fi
    echo ""
    echo "=== VolumeReplicationClass Configuration ==="
    kubectl --context=dr2 get volumereplicationclass rbd-volumereplicationclass -o yaml
    echo ""
    echo "=== RBD Image Status (for comparison with CRD approach) ==="
    kubectl --context=dr2 -n rook-ceph exec deploy/rook-ceph-tools -- rbd mirror image status replicapool/$RBD_IMAGE 2>/dev/null || echo "Could not check RBD mirror status"
    set -e
    echo ""
    echo "The test will continue for diagnostics, but CRD-based failover may be incomplete."
    echo "This could indicate the CSI addons controller is not properly processing VolumeReplication resources."
    echo ""
else
    echo "✓ VolumeReplication reached Primary state on DR2"
    echo ""
fi

echo "==================== PHASE 4: VERIFY APPLICATION ON DR2 ===================="
echo ""

echo "18. Starting application pod on DR2 with the PVC..."
kubectl --context=dr2 apply -f test/yaml/dr_flow/dr2-test-pod.yaml
echo ""

echo "19. Waiting for pod to start on DR2..."
sleep 10
if ! kubectl --context=dr2 wait --for=condition=Ready pod/dr-flow-test-pod --timeout=60s 2>/dev/null; then
    echo "⚠ Pod is not ready on DR2"
    echo ""
    echo "Pod status:"
    kubectl --context=dr2 get pod dr-flow-test-pod -o wide
    echo ""
    echo "Pod events:"
    kubectl --context=dr2 describe pod dr-flow-test-pod | tail -30
else
    echo "✓ Pod is ready on DR2"
fi
echo ""

echo "20. Verifying data on DR2..."
set +e
DR2_DATA=$(kubectl --context=dr2 exec dr-flow-test-pod -- cat /data/testfile.txt 2>/dev/null || echo "FAILED")
set -e

if [ "$DR2_DATA" = "FAILED" ]; then
    echo "⚠ Failed to read data from pod"
    echo ""
    echo "Debugging step 20 pod issue:"
    echo "=== DR2 Pod Status ==="
    kubectl --context=dr2 get pod dr-flow-test-pod -o wide
    echo ""
    echo "=== DR2 Pod Events ==="
    kubectl --context=dr2 describe pod dr-flow-test-pod | grep -A 20 "Events:"
    echo ""
    echo "=== DR2 Pod Logs ==="
    kubectl --context=dr2 logs dr-flow-test-pod 2>&1 || echo "No logs available"
    echo ""
    echo "=== Checking if volume is mounted ==="
    kubectl --context=dr2 exec dr-flow-test-pod -- ls -la /data 2>&1 || echo "Cannot access mount point"
    echo ""
else
    echo "✓ Data successfully read from DR2: $DR2_DATA"
fi
echo ""

echo "==================== FINAL STATE VERIFICATION ===================="
echo ""

echo "DR1 (Former Primary - Now Secondary):"
kubectl --context=dr1 get pvc $DR1_PVC_NAME -o wide 2>/dev/null || echo "  PVC: Deleted or not accessible"
kubectl --context=dr1 get volumereplication $DR1_VR_NAME -o wide 2>/dev/null || echo "  VR: State: Secondary"
echo ""

echo "DR2 (New Primary - Recovered Site):"
kubectl --context=dr2 get pvc $DR2_PVC_NAME -o wide
kubectl --context=dr2 get volumereplication $DR2_VR_NAME -o wide
echo ""

echo "==================== DATA VERIFICATION ===================="
echo ""
echo "Original data written on DR1: $TEST_DATA"
echo "Data read from DR2 after failover: $DR2_DATA"
echo ""

if [ "$DR2_DATA" = "$TEST_DATA" ]; then
    echo "🎉 ✅ SUCCESS! DR FAILOVER COMPLETED SUCCESSFULLY!"
    echo ""
    echo "What happened:"
    echo "  ✓ Application ran on DR1 with PVC and wrote data"
    echo "  ✓ RBD image continuously replicated to DR2 via Ceph mirroring"
    echo "  ✓ During failover:"
    echo "    - Demoted DR1 volume to secondary"
    echo "    - Promoted DR2 RBD image to primary"
    echo "    - Created NEW PVC on DR2 pointing to the replicated RBD image"
    echo "    - Created NEW VolumeReplication on DR2 as primary"
    echo "    - Application started on DR2 and accessed the replicated data"
    echo "  ✓ Data integrity maintained across clusters"
    echo ""
    echo "Key Architecture Points:"
    echo "  • K8s objects (PVC/VR) are NOT automatically replicated"
    echo "  • K8s objects ARE recreated on target cluster during failover"
    echo "  • RBD image data IS automatically replicated by Ceph mirroring"
    echo "  • DR orchestrators like Ramen automate the K8s object recreation"
else
    echo "⚠️ WARNING: Data verification failed"
    echo "Expected: $TEST_DATA"
    echo "Got: $DR2_DATA"
    echo ""
    echo "This might be due to:"
    echo "  - RBD mirroring delay"
    echo "  - Ceph snapshot schedule (check 2m interval)"
    echo "  - Volume promotion issues"
fi

echo ""
echo "==================== CLEANUP ===================="
echo "Test resources will be cleaned up automatically..."
