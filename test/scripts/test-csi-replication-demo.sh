#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Test script to demonstrate CSI replication between dr1 and dr2 clusters
# This script creates a PVC on dr1, enables replication, and verifies replication to dr2

set -e

# Get script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utility functions
source "$SCRIPT_DIR/utils.sh"

echo -e "${PURPLE}🔄 CSI Replication Test Demo${NC}"
echo "=============================="

# Configuration
NAMESPACE="csi-replication-test"
PVC_NAME="test-replication-pvc"
VOLUME_REP_NAME="test-volume-replication"
STORAGE_SIZE="1Gi"
STORAGE_CLASS="rook-ceph-block"
VRC_NAME="rbd-volumereplicationclass"

# Check prerequisites
log_info "Checking prerequisites..."
command -v kubectl >/dev/null 2>&1 || { log_error "kubectl is required"; exit 1; }

# Verify contexts exist
kubectl config get-contexts dr1 >/dev/null 2>&1 || { log_error "dr1 context not found"; exit 1; }
kubectl config get-contexts dr2 >/dev/null 2>&1 || { log_error "dr2 context not found"; exit 1; }

log_success "Prerequisites checked"

# Function to cleanup resources
cleanup() {
    log_info "Cleaning up test resources..."
    log_info "Executing: kubectl --context=dr1 delete volumereplication $VOLUME_REP_NAME -n $NAMESPACE --ignore-not-found=true"
    kubectl --context=dr1 delete volumereplication "$VOLUME_REP_NAME" -n "$NAMESPACE" --ignore-not-found=true
    log_info "Executing: kubectl --context=dr1 delete pvc $PVC_NAME -n $NAMESPACE --ignore-not-found=true"
    kubectl --context=dr1 delete pvc "$PVC_NAME" -n "$NAMESPACE" --ignore-not-found=true
    log_info "Executing: kubectl --context=dr1 delete namespace $NAMESPACE --ignore-not-found=true"
    kubectl --context=dr1 delete namespace "$NAMESPACE" --ignore-not-found=true
    log_info "Executing: kubectl --context=dr2 delete namespace $NAMESPACE --ignore-not-found=true"
    kubectl --context=dr2 delete namespace "$NAMESPACE" --ignore-not-found=true
    log_success "Cleanup completed"
}

# Trap to cleanup on exit
trap cleanup EXIT

# Step 1: Create test namespace
log_step "Step 1: Creating test namespace..."
safe_create_namespace "dr1" "$NAMESPACE"
safe_create_namespace "dr2" "$NAMESPACE"
log_success "Test namespace ready on both clusters"

# Step 2: Create PVC on dr1
log_step "Step 2: Creating PVC on dr1..."

# Check if PVC already exists
if check_pvc_exists "dr1" "$NAMESPACE" "$PVC_NAME"; then
    log_warning "PVC '$PVC_NAME' already exists in namespace '$NAMESPACE'"
    log_info "Getting existing PV name..."
    PV_NAME=$(kubectl --context=dr1 get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "")
    if [[ -n "$PV_NAME" ]]; then
        log_success "Using existing PVC bound to PV: $PV_NAME"
        # Skip to next step since PVC already exists and is bound
    else
        log_warning "Existing PVC is not bound yet"
    fi
else
    log_info "Generating PVC manifest for '$PVC_NAME'..."
    cat > /tmp/test-pvc.yaml << EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
  namespace: $NAMESPACE
  labels:
    app: csi-replication-test
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: $STORAGE_SIZE
  storageClassName: $STORAGE_CLASS
EOF

    log_info "Applying PVC manifest to dr1 cluster..."
    kubectl --context=dr1 apply -f /tmp/test-pvc.yaml
    log_success "PVC created on dr1"
fi

# Step 3: Wait for PVC to be bound
log_step "Step 3: Waiting for PVC to be bound..."
log_info "Checking current PVC status..."
kubectl --context=dr1 get pvc "$PVC_NAME" -n "$NAMESPACE" || log_warning "PVC not found yet"

# Check if PVC is already bound
PVC_STATUS=$(kubectl --context=dr1 get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
if [[ "$PVC_STATUS" == "Bound" ]]; then
    log_success "PVC is already bound"
    PV_NAME=$(kubectl --context=dr1 get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')
    log_success "PVC bound to PV: $PV_NAME"
else
    log_info "PVC status: $PVC_STATUS - waiting for binding..."
    log_info "Executing: kubectl --context=dr1 wait --for=condition=Bound pvc/$PVC_NAME -n $NAMESPACE --timeout=180s"
    kubectl --context=dr1 wait --for=condition=Bound pvc/"$PVC_NAME" -n "$NAMESPACE" --timeout=180s
    log_info "Getting PV name from bound PVC..."
    PV_NAME=$(kubectl --context=dr1 get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')
    log_success "PVC bound to PV: $PV_NAME"
fi

# Step 4: Create VolumeReplication resource
log_step "Step 4: Creating VolumeReplication resource..."

# Check if VolumeReplication already exists
if check_volumereplication_exists "dr1" "$NAMESPACE" "$VOLUME_REP_NAME"; then
    log_warning "VolumeReplication '$VOLUME_REP_NAME' already exists in namespace '$NAMESPACE'"
    VR_STATUS=$(kubectl --context=dr1 get volumereplication "$VOLUME_REP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "Unknown")
    log_info "Current VolumeReplication status: $VR_STATUS"
else
    log_info "Generating VolumeReplication manifest for '$VOLUME_REP_NAME'..."
    cat > /tmp/volume-replication.yaml << EOF
apiVersion: replication.storage.openshift.io/v1alpha1
kind: VolumeReplication
metadata:
  name: $VOLUME_REP_NAME
  namespace: $NAMESPACE
  labels:
    app: csi-replication-test
spec:
  volumeReplicationClass: $VRC_NAME
  dataSource:
    kind: PersistentVolumeClaim
    name: $PVC_NAME
  replicationState: primary
EOF

    log_info "Applying VolumeReplication manifest to dr1 cluster..."
    kubectl --context=dr1 apply -f /tmp/volume-replication.yaml
    log_success "VolumeReplication resource created"
fi

# Step 5: Check VolumeReplication status
log_step "Step 5: Monitoring VolumeReplication status..."
log_info "Waiting for replication to be established (this may take 2-3 minutes)..."

# Wait and check status
sleep 30
for i in {1..6}; do
    log_info "Status check $i/6..."
    
    # Get VolumeReplication status
    log_info "Executing: kubectl --context=dr1 get volumereplication $VOLUME_REP_NAME -n $NAMESPACE -o jsonpath='{.status.state}'"
    STATUS=$(kubectl --context=dr1 get volumereplication "$VOLUME_REP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "Unknown")
    CONDITIONS=$(kubectl --context=dr1 get volumereplication "$VOLUME_REP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions}' 2>/dev/null || echo "[]")
    
    log_info "Replication State: $STATUS"
    
    if [[ "$STATUS" == "Primary" ]]; then
        log_success "VolumeReplication established as Primary"
        break
    elif [[ "$i" -eq 6 ]]; then
        log_warning "VolumeReplication status still pending after 3 minutes"
    else
        log_info "Waiting 30 seconds before next check..."
        sleep 30
    fi
done

# Step 6: Display detailed status
log_step "Step 6: Displaying detailed replication status..."
echo ""
echo "=== VolumeReplication Details ==="
log_info "Executing: kubectl --context=dr1 get volumereplication $VOLUME_REP_NAME -n $NAMESPACE -o yaml"
kubectl --context=dr1 get volumereplication "$VOLUME_REP_NAME" -n "$NAMESPACE" -o yaml | grep -A 20 "status:"

echo ""
echo "=== PVC Details on dr1 ==="
log_info "Executing: kubectl --context=dr1 describe pvc $PVC_NAME -n $NAMESPACE"
kubectl --context=dr1 describe pvc "$PVC_NAME" -n "$NAMESPACE"

echo ""
echo "=== PV Details ==="
log_info "Executing: kubectl --context=dr1 describe pv $PV_NAME"
kubectl --context=dr1 describe pv "$PV_NAME"

# Step 7: Check for replication on dr2
log_step "Step 7: Checking replication on dr2 cluster..."

# Look for RBD images on both clusters
log_info "Checking RBD images on both clusters..."

echo ""
echo "=== RBD images on dr1 ==="
log_info "Executing: kubectl --context=dr1 -n rook-ceph exec deployment/rook-ceph-tools -- rbd ls replicapool"
kubectl --context=dr1 -n rook-ceph exec deployment/rook-ceph-tools -- rbd ls replicapool 2>/dev/null || log_warning "Could not list RBD images on dr1"

echo ""
echo "=== RBD images on dr2 ==="
log_info "Executing: kubectl --context=dr2 -n rook-ceph exec deployment/rook-ceph-tools -- rbd ls replicapool"
kubectl --context=dr2 -n rook-ceph exec deployment/rook-ceph-tools -- rbd ls replicapool 2>/dev/null || log_warning "Could not list RBD images on dr2"

# Step 8: Test data write and replication
log_step "Step 8: Testing data write and replication..."

# Check if test pod already exists
if check_pod_exists "dr1" "$NAMESPACE" "test-writer-pod"; then
    log_warning "Test pod 'test-writer-pod' already exists"
    log_info "Checking existing pod status..."
    kubectl --context=dr1 get pod test-writer-pod -n "$NAMESPACE"
    log_info "Getting existing pod logs..."
    kubectl --context=dr1 logs test-writer-pod -n "$NAMESPACE" || log_warning "Could not get existing pod logs"
else
    # Create a test pod that uses the PVC
    log_info "Generating test pod manifest..."
    cat > /tmp/test-pod.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-writer-pod
  namespace: $NAMESPACE
  labels:
    app: csi-replication-test
spec:
  containers:
  - name: writer
    image: registry.k8s.io/busybox:1.35
    command: ["/bin/sh"]
    args: ["-c", "echo 'CSI Replication Test Data - $(date)' > /data/test-file.txt && cat /data/test-file.txt && sleep 3600"]
    volumeMounts:
    - name: test-storage
      mountPath: /data
  volumes:
  - name: test-storage
    persistentVolumeClaim:
      claimName: $PVC_NAME
  restartPolicy: Never
EOF

    log_info "Applying test pod manifest to dr1 cluster..."
    kubectl --context=dr1 apply -f /tmp/test-pod.yaml
    log_info "Test pod created, writing data to replicated volume..."

    # Wait for pod to start and write data
    sleep 10
    log_info "Executing: kubectl --context=dr1 wait --for=condition=ready pod/test-writer-pod -n $NAMESPACE --timeout=60s"
    kubectl --context=dr1 wait --for=condition=ready pod/test-writer-pod -n "$NAMESPACE" --timeout=60s || log_warning "Test pod may not be ready"

    # Show pod logs
    log_info "Test pod output:"
    log_info "Executing: kubectl --context=dr1 logs test-writer-pod -n $NAMESPACE"
    kubectl --context=dr1 logs test-writer-pod -n "$NAMESPACE" || log_warning "Could not get pod logs"
fi

# Step 9: Summary
log_step "Step 9: Test Summary..."
echo ""
echo "=== CSI Replication Test Results ==="
echo "✅ PVC created and bound: $PVC_NAME"
echo "✅ VolumeReplication created: $VOLUME_REP_NAME"
echo "✅ Replication state: $(kubectl --context=dr1 get volumereplication "$VOLUME_REP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo 'Unknown')"
echo "✅ Test data written to replicated volume"
echo ""

# Final status check
log_info "Final VolumeReplication status:"
log_info "Executing: kubectl --context=dr1 get volumereplication $VOLUME_REP_NAME -n $NAMESPACE -o wide"
kubectl --context=dr1 get volumereplication "$VOLUME_REP_NAME" -n "$NAMESPACE" -o wide 2>/dev/null || log_warning "Could not get VolumeReplication status"

echo ""
log_success "🎉 CSI Replication test completed!"
echo ""
log_info "Next steps:"
echo "  1. Monitor replication status: kubectl --context=dr1 get volumereplication -n $NAMESPACE"
echo "  2. Check RBD mirroring: kubectl --context=dr1 -n rook-ceph exec deployment/rook-ceph-tools -- rbd mirror pool status replicapool"
echo "  3. Test failover scenarios by promoting secondary replica"
echo ""

# Clean up temp files
rm -f /tmp/test-pvc.yaml /tmp/volume-replication.yaml /tmp/test-pod.yaml

log_info "Test resources will be cleaned up on script exit"
echo "Press Ctrl+C to cleanup and exit, or wait for manual cleanup..."
sleep 5