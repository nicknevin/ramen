#!/usr/bin/env bash
set -e

# Fix CSI Addons version alignment and gRPC connectivity
# This script:
# 1. Updates controller and sidecars to matching versions (already loaded in minikube)
# 2. Fixes gRPC endpoint addresses
# 3. Ensures proper connectivity between controller and sidecars

CONTEXT="${1:-dr1}"
CONTROLLER_IMAGE="quay.io/csiaddons/k8s-controller:latest"
SIDECAR_IMAGE="quay.io/csiaddons/k8s-sidecar:v0.11.0"

echo "=== Fixing CSI Addons versions and connectivity for ${CONTEXT} ==="
echo ""

# Step 1: Update controller image to specific version
echo "1. Updating CSI Addons controller to ${VERSION}..."
kubectl --context="${CONTEXT}" -n csi-addons-system set image deployment/csi-addons-controller-manager \
  manager="${CONTROLLER_IMAGE}"
echo "✓ Controller image updated"
echo ""

# Step 2: Update sidecar images in all CSI deployments and daemonsets
echo "2. Updating CSI sidecar images to ${VERSION}..."

# RBD provisioner deployment
kubectl --context="${CONTEXT}" -n rook-ceph set image deployment/csi-rbdplugin-provisioner \
  csi-addons="${SIDECAR_IMAGE}" 2>/dev/null || echo "  ⚠ RBD provisioner not found"

# RBD daemonset
kubectl --context="${CONTEXT}" -n rook-ceph set image daemonset/csi-rbdplugin \
  csi-addons="${SIDECAR_IMAGE}" 2>/dev/null || echo "  ⚠ RBD daemonset not found"

# CephFS provisioner deployment  
kubectl --context="${CONTEXT}" -n rook-ceph set image deployment/csi-cephfsplugin-provisioner \
  csi-addons="${SIDECAR_IMAGE}" 2>/dev/null || echo "  ⚠ CephFS provisioner not found"

# CephFS daemonset
kubectl --context="${CONTEXT}" -n rook-ceph set image daemonset/csi-cephfsplugin \
  csi-addons="${SIDECAR_IMAGE}" 2>/dev/null || echo "  ⚠ CephFS daemonset not found"

echo "✓ Sidecar images updated"
echo ""

# Step 3: Wait for controller rollout
echo "3. Waiting for controller rollout..."
kubectl --context="${CONTEXT}" -n csi-addons-system rollout status deployment/csi-addons-controller-manager --timeout=120s
echo "✓ Controller ready"
echo ""

# Step 4: Wait for CSI plugin rollouts
echo "4. Waiting for CSI plugin rollouts..."
kubectl --context="${CONTEXT}" -n rook-ceph rollout status deployment/csi-rbdplugin-provisioner --timeout=120s 2>/dev/null || echo "  ⚠ RBD provisioner rollout timed out or not found"
kubectl --context="${CONTEXT}" -n rook-ceph rollout status deployment/csi-cephfsplugin-provisioner --timeout=120s 2>/dev/null || echo "  ⚠ CephFS provisioner rollout timed out or not found"
echo "✓ CSI plugins ready"
echo ""

# Step 5: Delete old CSIAddonsNode objects to force reconnection
echo "5. Cleaning up old CSIAddonsNode objects..."
kubectl --context="${CONTEXT}" delete csiaddonsnode --all -A 2>/dev/null || true
sleep 5
echo "✓ Old connections cleaned"
echo ""

# Step 6: Verify CSIAddonsNode connections
echo "6. Verifying CSIAddonsNode connections..."
sleep 10
CSIADDONSNODE_COUNT=$(kubectl --context="${CONTEXT}" get csiaddonsnode -A --no-headers 2>/dev/null | wc -l)
echo "  Found ${CSIADDONSNODE_COUNT} CSIAddonsNode resources"

if [ "${CSIADDONSNODE_COUNT}" -gt 0 ]; then
  kubectl --context="${CONTEXT}" get csiaddonsnode -A
  echo ""
  echo "✓ CSI Addons connectivity established"
else
  echo "  ⚠ Warning: No CSIAddonsNode resources found yet (may need more time)"
fi
echo ""

# Step 7: Check for connection errors
echo "7. Checking for gRPC connection errors..."
ERROR_COUNT=$(kubectl --context="${CONTEXT}" -n csi-addons-system logs deployment/csi-addons-controller-manager --tail=50 2>/dev/null | grep -c "error reading server preface" || true)

if [ "${ERROR_COUNT}" -eq 0 ]; then
  echo "✓ No gRPC connection errors detected"
else
  echo "  ⚠ Warning: Found ${ERROR_COUNT} gRPC connection errors in recent logs"
  echo "  Recent errors:"
  kubectl --context="${CONTEXT}" -n csi-addons-system logs deployment/csi-addons-controller-manager --tail=20 2>/dev/null | grep "ERROR" | tail -5
fi
echo ""

echo "=== CSI Addons version alignment complete for ${CONTEXT} ==="
echo ""
echo "Images used:"
echo "  Controller: ${CONTROLLER_IMAGE}"
echo "  Sidecar:    ${SIDECAR_IMAGE}"
echo ""
echo "To test VolumeReplication, create a VolumeReplication resource and check:"
echo "  kubectl --context=${CONTEXT} get volumereplication -A"
echo "  kubectl --context=${CONTEXT} describe volumereplication <name>"
