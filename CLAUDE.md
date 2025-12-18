# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ramen is a disaster recovery and workload relocation operator for Kubernetes, designed for open-cluster-management (OCM) environments. It provides recovery and relocation services for workloads and their persistent data across OCM managed clusters.

Key capabilities:
- Workload relocation for planned migrations across clusters
- Workload recovery for unplanned cluster failures
- Storage replication using CSI storage replication addon
- Integration with ceph-csi and volume replication operators

## Development Commands

### Building and Testing
```bash
# Build the manager binary
make build

# Run all tests
make test

# Run specific test suites
make test-drpc                    # DRPlacementControl tests
make test-vrg                     # VolumeReplicationGroup tests
make test-drcluster              # DRCluster tests
make test-drpolicy               # DRPolicy tests
make test-util                   # Utility tests

# Build Docker image
make docker-build

# Generate manifests and code
make generate manifests
```

### Linting
```bash
# Run all linters
make lint

# Individual linter targets
make lint-config-verify          # Verify golangci-lint config
make lint-e2e                    # Lint e2e module
make lint-api                    # Lint api module
```

### Environment Setup
```bash
# Create python virtual environment
make venv
source venv

# Create development environment (3 minikube clusters)
make create-rdr-env

# Destroy development environment
make destroy-rdr-env
```

### Deployment
```bash
# Deploy to Kubernetes
make deploy                      # Deploy both hub and dr-cluster
make deploy-hub                  # Deploy hub controller only
make deploy-dr-cluster          # Deploy dr-cluster controller only

# Undeploy
make undeploy
make undeploy-hub
make undeploy-dr-cluster
```

### Running Locally
```bash
# Run hub controller locally
make run-hub

# Run dr-cluster controller locally
make run-dr-cluster
```

## Architecture

### Core Components

**API Types** (`api/v1alpha1/`):
- `DRPolicy` - Defines disaster recovery policies between clusters
- `DRCluster` - Represents a cluster in the DR topology
- `DRPlacementControl` - Controls workload placement and DR operations
- `VolumeReplicationGroup` - Groups volumes for replication
- `RamenConfig` - Global configuration for Ramen
- `MaintenanceMode` - Controls cluster maintenance state

**Controllers** (`internal/controller/`):
- `drplacementcontrol_controller.go` - Main orchestration controller
- `drpolicy_controller.go` - Manages DR policies
- `drcluster_controller.go` - Manages cluster resources
- `volumereplicationgroup_controller.go` - Handles volume replication

**Key Packages**:
- `internal/controller/util/` - Shared utilities and helpers
- `internal/controller/volsync/` - VolSync integration
- `internal/controller/kubeobjects/` - Kubernetes object management
- `internal/controller/hooks/` - Extensible hook system

### Multi-Module Structure

The repository contains multiple Go modules:
- Main module (`go.mod`) - Core Ramen operator
- API module (`api/go.mod`) - CRD definitions and types
- E2E module (`e2e/go.mod`) - End-to-end tests

### Storage Integration

Ramen integrates with:
- CSI Volume Replication for storage-level replication
- VolSync for async volume replication
- Velero for backup/restore operations
- Ceph storage systems via ceph-csi

## Testing Framework

Uses Ginkgo/Gomega for testing:
- Unit tests in `*_test.go` files alongside source
- Suite tests in `suite_test.go` files
- E2E tests in `e2e/` directory
- Test utilities in `internal/controller/testutils/`

## Configuration

- Linting: `.golangci.yaml` with comprehensive Go linters
- Development environment: `test/envs/regional-dr.yaml`
- Example configs: `examples/dr_hub_config.yaml`, `examples/dr_cluster_config.yaml`

## Key Development Practices

- Uses controller-runtime framework for Kubernetes controllers
- Follows OCM patterns for multi-cluster management
- Implements comprehensive validation using CEL expressions
- Uses structured logging with logr/zap
- Supports both hub and spoke cluster deployments