#!/bin/bash

# CSI Addons TLS Fix Script
# This script properly adds TLS configuration to CSI Addons sidecars

set -e

CLUSTER=${1:-dr1}

echo "Applying TLS fixes to cluster: $CLUSTER"

# Function to safely add TLS flag to container args if not already present
add_tls_flag() {
    local resource_type=$1
    local resource_name=$2
    local container_index=$3
    local context=$4
    
    echo "Checking $resource_type/$resource_name container $container_index..."
    
    # Get current args
    current_args=$(kubectl --context=$context get $resource_type $resource_name -n rook-ceph -o jsonpath="{.spec.template.spec.containers[$container_index].args}")
    
    # Check if already has --enable-auth=false
    if echo "$current_args" | grep -q "enable-auth=false"; then
        echo "  ✓ Already has TLS fix"
        return 0
    fi
    
    # Check if it's a csi-addons container
    container_name=$(kubectl --context=$context get $resource_type $resource_name -n rook-ceph -o jsonpath="{.spec.template.spec.containers[$container_index].name}")
    if [ "$container_name" != "csi-addons" ]; then
        echo "  ! Container $container_index is not csi-addons (found: $container_name), skipping"
        return 0
    fi
    
    echo "  + Adding TLS fix to $resource_type/$resource_name container $container_index"
    kubectl --context=$context patch $resource_type $resource_name -n rook-ceph --type='json' \
        -p="[{\"op\": \"add\", \"path\": \"/spec/template/spec/containers/$container_index/args/-\", \"value\": \"--enable-auth=false\"}]"
}

# Apply fixes to deployments
add_tls_flag "deployment" "csi-rbdplugin-provisioner" 5 $CLUSTER
add_tls_flag "deployment" "csi-cephfsplugin-provisioner" 5 $CLUSTER

# Apply fixes to daemonsets  
add_tls_flag "daemonset" "csi-rbdplugin" 3 $CLUSTER
add_tls_flag "daemonset" "csi-cephfsplugin" 2 $CLUSTER

echo "✓ TLS fixes applied to $CLUSTER"