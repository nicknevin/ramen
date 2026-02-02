#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Utility functions for Kubernetes resource management

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${CYAN}ℹ️  [$(date '+%H:%M:%S')] $1${NC}"; }
log_success() { echo -e "${GREEN}✅ [$(date '+%H:%M:%S')] $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  [$(date '+%H:%M:%S')] $1${NC}"; }
log_error() { echo -e "${RED}❌ [$(date '+%H:%M:%S')] $1${NC}"; }
log_step() { echo -e "${PURPLE}🔧 [$(date '+%H:%M:%S')] $1${NC}"; }

# Utility functions to check if Kubernetes resources exist
check_namespace_exists() {
    local context=$1
    local namespace=$2
    kubectl --context="$context" get namespace "$namespace" >/dev/null 2>&1
    return $?
}

check_pvc_exists() {
    local context=$1
    local namespace=$2
    local pvc_name=$3
    kubectl --context="$context" get pvc "$pvc_name" -n "$namespace" >/dev/null 2>&1
    return $?
}

check_volumereplication_exists() {
    local context=$1
    local namespace=$2
    local vr_name=$3
    kubectl --context="$context" get volumereplication "$vr_name" -n "$namespace" >/dev/null 2>&1
    return $?
}

check_pod_exists() {
    local context=$1
    local namespace=$2
    local pod_name=$3
    kubectl --context="$context" get pod "$pod_name" -n "$namespace" >/dev/null 2>&1
    return $?
}

check_deployment_exists() {
    local context=$1
    local namespace=$2
    local deployment=$3
    kubectl --context="$context" get deployment "$deployment" -n "$namespace" >/dev/null 2>&1
    return $?
}

check_storageclass_exists() {
    local context=$1
    local storageclass=$2
    kubectl --context="$context" get storageclass "$storageclass" >/dev/null 2>&1
    return $?
}

check_crd_exists() {
    local context=$1
    local crd=$2
    kubectl --context="$context" get crd "$crd" >/dev/null 2>&1
    return $?
}

check_secret_exists() {
    local context=$1
    local namespace=$2
    local secret_name=$3
    kubectl --context="$context" get secret "$secret_name" -n "$namespace" >/dev/null 2>&1
    return $?
}

check_service_exists() {
    local context=$1
    local namespace=$2
    local service_name=$3
    kubectl --context="$context" get service "$service_name" -n "$namespace" >/dev/null 2>&1
    return $?
}

# Safe creation functions that check for existence first
safe_create_namespace() {
    local context=$1
    local namespace=$2
    
    if check_namespace_exists "$context" "$namespace"; then
        log_info "Namespace '$namespace' already exists on $context"
        return 0
    else
        log_info "Creating namespace '$namespace' on $context..."
        kubectl --context="$context" create namespace "$namespace" --dry-run=client -o yaml | kubectl --context="$context" apply -f -
        return $?
    fi
}

safe_apply_manifest() {
    local context=$1
    local manifest_file=$2
    local resource_type=$3
    local resource_name=$4
    local namespace=${5:-""}
    
    if [[ -n "$namespace" ]]; then
        local ns_flag="-n $namespace"
        local resource_identifier="$resource_type/$resource_name in namespace $namespace"
    else
        local ns_flag=""
        local resource_identifier="$resource_type/$resource_name"
    fi
    
    log_info "Checking if $resource_identifier exists on $context..."
    if kubectl --context="$context" get "$resource_type" "$resource_name" $ns_flag >/dev/null 2>&1; then
        log_warning "$resource_identifier already exists on $context - applying updates if any..."
    else
        log_info "Creating $resource_identifier on $context..."
    fi
    
    kubectl --context="$context" apply -f "$manifest_file"
    return $?
}

# Wait for resource to be ready with timeout
wait_for_pod_ready() {
    local context=$1
    local namespace=$2
    local pod_name=$3
    local timeout=${4:-60}
    
    log_info "Waiting for pod '$pod_name' to be ready (timeout: ${timeout}s)..."
    kubectl --context="$context" wait --for=condition=ready pod/"$pod_name" -n "$namespace" --timeout="${timeout}s"
    return $?
}

wait_for_deployment_ready() {
    local context=$1
    local namespace=$2
    local deployment_name=$3
    local timeout=${4:-120}
    
    log_info "Waiting for deployment '$deployment_name' to be ready (timeout: ${timeout}s)..."
    kubectl --context="$context" wait --for=condition=available deployment/"$deployment_name" -n "$namespace" --timeout="${timeout}s"
    return $?
}

wait_for_pvc_bound() {
    local context=$1
    local namespace=$2
    local pvc_name=$3
    local timeout=${4:-180}
    
    log_info "Waiting for PVC '$pvc_name' to be bound (timeout: ${timeout}s)..."
    kubectl --context="$context" wait --for=condition=bound pvc/"$pvc_name" -n "$namespace" --timeout="${timeout}s"
    return $?
}

# Resource status checking functions
get_pod_status() {
    local context=$1
    local namespace=$2
    local pod_name=$3
    
    kubectl --context="$context" get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound"
}

get_pvc_status() {
    local context=$1
    local namespace=$2
    local pvc_name=$3
    
    kubectl --context="$context" get pvc "$pvc_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound"
}

get_deployment_ready_replicas() {
    local context=$1
    local namespace=$2
    local deployment_name=$3
    
    kubectl --context="$context" get deployment "$deployment_name" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0"
}

# Cleanup functions
safe_delete_resource() {
    local context=$1
    local resource_type=$2
    local resource_name=$3
    local namespace=${4:-""}
    
    if [[ -n "$namespace" ]]; then
        local ns_flag="-n $namespace"
        local resource_identifier="$resource_type/$resource_name in namespace $namespace"
    else
        local ns_flag=""
        local resource_identifier="$resource_type/$resource_name"
    fi
    
    log_info "Safely deleting $resource_identifier from $context..."
    kubectl --context="$context" delete "$resource_type" "$resource_name" $ns_flag --ignore-not-found=true
    return $?
}

# Image management utilities
check_minikube_image_exists() {
    local profile=$1
    local image=$2
    
    minikube image ls --format table -p "$profile" | grep -q "$image"
    return $?
}

load_image_to_minikube() {
    local image=$1
    local profile=$2
    
    if check_minikube_image_exists "$profile" "$image"; then
        log_info "Image '$image' already exists in $profile cluster"
        return 0
    else
        log_info "Loading image '$image' to $profile cluster..."
        minikube image load "$image" -p "$profile"
        return $?
    fi
}