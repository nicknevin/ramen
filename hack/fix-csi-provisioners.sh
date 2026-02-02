#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Fix CSI provisioner deployments after upstream merge
# Upstream Rook manifests incorrectly configured csi-rbdplugin-provisioner with CephCSI driver
# This script patches it to use the correct external-provisioner image

set -e

echo "🔧 Applying CSI provisioner fixes for Rook/Ceph compatibility (post-merge)..."
echo ""

for context in dr1 dr2; do
    echo "📌 Fixing CSI provisioners on $context cluster..."
    
    # ========== FIX csi-rbdplugin-provisioner ==========
    # Upstream deploys container 0 (csi-provisioner) with wrong image
    # Container structure: csi-provisioner(0), csi-resizer(1), csi-attacher(2), csi-snapshotter(3), 
    #                     csi-omap-generator(4), csi-addons(5), csi-rbdplugin(6), log-collector(7)
    
    if kubectl --context=$context get deployment -n rook-ceph csi-rbdplugin-provisioner &>/dev/null; then
        echo "  ✓ Patching csi-rbdplugin-provisioner..."
        
        # Fix container 0 (csi-provisioner) to use correct external-provisioner image instead of CephCSI driver
        kubectl --context=$context patch deployment -n rook-ceph csi-rbdplugin-provisioner \
            --type='json' \
            -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "registry.k8s.io/sig-storage/csi-provisioner:v5.2.0"}]' 2>/dev/null || true
        
        # Ensure log-collector (container 7) has correct initialization
        kubectl --context=$context patch deployment -n rook-ceph csi-rbdplugin-provisioner \
            --type='json' \
            -p='[{"op": "replace", "path": "/spec/template/spec/containers/7/command", "value": ["/bin/sh"]}]' 2>/dev/null || true
        kubectl --context=$context patch deployment -n rook-ceph csi-rbdplugin-provisioner \
            --type='json' \
            -p='[{"op": "replace", "path": "/spec/template/spec/containers/7/args", "value": ["-c", "while true; do sleep 3600; done"]}]' 2>/dev/null || true
    fi
    
    # ========== csi-cephfsplugin-provisioner ==========
    # Upstream has WRONG IMAGES too: csi-attacher uses CephCSI driver instead of external-attacher
    # Container structure: csi-attacher(0), csi-snapshotter(1), csi-resizer(2), csi-provisioner(3),
    #                     csi-cephfsplugin(4), csi-addons(5), log-collector(6)
    
    if kubectl --context=$context get deployment -n rook-ceph csi-cephfsplugin-provisioner &>/dev/null; then
        echo "  ✓ Patching csi-cephfsplugin-provisioner (multiple image fixes)..."
        
        # Fix container 0 (csi-attacher) - currently wrong CephCSI image
        kubectl --context=$context patch deployment -n rook-ceph csi-cephfsplugin-provisioner \
            --type='json' \
            -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "registry.k8s.io/sig-storage/csi-attacher:v4.8.1"}]' 2>/dev/null || true
        
        # Fix container 1 (csi-snapshotter) - remove broken "sh" command
        kubectl --context=$context patch deployment -n rook-ceph csi-cephfsplugin-provisioner \
            --type='json' \
            -p='[{"op": "remove", "path": "/spec/template/spec/containers/1/command"}]' 2>/dev/null || true
        
        # Ensure log-collector (container 6) has correct initialization
        kubectl --context=$context patch deployment -n rook-ceph csi-cephfsplugin-provisioner \
            --type='json' \
            -p='[{"op": "replace", "path": "/spec/template/spec/containers/6/command", "value": ["/bin/sh"]}]' 2>/dev/null || true
        kubectl --context=$context patch deployment -n rook-ceph csi-cephfsplugin-provisioner \
            --type='json' \
            -p='[{"op": "replace", "path": "/spec/template/spec/containers/6/args", "value": ["-c", "while true; do sleep 3600; done"]}]' 2>/dev/null || true
    fi
    
    # ========== RESTART PROVISIONER PODS ==========
    echo "  ↻ Restarting provisioner pods to apply changes..."
    
    # Delete rbdplugin provisioner pods to force restart with new specs
    if kubectl --context=$context get deployment -n rook-ceph csi-rbdplugin-provisioner &>/dev/null; then
        kubectl --context=$context delete pods -n rook-ceph -l app=csi-rbdplugin-provisioner --ignore-not-found=true
    fi
    
    # Delete cephfsplugin provisioner pods to force restart with new specs
    if kubectl --context=$context get deployment -n rook-ceph csi-cephfsplugin-provisioner &>/dev/null; then
        kubectl --context=$context delete pods -n rook-ceph -l app=csi-cephfsplugin-provisioner --ignore-not-found=true
    fi
done

echo ""
echo "✅ CSI provisioner fixes applied"
echo "📊 Waiting for provisioner pods to stabilize (30 seconds)..."
sleep 30

echo ""
echo "📋 Final status:"
for context in dr1 dr2; do
    echo ""
    echo "=== $context cluster ==="
    kubectl --context=$context get pods -n rook-ceph -l 'app in (csi-rbdplugin-provisioner,csi-cephfsplugin-provisioner)' --no-headers 2>/dev/null || echo "No provisioner pods found"
done
