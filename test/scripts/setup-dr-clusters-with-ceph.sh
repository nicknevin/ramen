#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Single script to setup DR clusters with Ceph storage and replication
# Creates: hub (RamenDR management) + dr1 + dr2 (both with Ceph RBD + replication)

set -e

# Check if running with appropriate permissions
check_permissions() {
    # Test sudo access for virsh operations
    if ! sudo -n true 2>/dev/null; then
        log_info "This script requires sudo access for virsh operations."
        log_info "Please enter your password if prompted."
        sudo -v || { log_error "sudo access required for network operations"; exit 1; }
    fi
    
    # Test docker access
    if ! docker ps >/dev/null 2>&1; then
        if groups | grep -q docker; then
            log_info "Docker group membership detected, but docker daemon may not be accessible."
            log_info "You may need to log out and back in, or run: newgrp docker"
        else
            log_warning "Consider adding your user to the docker group: sudo usermod -aG docker $USER"
        fi
    fi
}

# Get script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utility functions
source "$SCRIPT_DIR/utils.sh"

echo -e "${PURPLE}🚀 DR Clusters with Ceph Storage & Replication Setup${NC}"
echo "===================================================="
echo ""
START_TIME=$(date +%s)

# Check permissions early
check_permissions

# Get script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_info "This script will create:"
echo "  • hub  - RamenDR management cluster"
echo "  • dr1  - Primary DR cluster with Ceph RBD + replication"
echo "  • dr2  - Secondary DR cluster with Ceph RBD + replication"
echo "  • CSI replication addons and volume replication classes"
echo ""
echo "Available steps:"
echo "  0. Setup custom network"
echo "  1. Create clusters"
echo "  2. Load images" 
echo "  3. Install snapshot controllers"
echo "  4. Install Rook operators"
echo "  5. Create Ceph clusters"
echo "  6. Setup RBD pools"
echo "  7. Install CSI addons"
echo "  8. Create storage and replication classes"
echo ""
log_info "Starting from step: $START_STEP"
echo ""

# Configuration
HUB_PROFILE="hub"
DR1_PROFILE="dr1" 
DR2_PROFILE="dr2"
MINIKUBE_DRIVER="kvm2"
KUBERNETES_VERSION="v1.34.0"
CUSTOM_NETWORK="csi-replication-bridge"

# Step to start from (1-8, default is 1)
START_STEP=${1:-${START_STEP:-1}}

# Check prerequisites
command -v minikube >/dev/null 2>&1 || { log_error "minikube is required"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { log_error "kubectl is required"; exit 1; }
command -v docker >/dev/null 2>&1 || { log_error "docker is required for image management"; exit 1; }
command -v virsh >/dev/null 2>&1 || { log_error "virsh is required for custom network"; exit 1; }

# Function to create custom network if it doesn't exist
setup_custom_network() {
    log_info "Setting up custom KVM bridge network..."
    
    # Check if network already exists
    if sudo virsh net-list | grep -q "$CUSTOM_NETWORK"; then
        log_success "Custom network '$CUSTOM_NETWORK' already exists"
        return 0
    fi
    
    # Check if network XML file exists
    if [ ! -f "/tmp/csi-replication-network.xml" ]; then
        log_info "Creating network XML definition..."
        cat > /tmp/csi-replication-network.xml << 'EOF'
<network>
  <name>csi-replication-bridge</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='virbr-csi' stp='on' delay='0'/>
  <ip address='192.168.100.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.100.10' end='192.168.100.50'/>
    </dhcp>
  </ip>
</network>
EOF
        log_success "Created network XML definition"
    fi
    
    # Define, start and enable autostart for the network
    log_info "Defining custom network..."
    sudo virsh net-define /tmp/csi-replication-network.xml
    
    log_info "Starting custom network..."
    sudo virsh net-start csi-replication-bridge
    
    log_info "Enabling network autostart..."
    sudo virsh net-autostart csi-replication-bridge
    
    # Add iptables rules for NAT and forwarding if needed
    log_info "Configuring host networking for custom bridge..."
    
    # Add NAT masquerading rule if not exists
    if ! sudo iptables -t nat -C POSTROUTING -s 192.168.100.0/24 ! -d 192.168.100.0/24 -j MASQUERADE 2>/dev/null; then
        sudo iptables -t nat -A POSTROUTING -s 192.168.100.0/24 ! -d 192.168.100.0/24 -j MASQUERADE
        log_success "Added NAT masquerading rule"
    fi
    
    # Add FORWARD rules if not exists
    if ! sudo iptables -C FORWARD -s 192.168.100.0/24 -j ACCEPT 2>/dev/null; then
        sudo iptables -I FORWARD 1 -s 192.168.100.0/24 -j ACCEPT
        log_success "Added FORWARD rule for outbound traffic"
    fi
    
    if ! sudo iptables -C FORWARD -d 192.168.100.0/24 -j ACCEPT 2>/dev/null; then
        sudo iptables -I FORWARD 1 -d 192.168.100.0/24 -j ACCEPT
        log_success "Added FORWARD rule for inbound traffic"
    fi
    
    # Enable IP forwarding
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
    
    log_success "Custom network '$CUSTOM_NETWORK' created and configured successfully"
}

# Define required images
declare -a ROOK_IMAGES=(
    "rook/ceph:v1.13.7"
    "quay.io/ceph/ceph:v18.2.2"
)

declare -a CSI_IMAGES=(
    "registry.k8s.io/sig-storage/csi-attacher:v4.3.0"
    "registry.k8s.io/sig-storage/csi-provisioner:v3.5.0"
    "registry.k8s.io/sig-storage/csi-resizer:v1.8.0"
    "registry.k8s.io/sig-storage/csi-snapshotter:v6.2.2"
    "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.8.0"
    "registry.k8s.io/sig-storage/livenessprobe:v2.8.0"
    "registry.k8s.io/sig-storage/csi-external-health-monitor-controller:v0.7.0"
    "registry.k8s.io/sig-storage/hostpathplugin:v1.9.0"
    "registry.k8s.io/sig-storage/snapshot-controller:v6.2.2"
)

declare -a CSI_ADDONS_IMAGES=(
    "quay.io/csiaddons/k8s-controller:v0.9.1"
    "quay.io/csiaddons/k8s-sidecar:v0.9.1"
    "gcr.io/kubebuilder/kube-rbac-proxy:v0.8.0"
    "quay.io/cephcsi/cephcsi:v3.11.0"
)

# Function to check if Docker image exists locally
image_exists_locally() {
    local image=$1
    docker image inspect "$image" >/dev/null 2>&1
}

# Function to pre-pull and load images
pre_pull_and_load_images() {
    local profile=$1
    local images=("${@:2}")
    
    log_info "Pre-pulling and loading images for $profile cluster..."
    
    for image in "${images[@]}"; do
        log_info "Processing image: $image"
        
        # Check if image exists locally
        if image_exists_locally "$image"; then
            log_success "Image $image already exists locally, skipping download"
        else
            # Try to pull image locally first
            if docker pull "$image" 2>/dev/null; then
                log_success "Downloaded $image successfully"
            else
                log_warning "Failed to download $image - will try alternative registries during deployment"
                continue
            fi
        fi
        
        # Load image into minikube (always do this to ensure it's in the cluster)
        log_info "Loading $image into $profile cluster..."
        if minikube image load "$image" --profile="$profile" 2>/dev/null; then
            log_success "Loaded $image into $profile"
        else
            log_warning "Failed to load $image into $profile"
        fi
    done
}

# Function to validate all images before proceeding
validate_images() {
    log_info "Validating required images availability..."
    local missing_images=()
    local available_images=()
    
    # Combine all required images
    ALL_VALIDATION_IMAGES=("${CSI_IMAGES[@]}" "${ROOK_IMAGES[@]}" "${CSI_ADDONS_IMAGES[@]}")
    
    for image in "${ALL_VALIDATION_IMAGES[@]}"; do
        if image_exists_locally "$image"; then
            available_images+=("$image")
        else
            # Try to pull it
            log_info "Attempting to download missing image: $image"
            if docker pull "$image" 2>/dev/null; then
                available_images+=("$image")
                log_success "Downloaded $image"
            else
                missing_images+=("$image")
                log_warning "Could not download $image"
            fi
        fi
    done
    
    log_info "Image validation results:"
    log_success "Available images: ${#available_images[@]}/${#ALL_VALIDATION_IMAGES[@]}"
    
    if [ ${#missing_images[@]} -gt 0 ]; then
        log_warning "Missing images: ${#missing_images[@]}"
        for img in "${missing_images[@]}"; do
            echo "  - $img"
        done
        log_warning "Setup will continue but some components may fail to start"
        echo ""
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_error "Setup cancelled by user"
            exit 1
        fi
    else
        log_success "All required images are available!"
    fi
    echo ""
}

# Function to check if cluster needs recreation
needs_recreation() {
    local profile=$1
    local target_memory=$2
    local target_cpus=$3
    
    if ! minikube profile list --output=json 2>/dev/null | grep -q "\"Name\":\"$profile\""; then
        return 0  # New cluster needed
    fi
    
    # Check if configuration matches
    local current_memory=$(minikube config get memory -p "$profile" 2>/dev/null || echo "0")
    local current_cpus=$(minikube config get cpus -p "$profile" 2>/dev/null || echo "0")
    
    if [ "$current_memory" != "$target_memory" ] || [ "$current_cpus" != "$target_cpus" ]; then
        log_warning "Cluster '$profile' has different config (mem: $current_memory vs $target_memory, cpu: $current_cpus vs $target_cpus)"
        return 0  # Recreation needed
    fi
    
    return 1  # No recreation needed
}

# Validate Docker images before proceeding
validate_images

# ============================================================================
# STEP 0: Setup Custom KVM Bridge Network
# ============================================================================
if [ "$START_STEP" -le 0 ]; then
log_step "Step 0/8: Setting up custom KVM bridge network for cross-cluster connectivity..."
setup_custom_network
fi  # End of Step 0

# ============================================================================
# STEP 1: Create Clusters
# ============================================================================
if [ "$START_STEP" -le 1 ]; then
log_step "Step 1/8: Creating clusters..."

log_info "Creating hub cluster (management) on custom bridge network..."
minikube start \
    --profile="$HUB_PROFILE" \
    --driver="$MINIKUBE_DRIVER" \
    --memory="4096" \
    --cpus="2" \
    --kubernetes-version="$KUBERNETES_VERSION" \
    --addons=storage-provisioner,default-storageclass \
    --network=csi-replication-bridge \
    --wait=true

log_info "Creating dr1 cluster (primary DR with Ceph) on custom bridge network..."
minikube start \
    --profile="$DR1_PROFILE" \
    --driver="$MINIKUBE_DRIVER" \
    --memory="8192" \
    --cpus="4" \
    --kubernetes-version="$KUBERNETES_VERSION" \
    --addons=storage-provisioner,default-storageclass \
    --extra-disks=2 \
    --disk-size=30g \
    --network=csi-replication-bridge \
    --wait=true

log_info "Creating dr2 cluster (secondary DR with Ceph) on custom bridge network..."
minikube start \
    --profile="$DR2_PROFILE" \
    --driver="$MINIKUBE_DRIVER" \
    --memory="8192" \
    --cpus="4" \
    --kubernetes-version="$KUBERNETES_VERSION" \
    --addons=storage-provisioner,default-storageclass \
    --extra-disks=2 \
    --disk-size=30g \
    --network=csi-replication-bridge \
    --wait=true

# Update contexts
minikube update-context --profile="$HUB_PROFILE"
minikube update-context --profile="$DR1_PROFILE"
minikube update-context --profile="$DR2_PROFILE"

log_success "All clusters created successfully"

# Test cross-cluster connectivity on custom network
log_info "Testing cross-cluster connectivity on custom bridge network..."

# Get cluster IPs
DR1_IP=$(minikube ip --profile="$DR1_PROFILE")
DR2_IP=$(minikube ip --profile="$DR2_PROFILE")
HUB_IP=$(minikube ip --profile="$HUB_PROFILE")

log_info "Cluster IPs on custom network:"
echo "  • Hub:  $HUB_IP"
echo "  • DR1:  $DR1_IP"  
echo "  • DR2:  $DR2_IP"

# Verify IPs are on expected subnet
expected_subnet="192.168.100"
connectivity_success=true

for cluster in "hub:$HUB_IP" "dr1:$DR1_IP" "dr2:$DR2_IP"; do
    name=$(echo $cluster | cut -d: -f1)
    ip=$(echo $cluster | cut -d: -f2)
    
    # Check if IP is on expected subnet
    if [[ "$ip" == ${expected_subnet}.* ]]; then
        log_success "$name is on custom network subnet ($ip)"
    else
        log_warning "$name is not on expected subnet ($ip), expected ${expected_subnet}.x"
    fi
    
    # Test connectivity from host to cluster
    if ping -c 2 -W 3 "$ip" >/dev/null 2>&1; then
        log_success "Host can reach $name ($ip)"
    else
        log_error "Host cannot reach $name ($ip)"
        connectivity_success=false
    fi
done

# Test inter-cluster VM-to-VM connectivity using custom bridge network
if [ "$connectivity_success" = true ]; then
    log_info "Testing VM-to-VM connectivity between DR clusters..."
    
    echo "=== Testing dr1 VM → dr2 VM (ping) ==="
    if minikube ssh --profile="$DR1_PROFILE" -- ping -c 3 "$DR2_IP" >/dev/null 2>&1; then
        log_success "✅ DR1 VM can ping DR2 VM ($DR2_IP)"
    else
        log_error "❌ DR1 VM cannot ping DR2 VM ($DR2_IP) - custom bridge network issue"
    fi
    
    echo "=== Testing dr2 VM → dr1 VM (ping) ==="  
    if minikube ssh --profile="$DR2_PROFILE" -- ping -c 3 "$DR1_IP" >/dev/null 2>&1; then
        log_success "✅ DR2 VM can ping DR1 VM ($DR1_IP)"
    else
        log_error "❌ DR2 VM cannot ping DR1 VM ($DR1_IP) - custom bridge network issue"
    fi
    
    log_success "VM-to-VM connectivity test completed"
    log_info "Pod-to-pod cross-cluster connectivity will be tested after Ceph services are created"
else
    log_error "Skipping VM connectivity test due to host connectivity failures"
    log_info "Please check your custom network configuration:"
    echo "  sudo virsh net-dumpxml csi-replication-bridge"
    echo "  ip route | grep 192.168.100"
fi

fi  # End of Step 1

# ============================================================================
# PRE-LOAD IMAGES (ONE-TIME DOWNLOAD)  
# ============================================================================
if [ "$START_STEP" -le 2 ]; then
log_step "Step 2/7: Pre-loading required images to avoid network issues..."

# Combine all required images and download once
ALL_IMAGES=("${CSI_IMAGES[@]}" "${ROOK_IMAGES[@]}" "${CSI_ADDONS_IMAGES[@]}")

log_info "Downloading any missing images locally..."
for image in "${ALL_IMAGES[@]}"; do
    if ! image_exists_locally "$image"; then
        log_info "Downloading $image..."
        if docker pull "$image" 2>/dev/null; then
            log_success "Downloaded $image"
        else
            log_warning "Failed to download $image"
        fi
    fi
done

log_info "Loading images into DR clusters..."

log_info "Loading images into DR clusters in parallel..."

# Function to load images into a cluster
load_images_to_cluster() {
    local profile=$1
    local cluster_name=$(echo "$profile" | tr '[:lower:]' '[:upper:]')
    
    log_info "Starting image loading for $cluster_name cluster..."
    for image in "${ALL_IMAGES[@]}"; do
        if image_exists_locally "$image"; then
            log_info "Loading $image into $profile..."
            if minikube image load "$image" --profile="$profile" 2>/dev/null; then
                log_success "✓ $image → $profile"
            else
                log_warning "✗ Failed to load $image into $profile"
            fi
        fi
    done
    log_success "Completed image loading for $cluster_name cluster"
}

# Load images into both clusters in parallel
load_images_to_cluster "$DR1_PROFILE" &
DR1_PID=$!
load_images_to_cluster "$DR2_PROFILE" &
DR2_PID=$!

# Wait for both background jobs to complete
log_info "Waiting for parallel image loading to complete..."
wait $DR1_PID
DR1_STATUS=$?
wait $DR2_PID  
DR2_STATUS=$?

if [ $DR1_STATUS -eq 0 ] && [ $DR2_STATUS -eq 0 ]; then
    log_success "Parallel image loading completed successfully"
else
    log_warning "Some image loading operations failed (DR1: $DR1_STATUS, DR2: $DR2_STATUS)"
fi

# Verify images are loaded in clusters
log_info "Verifying image availability in clusters..."
for profile in "$DR1_PROFILE" "$DR2_PROFILE"; do
    log_info "Checking images in $profile..."
    available_count=$(minikube image ls --profile="$profile" --format=table 2>/dev/null | grep -E "(snapshot-controller|csi-|rook|ceph)" | wc -l)
    log_info "Found $available_count relevant images in $profile cluster"
done

# Verify network connectivity between DR clusters
log_info "Verifying network connectivity between DR clusters..."
DR1_IP=$(minikube ip --profile="$DR1_PROFILE")
DR2_IP=$(minikube ip --profile="$DR2_PROFILE")

log_info "DR1 cluster IP: $DR1_IP"
log_info "DR2 cluster IP: $DR2_IP"

# Test connectivity between DR clusters (kvm2 VMs can communicate by default)
log_info "Testing network connectivity for CSI replication..."
if ping -c 1 "$DR1_IP" >/dev/null 2>&1 && ping -c 1 "$DR2_IP" >/dev/null 2>&1; then
    log_success "DR clusters are accessible from host"
else
    log_warning "Some clusters may have connectivity issues"
fi

# ============================================================================
# STEP 2: Install Snapshot Controllers and CSI Components
# ============================================================================
log_step "Step 2/8: Installing snapshot controllers and CSI components..."

# Install snapshot controller manually on both DR clusters
log_info "Installing snapshot controllers..."

# Install snapshot CRDs first
kubectl --context=dr1 apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.1.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl --context=dr1 apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.1.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl --context=dr1 apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.1.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml

kubectl --context=dr2 apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.1.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl --context=dr2 apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.1.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl --context=dr2 apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.1.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml

# Install snapshot controller RBAC and deployment
kubectl --context=dr1 apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.1.0/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl --context=dr1 apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.1.0/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml

kubectl --context=dr2 apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.1.0/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl --context=dr2 apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.1.0/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml

# Patch snapshot controllers to use local images
log_info "Patching snapshot controllers to use local images..."
kubectl --context=dr1 patch deployment snapshot-controller -n kube-system -p '{"spec":{"template":{"spec":{"containers":[{"name":"volume-snapshot-controller","imagePullPolicy":"IfNotPresent","image":"registry.k8s.io/sig-storage/snapshot-controller:v6.2.2"}]}}}}'
kubectl --context=dr2 patch deployment snapshot-controller -n kube-system -p '{"spec":{"template":{"spec":{"containers":[{"name":"volume-snapshot-controller","imagePullPolicy":"IfNotPresent","image":"registry.k8s.io/sig-storage/snapshot-controller:v6.2.2"}]}}}}'
fi  # End of Step 3

# ============================================================================
# STEP 3: Install Rook Ceph Operators
# ============================================================================
if [ "$START_STEP" -le 4 ]; then
log_step "Step 4/8: Installing Rook Ceph operators on DR clusters..."

# Install on dr1 with image pull policy adjustments
log_info "Installing Rook operator on dr1..."
kubectl --context=dr1 apply -f https://raw.githubusercontent.com/rook/rook/v1.12.3/deploy/examples/crds.yaml
kubectl --context=dr1 apply -f https://raw.githubusercontent.com/rook/rook/v1.12.3/deploy/examples/common.yaml
kubectl --context=dr1 apply -f "$(dirname "$SCRIPT_DIR")/yaml/objects/rook-operator.yaml"
kubectl --context=dr1 apply -f https://raw.githubusercontent.com/rook/rook/v1.12.3/deploy/examples/operator.yaml

# Install on dr2 with image pull policy adjustments
log_info "Installing Rook operator on dr2..."
kubectl --context=dr2 apply -f https://raw.githubusercontent.com/rook/rook/v1.12.3/deploy/examples/crds.yaml
kubectl --context=dr2 apply -f https://raw.githubusercontent.com/rook/rook/v1.12.3/deploy/examples/common.yaml
kubectl --context=dr2 apply -f "$(dirname "$SCRIPT_DIR")/yaml/objects/rook-operator.yaml"
kubectl --context=dr2 apply -f https://raw.githubusercontent.com/rook/rook/v1.12.3/deploy/examples/operator.yaml

# Patch operator deployments to use IfNotPresent pull policy
log_info "Patching image pull policies..."
kubectl --context=dr1 patch deployment rook-ceph-operator -n rook-ceph -p '{"spec":{"template":{"spec":{"containers":[{"name":"rook-ceph-operator","imagePullPolicy":"IfNotPresent"}]}}}}'
kubectl --context=dr2 patch deployment rook-ceph-operator -n rook-ceph -p '{"spec":{"template":{"spec":{"containers":[{"name":"rook-ceph-operator","imagePullPolicy":"IfNotPresent"}]}}}}'

log_info "Waiting for Rook operators to be ready (this may take 5-10 minutes)..."
kubectl --context=dr1 wait --for=condition=ready pod -l app=rook-ceph-operator -n rook-ceph --timeout=900s || {
    log_warning "DR1 Rook operator taking longer than expected, checking status..."
    kubectl --context=dr1 get pods -n rook-ceph
    kubectl --context=dr1 describe pod -l app=rook-ceph-operator -n rook-ceph
}
kubectl --context=dr2 wait --for=condition=ready pod -l app=rook-ceph-operator -n rook-ceph --timeout=900s || {
    log_warning "DR2 Rook operator taking longer than expected, checking status..."
    kubectl --context=dr2 get pods -n rook-ceph
    kubectl --context=dr2 describe pod -l app=rook-ceph-operator -n rook-ceph
}

log_success "Rook operators installed"
fi  # End of Step 4

# ============================================================================
# STEP 5: Create Ceph Clusters
# ============================================================================
if [ "$START_STEP" -le 5 ]; then
log_step "Step 5/8: Creating Ceph clusters with mirroring..."

log_info "Deploying Ceph clusters using yaml/objects/ceph-cluster.yaml..."
kubectl --context=dr1 apply -f "$SCRIPT_DIR/../yaml/objects/ceph-cluster.yaml"
kubectl --context=dr2 apply -f "$SCRIPT_DIR/../yaml/objects/ceph-cluster.yaml"

log_success "Ceph clusters created"
fi  # End of Step 5

# ============================================================================
# STEP 6: Create RBD Pools with Mirroring
# ============================================================================
if [ "$START_STEP" -le 6 ]; then
log_step "Step 6/8: Setting up RBD pools with mirroring..."

# Wait for Ceph clusters to be ready first
log_info "Waiting for Ceph clusters to be ready (this may take 10-15 minutes)..."

# Function to check if ceph cluster is ready (Ready phase is sufficient, even with health warnings)
check_ceph_ready() {
    local context=$1
    local phase=$(kubectl --context=$context get cephcluster/rook-ceph -n rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ "$phase" = "Ready" ]
}

# Wait for DR1 Ceph cluster
log_info "Waiting for DR1 Ceph cluster..."
timeout=900
start_time=$(date +%s)
while ! check_ceph_ready "dr1"; do
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    if [ $elapsed -gt $timeout ]; then
        log_warning "DR1 Ceph cluster timeout after ${timeout}s, checking status..."
        kubectl --context=dr1 get cephcluster -n rook-ceph -o wide
        break
    fi
    sleep 10
done

if check_ceph_ready "dr1"; then
    log_success "DR1 Ceph cluster is ready"
else
    log_warning "DR1 Ceph cluster may not be fully ready, but continuing..."
fi

# Wait for DR2 Ceph cluster  
log_info "Waiting for DR2 Ceph cluster..."
start_time=$(date +%s)
while ! check_ceph_ready "dr2"; do
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    if [ $elapsed -gt $timeout ]; then
        log_warning "DR2 Ceph cluster timeout after ${timeout}s, checking status..."
        kubectl --context=dr2 get cephcluster -n rook-ceph -o wide
        break
    fi
    sleep 10
done

if check_ceph_ready "dr2"; then
    log_success "DR2 Ceph cluster is ready"
else
    log_warning "DR2 Ceph cluster may not be fully ready, but continuing..."
fi

log_info "Creating RBD pools using yaml/objects/ceph-blockpool.yaml..."
kubectl --context=dr1 apply -f "$SCRIPT_DIR/../yaml/objects/ceph-blockpool.yaml"
kubectl --context=dr2 apply -f "$SCRIPT_DIR/../yaml/objects/ceph-blockpool.yaml"

log_success "RBD pools with mirroring created"
fi  # End of Step 6

# ============================================================================
# STEP 7: Install CSI Replication Addons
# ============================================================================
if [ "$START_STEP" -le 7 ]; then
log_step "Step 7/8: Installing CSI replication addons..."

# Install CSI addons for replication
log_info "Installing CSI addons for replication..."
# Create namespaces first
safe_create_namespace "dr1" "csi-addons-system"
safe_create_namespace "dr2" "csi-addons-system"

# Install CRDs
kubectl --context=dr1 apply -f https://raw.githubusercontent.com/csi-addons/kubernetes-csi-addons/v0.8.0/deploy/controller/crds.yaml
kubectl --context=dr2 apply -f https://raw.githubusercontent.com/csi-addons/kubernetes-csi-addons/v0.8.0/deploy/controller/crds.yaml

# Install RBAC resources
kubectl --context=dr1 apply -f https://raw.githubusercontent.com/csi-addons/kubernetes-csi-addons/v0.8.0/deploy/controller/rbac.yaml
kubectl --context=dr2 apply -f https://raw.githubusercontent.com/csi-addons/kubernetes-csi-addons/v0.8.0/deploy/controller/rbac.yaml

# Install controller
kubectl --context=dr1 apply -f https://raw.githubusercontent.com/csi-addons/kubernetes-csi-addons/v0.8.0/deploy/controller/setup-controller.yaml
kubectl --context=dr2 apply -f https://raw.githubusercontent.com/csi-addons/kubernetes-csi-addons/v0.8.0/deploy/controller/setup-controller.yaml

# Patch imagePullPolicy to avoid pulling from internet for local minikube environment
log_info "Patching CSI addons controller imagePullPolicy..."
kubectl --context=dr1 patch deployment csi-addons-controller-manager -n csi-addons-system -p '{"spec":{"template":{"spec":{"containers":[{"name":"manager","imagePullPolicy":"IfNotPresent","image":"quay.io/csiaddons/k8s-controller:v0.9.1"}]}}}}' || true
kubectl --context=dr2 patch deployment csi-addons-controller-manager -n csi-addons-system -p '{"spec":{"template":{"spec":{"containers":[{"name":"manager","imagePullPolicy":"IfNotPresent","image":"quay.io/csiaddons/k8s-controller:v0.9.1"}]}}}}' || true

# Wait for controller to be ready
log_info "Waiting for CSI addons controllers to be ready..."
kubectl --context=dr1 wait --for=condition=ready pod -l app.kubernetes.io/name=csi-addons -n csi-addons-system --timeout=120s || log_warning "CSI addons controller on dr1 may not be ready yet"
kubectl --context=dr2 wait --for=condition=ready pod -l app.kubernetes.io/name=csi-addons -n csi-addons-system --timeout=120s || log_warning "CSI addons controller on dr2 may not be ready yet"

# Enable CSI addons endpoint in Ceph CSI driver
log_info "Configuring CSI addons endpoint in Ceph CSI drivers..."
kubectl --context=dr1 patch deployment csi-rbdplugin-provisioner -n rook-ceph --type='json' -p "$(cat "$SCRIPT_DIR/../yaml/patches/csi-rbdplugin-addons-endpoint.json")" || log_warning "Failed to patch dr1 CSI driver (may already be configured)"

kubectl --context=dr2 patch deployment csi-rbdplugin-provisioner -n rook-ceph --type='json' -p "$(cat "$SCRIPT_DIR/../yaml/patches/csi-rbdplugin-addons-endpoint.json")" || log_warning "Failed to patch dr2 CSI driver (may already be configured)"

# Wait for CSI drivers to restart with addons endpoint
log_info "Waiting for CSI RBD provisioners to restart with addons endpoint..."
kubectl --context=dr1 rollout status deployment/csi-rbdplugin-provisioner -n rook-ceph --timeout=180s || log_warning "DR1 CSI driver restart timeout"
kubectl --context=dr2 rollout status deployment/csi-rbdplugin-provisioner -n rook-ceph --timeout=180s || log_warning "DR2 CSI driver restart timeout"

# Create NodePort services to expose Ceph monitors for cross-cluster communication
log_info "Creating NodePort services for Ceph cross-cluster communication..."
kubectl --context=dr1 apply -f "$(dirname "$SCRIPT_DIR")/yaml/objects/ceph-mon-nodeport-service.yaml"
kubectl --context=dr2 apply -f "$(dirname "$SCRIPT_DIR")/yaml/objects/ceph-mon-nodeport-service.yaml"

# Wait for NodePort services to be ready
log_info "Waiting for NodePort services to be ready..."
kubectl --context=dr1 wait --for=condition=ready --timeout=60s service/ceph-mon-nodeport -n rook-ceph || log_warning "DR1 NodePort service may not be ready yet"
kubectl --context=dr2 wait --for=condition=ready --timeout=60s service/ceph-mon-nodeport -n rook-ceph || log_warning "DR2 NodePort service may not be ready yet"

# Test pod-to-pod cross-cluster connectivity now that services are available
log_info "Testing pod-to-pod cross-cluster connectivity via NodePort services..."

# Get cluster IPs
DR1_IP=$(minikube ip --profile="$DR1_PROFILE")
DR2_IP=$(minikube ip --profile="$DR2_PROFILE")

# Test critical Ceph ports that CSI replication will need
declare -a test_ports=("30789" "30300")  # NodePort ports for Ceph monitor and manager

log_info "Testing DR1 → DR2 connectivity on Ceph NodePort services..."
dr1_to_dr2_success=true
for port in "${test_ports[@]}"; do
    echo "=== Testing dr1 Pod → dr2 NodePort:$port ===" 
    if timeout 10 kubectl --context="$DR1_PROFILE" run cross-cluster-test-dr1-$port --rm -i --restart=Never --image=busybox:1.36 -- nc -zv "$DR2_IP" "$port" 2>/dev/null; then
        log_success "✅ dr1-pod → dr2:$port SUCCESS"
    else
        log_warning "❌ dr1-pod → dr2:$port FAILED - Ceph services may not be fully ready"
        dr1_to_dr2_success=false
    fi
done

log_info "Testing DR2 → DR1 connectivity on Ceph NodePort services..."
dr2_to_dr1_success=true
for port in "${test_ports[@]}"; do
    echo "=== Testing dr2 Pod → dr1 NodePort:$port ==="
    if timeout 10 kubectl --context="$DR2_PROFILE" run cross-cluster-test-dr2-$port --rm -i --restart=Never --image=busybox:1.36 -- nc -zv "$DR1_IP" "$port" 2>/dev/null; then
        log_success "✅ dr2-pod → dr1:$port SUCCESS"
    else
        log_warning "❌ dr2-pod → dr1:$port FAILED - Ceph services may not be fully ready"
        dr2_to_dr1_success=false
    fi
done

# Summary of cross-cluster connectivity
if [ "$dr1_to_dr2_success" = true ] && [ "$dr2_to_dr1_success" = true ]; then
    log_success "🎉 Cross-cluster pod connectivity via NodePorts is working - CSI replication should work!"
else
    log_info "ℹ️  Some NodePort connectivity tests failed - Ceph may need more time to become ready"
fi

log_success "CSI replication addons installed and configured"
fi  # End of Step 7

# ============================================================================
# STEP 8: Setup Storage Classes and Volume Replication Classes
# ============================================================================
if [ "$START_STEP" -le 8 ]; then
log_step "Step 8/8: Creating storage and replication classes..."

# Wait for Ceph clusters to be ready
log_info "Waiting for Ceph clusters to be ready (this may take 10-15 minutes)..."
kubectl --context=dr1 wait --for=condition=ready cephcluster/rook-ceph -n rook-ceph --timeout=900s || {
    log_warning "DR1 Ceph taking longer than expected, showing status..."
    kubectl --context=dr1 get cephcluster -n rook-ceph -o wide
    kubectl --context=dr1 get pods -n rook-ceph
}
kubectl --context=dr2 wait --for=condition=ready cephcluster/rook-ceph -n rook-ceph --timeout=900s || {
    log_warning "DR2 Ceph taking longer than expected, showing status..."
    kubectl --context=dr2 get cephcluster -n rook-ceph -o wide
    kubectl --context=dr2 get pods -n rook-ceph
}

# Create RBD storage class
log_info "Creating storage class using yaml/objects/rbd-storage-class.yaml..."
kubectl --context=dr1 apply -f "$SCRIPT_DIR/../yaml/objects/rbd-storage-class.yaml"
kubectl --context=dr2 apply -f "$SCRIPT_DIR/../yaml/objects/rbd-storage-class.yaml"

# Create Volume Replication Classes
log_info "Creating volume replication classes using yaml/objects/volume-replication-class.yaml..."
kubectl --context=dr1 apply -f "$SCRIPT_DIR/../yaml/objects/volume-replication-class.yaml"
kubectl --context=dr2 apply -f "$SCRIPT_DIR/../yaml/objects/volume-replication-class.yaml"

# Create Volume Snapshot Class
log_info "Creating volume snapshot class using yaml/objects/volume-snapshot-class.yaml..."
kubectl --context=dr1 apply -f "$SCRIPT_DIR/../yaml/objects/volume-snapshot-class.yaml"
kubectl --context=dr2 apply -f "$SCRIPT_DIR/../yaml/objects/volume-snapshot-class.yaml"

# Create CSIAddonsNode resources for service discovery
log_info "Creating CSIAddonsNode resources for CSI addons service discovery..."
kubectl --context=dr1 apply -f "$SCRIPT_DIR/../yaml/objects/csi-addons-node-dr1.yaml"
kubectl --context=dr2 apply -f "$SCRIPT_DIR/../yaml/objects/csi-addons-node-dr2.yaml"

log_success "Storage and replication classes created"
fi  # End of Step 8

# ============================================================================
# CLEANUP AND VERIFICATION
# ============================================================================

# Calculate total time
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))
MINUTES=$((TOTAL_TIME / 60))
SECONDS=$((TOTAL_TIME % 60))

log_success "🎉 DR Clusters with Ceph Storage & Replication Setup Complete!"
log_info "Total setup time: ${MINUTES}m ${SECONDS}s"
echo ""

# Show status
echo -e "${CYAN}📊 Cluster Status:${NC}"
minikube profile list

echo ""
echo -e "${CYAN}🎯 Available Contexts:${NC}"
kubectl config get-contexts | grep -E "(hub|dr1|dr2)"

echo ""
echo -e "${CYAN}💾 Storage Components Deployed:${NC}"
echo "  • Rook Ceph operators on dr1 and dr2"
echo "  • RBD pools with mirroring enabled"
echo "  • CSI replication addons with endpoint configuration"
echo "  • CSIAddonsNode resources for service discovery"
echo "  • NodePort services for cross-cluster Ceph communication"
echo "  • Volume replication classes (2m, 5m intervals)"
echo "  • Volume snapshot classes"
echo ""

echo -e "${CYAN}🌐 Cross-Cluster Connectivity:${NC}"
DR1_IP=$(minikube ip --profile="$DR1_PROFILE" 2>/dev/null || echo "N/A")
DR2_IP=$(minikube ip --profile="$DR2_PROFILE" 2>/dev/null || echo "N/A")
echo "  • DR1 Ceph Monitor: $DR1_IP:30789"
echo "  • DR2 Ceph Monitor: $DR2_IP:30789"
echo "  • Cross-cluster networking: NodePort services"
echo ""

echo -e "${CYAN}🧪 Test Your Setup:${NC}"
echo "  1. Check Ceph health:"
echo "     kubectl --context=dr1 -n rook-ceph get cephcluster"
echo "     kubectl --context=dr2 -n rook-ceph get cephcluster"
echo ""
echo "  2. List storage classes:"
echo "     kubectl --context=dr1 get storageclass"
echo "     kubectl --context=dr2 get storageclass"
echo ""
echo "  3. List volume replication classes:"
echo "     kubectl --context=dr1 get volumereplicationclass"
echo "     kubectl --context=dr2 get volumereplicationclass"
echo ""
echo "  4. Start monitoring:"
echo "     ./regional-dr-monitoring.sh"
echo ""

echo -e "${PURPLE}🚀 Ready for CSI Replication Testing!${NC}"
echo "Your clusters are now ready for:"
echo "  • Volume replication between dr1 ↔ dr2"  
echo "  • RamenDR disaster recovery scenarios"
echo "  • CSI snapshot and clone operations"
echo "  • Cross-cluster application failover testing"