#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Final cleanup of container configurations after upstream merge issues
# This fixes remaining container arg/command problems that were introduced during patching

set -e

echo "🔧 Cleaning up remaining CSI container configuration issues..."
echo ""

for context in dr1 dr2; do
    echo "📌 Fixing CSI pods on $context cluster..."
    
    # ========== FIX csi-rbdplugin-provisioner ==========
    # csi-resizer (container 1) incorrectly has sleep loop args - remove them
    if kubectl --context=$context get deployment -n rook-ceph csi-rbdplugin-provisioner &>/dev/null; then
        echo "  ✓ Restoring csi-resizer in csi-rbdplugin-provisioner..."
        
        # Remove the incorrect sleep loop args from csi-resizer (container 1)
        kubectl --context=$context patch deployment -n rook-ceph csi-rbdplugin-provisioner \
            --type='json' \
            -p='[{"op": "remove", "path": "/spec/template/spec/containers/1/args"}]' 2>/dev/null || true
    fi
    
    # ========== FIX csi-rbdplugin daemonset ==========
    # driver-registrar (container 0) may have wrong args - restore proper registration socket args
    if kubectl --context=$context get daemonset -n rook-ceph csi-rbdplugin &>/dev/null; then
        echo "  ✓ Restoring driver-registrar in csi-rbdplugin daemonset..."
        
        kubectl --context=$context patch daemonset -n rook-ceph csi-rbdplugin \
            --type='json' \
            -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": ["--v=2","--csi-address=/registration/csi-rbdplugin.sock","--kubelet-registration-path=/var/lib/kubelet/plugins/rbd.csi.ceph.com/csi.sock"]}]' 2>/dev/null || true
    fi
    
    # ========== FIX csi-cephfsplugin daemonset ==========
    # driver-registrar (container 0) may have wrong args - restore proper registration socket args
    if kubectl --context=$context get daemonset -n rook-ceph csi-cephfsplugin &>/dev/null; then
        echo "  ✓ Restoring driver-registrar in csi-cephfsplugin daemonset..."
        
        kubectl --context=$context patch daemonset -n rook-ceph csi-cephfsplugin \
            --type='json' \
            -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": ["--v=2","--csi-address=/registration/csi-cephfsplugin.sock","--kubelet-registration-path=/var/lib/kubelet/plugins/cephfs.csi.ceph.com/csi.sock"]}]' 2>/dev/null || true
    fi
    
    # ========== RESTART ALL CSI PODS ==========
    echo "  ↻ Restarting all CSI pods to apply changes..."
    
    for app in csi-rbdplugin-provisioner csi-cephfsplugin-provisioner csi-rbdplugin csi-cephfsplugin; do
        kubectl --context=$context delete pods -n rook-ceph -l app=$app --ignore-not-found=true 2>/dev/null || true
    done
done

echo ""
echo "✅ CSI cleanup fixes applied"
echo "📊 Waiting for pods to stabilize (30 seconds)..."
sleep 30

echo ""
echo "📋 Final status:"
for context in dr1 dr2; do
    echo ""
    echo "=== $context cluster ==="
    kubectl --context=$context get pods -n rook-ceph -l 'app in (csi-rbdplugin,csi-cephfsplugin,csi-rbdplugin-provisioner,csi-cephfsplugin-provisioner)' --no-headers 2>/dev/null | awk '{print $1, $2, $3}' || echo "No CSI pods found"
done
