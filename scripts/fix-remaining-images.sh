#!/bin/bash
# Fix remaining image issues after drenv cache loading

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Fixing Remaining Image Issues ===${NC}"

# List of remaining images that need manual loading
# (these are not handled by drenv cache due to custom repositories)
MISSING_IMAGES=(
    "quay.io/csiaddons/k8s-sidecar:v0.11.0"
    "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.13.0"
    "registry.k8s.io/sig-storage/csi-provisioner:v5.2.0"
    "registry.k8s.io/sig-storage/csi-attacher:v4.8.1"
    "registry.k8s.io/sig-storage/csi-resizer:v1.13.2"
    "registry.k8s.io/sig-storage/csi-snapshotter:v8.2.1"
)

# Function to load images to both clusters
load_images() {
    local images=("$@")
    echo -e "${YELLOW}Loading ${#images[@]} missing images...${NC}"
    
    # Pull all images in parallel (batches of 3)
    for ((i=0; i<${#images[@]}; i+=3)); do
        batch=(${images[@]:i:3})
        echo -e "${YELLOW}Pulling batch: ${batch[@]}${NC}"
        
        for image in "${batch[@]}"; do
            docker pull "$image" &
        done
        wait
    done
    
    # Load to both clusters in parallel
    for image in "${images[@]}"; do
        echo -e "${YELLOW}Loading $image to both clusters...${NC}"
        (
            minikube image load "$image" --profile=dr1 && 
            echo -e "${GREEN}✓ Loaded $image to dr1${NC}"
        ) &
        (
            minikube image load "$image" --profile=dr2 && 
            echo -e "${GREEN}✓ Loaded $image to dr2${NC}"
        ) &
    done
    wait
}

# Function to patch deployments with custom images to use standard ones
patch_custom_images() {
    echo -e "${YELLOW}Patching deployments with custom nladha images...${NC}"
    
    # Replace custom CSI addons controller image
    kubectl --context=dr1 patch deployment -n csi-addons-system csi-addons-controller-manager \
        --type='json' \
        -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "quay.io/csiaddons/k8s-controller:latest"}]' || true
    
    kubectl --context=dr2 patch deployment -n csi-addons-system csi-addons-controller-manager \
        --type='json' \
        -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "quay.io/csiaddons/k8s-controller:latest"}]' || true
    
    # Replace custom CSI addons sidecar images in Rook DaemonSets/Deployments
    for context in dr1 dr2; do
        echo -e "${YELLOW}Patching CSI RBD provisioner in $context...${NC}"
        kubectl --context=$context patch deployment -n rook-ceph csi-rbdplugin-provisioner \
            --type='json' \
            -p='[{"op": "replace", "path": "/spec/template/spec/containers/6/image", "value": "quay.io/csiaddons/k8s-sidecar:v0.11.0"}]' || true
        
        echo -e "${YELLOW}Patching CSI CephFS provisioner in $context...${NC}"
        kubectl --context=$context patch deployment -n rook-ceph csi-cephfsplugin-provisioner \
            --type='json' \
            -p='[{"op": "replace", "path": "/spec/template/spec/containers/6/image", "value": "quay.io/csiaddons/k8s-sidecar:v0.11.0"}]' || true
        
        echo -e "${YELLOW}Patching CSI RBD DaemonSet in $context...${NC}"
        kubectl --context=$context patch daemonset -n rook-ceph csi-rbdplugin \
            --type='json' \
            -p='[{"op": "replace", "path": "/spec/template/spec/containers/3/image", "value": "quay.io/csiaddons/k8s-sidecar:v0.11.0"}]' || true
    done
}

# Function to restart problematic deployments
restart_deployments() {
    echo -e "${YELLOW}Restarting problematic deployments...${NC}"
    
    for context in dr1 dr2; do
        echo -e "${YELLOW}Restarting deployments in $context...${NC}"
        kubectl --context=$context rollout restart deployment -n rook-ceph csi-rbdplugin-provisioner || true
        kubectl --context=$context rollout restart deployment -n rook-ceph csi-cephfsplugin-provisioner || true
        kubectl --context=$context rollout restart daemonset -n rook-ceph csi-rbdplugin || true
        kubectl --context=$context rollout restart deployment -n csi-addons-system csi-addons-controller-manager || true
    done
}

# Function to wait for pods to be ready
wait_for_pods() {
    echo -e "${YELLOW}Waiting for pods to become ready...${NC}"
    
    for context in dr1 dr2; do
        echo -e "${YELLOW}Waiting for pods in $context...${NC}"
        kubectl --context=$context wait --for=condition=ready pod -l app=rook-ceph-operator -n rook-ceph --timeout=300s || true
        kubectl --context=$context wait --for=condition=ready pod -l app=csi-rbdplugin-provisioner -n rook-ceph --timeout=300s || true
        kubectl --context=$context wait --for=condition=ready pod -l app=csi-cephfsplugin-provisioner -n rook-ceph --timeout=300s || true
        kubectl --context=$context wait --for=condition=ready pod -l control-plane=controller-manager -n csi-addons-system --timeout=300s || true
    done
}

# Main execution
main() {
    echo -e "${GREEN}Starting image fix process...${NC}"
    
    # Step 1: Load missing images
    load_images "${MISSING_IMAGES[@]}"
    
    # Step 2: Patch custom images
    patch_custom_images
    
    # Step 3: Restart deployments
    restart_deployments
    
    # Step 4: Wait for everything to be ready
    wait_for_pods
    
    echo -e "${GREEN}=== Checking Final Status ===${NC}"
    for context in dr1 dr2; do
        echo -e "${YELLOW}Failed pods in $context:${NC}"
        kubectl --context=$context get pods -A | grep -E "(ImagePullBackOff|ErrImagePull|Pending)" || echo -e "${GREEN}✓ No failed pods in $context${NC}"
    done
    
    echo -e "${GREEN}Image fix process completed!${NC}"
}

# Run main function
main "$@"