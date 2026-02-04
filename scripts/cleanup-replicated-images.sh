#!/bin/bash

# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Script to clean up old replicated RBD images from both CSI replication clusters
# This script removes all CSI volumes (csi-vol-*) from the replicapool on both dr1 and dr2 clusters

set -e

POOL_NAME="replicapool"

cleanup_cluster_images() {
    local cluster=$1
    echo "Cleaning replicated images on $cluster..."
    
    # Check if cluster is accessible
    if ! kubectl --context=$cluster get pods -n rook-ceph 2>/dev/null | grep -q rook-ceph-tools; then
        echo "  Warning: Cannot access rook-ceph-tools on $cluster, skipping cleanup"
        return 0
    fi

    # Get list of CSI volume images
    local images=$(kubectl exec -n rook-ceph --context=$cluster deploy/rook-ceph-tools -- \
        rbd ls $POOL_NAME 2>/dev/null | grep "^csi-vol-" || true)
    
    if [[ -z "$images" ]]; then
        echo "  No CSI volume images found on $cluster"
        return 0
    fi

    echo "  Found $(echo "$images" | wc -l) CSI volume images to clean up on $cluster"

    # First disable mirroring for all images
    for img in $images; do
        echo "    Disabling mirroring for $img on $cluster"
        if [[ "$cluster" == "dr1" ]]; then
            # On dr1, images are typically secondary, need --force
            kubectl exec -n rook-ceph --context=$cluster deploy/rook-ceph-tools -- \
                rbd mirror image disable --force $POOL_NAME/$img 2>/dev/null || true
        else
            # On dr2, try normal disable first, then force if needed
            kubectl exec -n rook-ceph --context=$cluster deploy/rook-ceph-tools -- \
                rbd mirror image disable $POOL_NAME/$img 2>/dev/null || \
                rbd mirror image disable --force $POOL_NAME/$img 2>/dev/null || true
        fi
    done

    # Then delete all images
    for img in $images; do
        echo "    Deleting $img from $cluster"
        kubectl exec -n rook-ceph --context=$cluster deploy/rook-ceph-tools -- \
            rbd rm $POOL_NAME/$img 2>/dev/null || true
    done

    echo "  Cleanup completed on $cluster"
}

main() {
    echo "Starting cleanup of old replicated images from both clusters..."
    
    # Clean up dr1 first (secondary replicas)
    cleanup_cluster_images "dr1"
    
    # Clean up dr2 (primary images)  
    cleanup_cluster_images "dr2"
    
    echo "Image cleanup completed on both clusters."
}

# Execute main function
main "$@"