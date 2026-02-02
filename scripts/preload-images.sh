#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Pre-load container images into minikube clusters to avoid network pull issues
# Based on setup-dr-clusters-with-ceph.sh image management approach

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Define required images for Rook/Ceph and CSI
declare -a ROOK_IMAGES=(
    "rook/ceph:v1.18.9"
    "quay.io/ceph/ceph:v18.2.2"
    "quay.io/nladha/csiaddons-sidecar:cg"
)

declare -a CSI_IMAGES=(
    "registry.k8s.io/sig-storage/csi-attacher:v4.8.1"
    "registry.k8s.io/sig-storage/csi-provisioner:v3.5.0"
    "registry.k8s.io/sig-storage/csi-resizer:v1.13.2"
    "registry.k8s.io/sig-storage/csi-snapshotter:v8.2.1"
    "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.8.0"
    "registry.k8s.io/sig-storage/livenessprobe:v2.8.0"
    "registry.k8s.io/sig-storage/csi-external-health-monitor-controller:v0.7.0"
    "registry.k8s.io/sig-storage/snapshot-controller:v8.2.1"
)

declare -a CSI_ADDONS_IMAGES=(
    "quay.io/csiaddons/k8s-controller:v0.9.1"
    "quay.io/csiaddons/k8s-sidecar:v0.9.1"
    "gcr.io/kubebuilder/kube-rbac-proxy:v0.8.0"
    "quay.io/cephcsi/cephcsi:v3.11.0"
    "quay.io/cephcsi/cephcsi:v3.15.0"
)

# Minikube addon images
declare -a MINIKUBE_ADDON_IMAGES=(
    "docker.io/registry:3.0.0"
    "gcr.io/k8s-minikube/kube-registry-proxy:0.0.9"
)

# Custom/problematic images that may need substitution
declare -a CUSTOM_IMAGES=(
    "quay.io/nladha/csiaddons-controller:cg"
    "quay.io/nladha/csiaddons-sidecar:cg"
)

# Standard substitutes for custom images
declare -a SUBSTITUTE_IMAGES=(
    "quay.io/csiaddons/k8s-controller:v0.9.1"
    "quay.io/csiaddons/k8s-sidecar:v0.9.1"
)

# Function to check if Docker image exists locally
image_exists_locally() {
    local image=$1
    docker image inspect "$image" >/dev/null 2>&1
}

# Function to create image tags for custom/problematic images
handle_custom_images() {
    local profile=$1
    log_info "Creating substitute tags for custom images in $profile..."
    
    # Tag standard images as substitutes for custom ones
    for i in "${!CUSTOM_IMAGES[@]}"; do
        local custom_image="${CUSTOM_IMAGES[$i]}"
        local substitute_image="${SUBSTITUTE_IMAGES[$i]}"
        
        if minikube ssh --profile="$profile" -- "docker tag $substitute_image $custom_image" >/dev/null 2>&1; then
            log_success "✓ Tagged $substitute_image as $custom_image in $profile"
        else
            log_warning "✗ Failed to tag substitute for $custom_image in $profile"
        fi
    done
}

# Function to pre-pull images in parallel
pre_pull_images() {
    log_info "Pre-pulling required images in parallel to avoid network issues during cluster setup..."
    
    # Combine all required images
    ALL_IMAGES=("${ROOK_IMAGES[@]}" "${CSI_IMAGES[@]}" "${CSI_ADDONS_IMAGES[@]}" "${MINIKUBE_ADDON_IMAGES[@]}" "${SUBSTITUTE_IMAGES[@]}")
    
    local need_pulling=()
    local total_count=${#ALL_IMAGES[@]}
    
    # Check which images need pulling
    for image in "${ALL_IMAGES[@]}"; do
        if image_exists_locally "$image"; then
            log_info "✓ Image already available locally: $image"
        else
            need_pulling+=("$image")
        fi
    done
    
    if [ ${#need_pulling[@]} -eq 0 ]; then
        log_success "All $total_count required images are already available locally"
        return 0
    fi
    
    log_info "Need to pull ${#need_pulling[@]} images..."
    
    # Pull images in parallel batches of 3 (to avoid overwhelming the network)
    local batch_size=3
    local pulled_count=0
    local failed_pulls=()
    
    for ((i=0; i<${#need_pulling[@]}; i+=batch_size)); do
        local pids=()
        local batch_images=()
        
        # Start batch pulls
        for ((j=i; j<i+batch_size && j<${#need_pulling[@]}; j++)); do
            local image="${need_pulling[$j]}"
            batch_images+=("$image")
            
            log_info "Pulling: $image"
            (
                if docker pull "$image" >/dev/null 2>&1; then
                    echo "PULL_SUCCESS:$image"
                else
                    echo "PULL_FAILED:$image"
                fi
            ) &
            pids+=($!)
        done
        
        # Wait for batch to complete
        for pid in "${pids[@]}"; do
            wait $pid
        done
        
        # Check results
        for image in "${batch_images[@]}"; do
            if image_exists_locally "$image"; then
                log_success "✓ Successfully pulled: $image"
                ((pulled_count++))
            else
                log_error "✗ Failed to pull: $image"
                failed_pulls+=("$image")
            fi
        done
        
        log_info "Batch completed: ${#batch_images[@]} images processed"
    done
    
    if [ ${#failed_pulls[@]} -gt 0 ]; then
        log_warning "Failed to pull ${#failed_pulls[@]} images:"
        for image in "${failed_pulls[@]}"; do
            log_warning "  - $image"
        done
        log_info "Continuing with available images..."
    fi
    
    log_success "Successfully pulled $pulled_count new images, total available: $((total_count - ${#failed_pulls[@]}))"
}

# Function to load images into a minikube cluster in parallel
load_images_to_cluster() {
    local profile=$1
    log_info "Loading images into $profile cluster..."
    
    # Combine all required images including substitutes
    ALL_IMAGES=("${ROOK_IMAGES[@]}" "${CSI_IMAGES[@]}" "${CSI_ADDONS_IMAGES[@]}" "${SUBSTITUTE_IMAGES[@]}")
    
    local loaded_count=0
    local failed_images=()
    
    # Load images in parallel batches of 5
    local batch_size=5
    local total_images=${#ALL_IMAGES[@]}
    
    for ((i=0; i<$total_images; i+=batch_size)); do
        local pids=()
        local batch_images=()
        
        # Start batch
        for ((j=i; j<i+batch_size && j<total_images; j++)); do
            local image="${ALL_IMAGES[$j]}"
            batch_images+=("$image")
            
            # Load image in background
            (
                if minikube image load "$image" --profile="$profile" >/dev/null 2>&1; then
                    echo "SUCCESS:$image"
                else
                    echo "FAILED:$image"
                fi
            ) &
            pids+=($!)
        done
        
        # Wait for batch to complete and collect results
        for pid in "${pids[@]}"; do
            wait $pid
        done
        
        # Process results
        for image in "${batch_images[@]}"; do
            if image_exists_locally "$image"; then
                log_success "✓ Available for $profile: $image"
                ((loaded_count++))
            else
                log_warning "✗ Missing for $profile: $image"
                failed_images+=("$image")
            fi
        done
        
        log_info "Batch completed for $profile: ${#batch_images[@]} images processed"
    done
    
    if [ ${#failed_images[@]} -gt 0 ]; then
        log_warning "Failed to load ${#failed_images[@]} images into $profile:"
        for image in "${failed_images[@]}"; do
            log_warning "  - $image"
        done
    fi
    
    log_success "Processed $loaded_count/${total_images} images for $profile cluster"
}

# Function to verify images are loaded in clusters
verify_images_in_cluster() {
    local profile=$1
    log_info "Verifying images in $profile cluster..."
    
    local available_count=$(minikube image ls --profile="$profile" 2>/dev/null | wc -l)
    log_info "Found $available_count total images in $profile cluster"
    
    # Check for specific required images
    local rook_images_found=0
    local csi_images_found=0
    
    for image in "${ROOK_IMAGES[@]}"; do
        if minikube image ls --profile="$profile" 2>/dev/null | grep -q "$image"; then
            ((rook_images_found++))
        fi
    done
    
    for image in "${CSI_IMAGES[@]}"; do
        if minikube image ls --profile="$profile" 2>/dev/null | grep -q "$image"; then
            ((csi_images_found++))
        fi
    done
    
    log_info "$profile cluster has $rook_images_found/${#ROOK_IMAGES[@]} Rook images and $csi_images_found/${#CSI_IMAGES[@]} CSI images"
}

# Main execution
main() {
    local clusters=("$@")
    
    if [ ${#clusters[@]} -eq 0 ]; then
        log_info "Usage: $0 <cluster1> [cluster2] [cluster3]..."
        log_info "Example: $0 dr1 dr2"
        exit 1
    fi
    
    echo -e "${PURPLE}🐳 Container Image Pre-loading for Minikube Clusters${NC}"
    echo "=================================================="
    echo ""
    
    # Check prerequisites
    command -v docker >/dev/null 2>&1 || { log_error "docker is required"; exit 1; }
    command -v minikube >/dev/null 2>&1 || { log_error "minikube is required"; exit 1; }
    
    # Pre-pull all images locally first
    log_info "Step 1: Pre-pulling images locally..."
    pre_pull_images
    echo ""
    
    # Load images into each specified cluster
    log_info "Step 2: Loading images into minikube clusters..."
    for cluster in "${clusters[@]}"; do
        log_info "Processing cluster: $cluster"
        
        # Check if cluster exists
        if ! minikube profile list --output=json 2>/dev/null | grep -q "\"Name\":\"$cluster\""; then
            log_warning "Cluster $cluster does not exist, skipping..."
            continue
        fi
        
        # Load images
        load_images_to_cluster "$cluster"
        
        # Handle custom image substitutions
        handle_custom_images "$cluster"
        echo ""
    done
    
    # Verify images are loaded
    log_info "Step 3: Verifying image availability..."
    for cluster in "${clusters[@]}"; do
        if minikube profile list --output=json 2>/dev/null | grep -q "\"Name\":\"$cluster\""; then
            verify_images_in_cluster "$cluster"
        fi
    done
    
    log_success "🎉 Image pre-loading completed successfully!"
    echo ""
    echo -e "${CYAN}Next steps:${NC}"
    echo "1. Your minikube clusters now have all required images locally"
    echo "2. Rook/Ceph operators should deploy without network pull issues"
    echo "3. Continue with your drenv environment setup"
    echo ""
}

# Execute main function with all arguments
main "$@"