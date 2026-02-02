# Using RamenDR's Rook Environment for CSI Replication Testing

This guide explains how to leverage RamenDR's proven `rook.yaml` environment for direct CSI Replication Add-on testing with Ceph storage.

> **📖 Complete Testing Guide**: See [docs/testing/csi-replication-testing.md](csi-replication-testing.md) for comprehensive setup, testing procedures, troubleshooting, and advanced scenarios.

## Why Use RamenDR's Rook Environment?

We use RamenDR's existing `rook.yaml` environment because it provides:

1. **Focused on Storage**: Just Ceph/Rook components without management overhead
2. **Battle-tested**: Proven Rook and CSI configurations used in RamenDR testing
3. **Complete CSI Stack**: All necessary CSI addons and replication components
4. **Working RBD Mirroring**: Automatic cross-cluster RBD mirroring setup
5. **No Complex Dependencies**: Avoids OCM, Submariner, and other management components

## Architecture

The `rook.yaml` environment creates:

- **dr1**: Primary cluster with full Ceph deployment and CSI replication
- **dr2**: Secondary cluster with full Ceph deployment and CSI replication  
- **RBD Mirroring**: Automatically configured bidirectional mirroring between dr1 ↔ dr2
- **CSI Addons**: Volume replication controllers, CRDs, and snapshot support
- **Storage Classes**: Ready-to-use RBD storage classes and pools

## Quick Start

### Essential Make Targets

```bash
# 1. Setup complete environment (20-30 minutes)
#    Includes: clusters, Ceph, CSI Addons, TLS fixes, storage resources
make setup-csi-replication

# 2. Test CSI replication functionality 
make test-csi-replication

# 3. Clean up duplicate resources (if running setup multiple times)
make clean-csi-duplicates

# 4. Stop clusters (keep VMs for faster restart)
make stop-csi-replication

# 5. Start existing clusters
make start-csi-replication  

# 6. Delete everything completely
make delete-csi-replication
```

That's it! The `setup-csi-replication` target handles everything automatically:
- ✅ Creates dr1 + dr2 clusters with Ceph storage
- ✅ Deploys and configures CSI Addons (with TLS fixes)
- ✅ Sets up storage classes and VolumeReplicationClasses
- ✅ Configures cross-cluster RBD mirroring
- ✅ Verifies all components are working

> **📋 Need more details?** The sections below provide complete environment information, customization options, and troubleshooting guides.

## Summary

**6 Essential Commands:**
1. `make setup-csi-replication` → Complete environment setup (one-time, ~25 min)
2. `make test-csi-replication` → Test CSI replication functionality  
3. `make test-csi-failover` → Test volume failover (demote/promote flow)
4. `make clean-csi-duplicates` → Clean up duplicate resources
5. `make stop-csi-replication` → Stop clusters (keep VMs)
6. `make start-csi-replication` → Start stopped clusters  
7. `make delete-csi-replication` → Remove everything

**What you get:** Two Kubernetes clusters (dr1, dr2) with Ceph storage, CSI replication, and cross-cluster RBD mirroring - ready for CSI API testing without RamenDR complexity.

**⚠️ Important Notes:**
- `make start-csi-replication` is **idempotent** - safe to run multiple times
- If clusters are already running, it will apply TLS fixes and continue normally
- If clusters don't exist, you need `make setup-csi-replication` first
- Running `make setup-csi-replication` multiple times may create duplicate resources

## Duplicate Resource Management

Running `make setup-csi-replication` multiple times can create duplicate resources due to image pull failures or incomplete setups. The `clean-csi-duplicates` target provides a solution:

### What Gets Cleaned Up

The `make clean-csi-duplicates` command removes:
- **Duplicate storage classes** (keeps only the first `rook-ceph-block` StorageClass)
- **Duplicate Ceph block pools** (keeps only the first `replicapool` CephBlockPool)
- **Duplicate rook-ceph-operator deployments** (keeps only one per cluster)
- **Duplicate snapshot-controller deployments** (keeps only one per cluster)

### When to Use

Use `make clean-csi-duplicates` when:
- Setup failed due to ImagePullBackOff errors and you need to retry
- You see multiple instances of the same resource type
- Storage operations fail due to conflicting resources
- Before running `make setup-csi-replication` again after a partial failure

### Usage Example

```bash
# If setup fails or creates duplicates
make clean-csi-duplicates

# Then retry setup
make setup-csi-replication
```

### Safe Operation

The cleanup process:
- ✅ Only removes duplicates (keeps the first instance of each resource)
- ✅ Works on both `dr1` and `dr2` clusters simultaneously
- ✅ Ignores errors if resources don't exist
- ✅ Preserves working deployments and storage

---

## Detailed Information

### Advanced Options (Optional)

For troubleshooting or advanced use cases, individual components can be managed separately:

```bash
# Manual fixes (only if needed)
make fix-csi-addons-tls         # Apply TLS configuration fixes
make setup-csi-storage-resources # Setup storage classes and VRCs  
make clean-csi-duplicates       # Remove duplicate resources
make status-csi-replication     # Check cluster status
```

### Alternative: Direct drenv Usage

```bash
# Navigate to test directory and activate Python environment
cd test && source ../venv

# One-time setup (configures host system)
drenv setup envs/regional-dr.yaml

# Start the environment
drenv start envs/regional-dr.yaml

# One-time setup (configures host system)
drenv setup envs/rook.yaml

# Start the environment
drenv start envs/rook.yaml

# When done, clean up
drenv delete envs/rook.yaml
```

## Focus on CSI Replication

This environment is perfect for CSI replication testing because:

### What You Get
- **2 Clusters**: `dr1` and `dr2` focused purely on storage and CSI
- **Ceph Storage**: Full Rook deployment with RBD pools and mirroring
- **CSI Components**: External snapshotter, CSI addons, replication controllers
- **RBD Mirroring**: Automatic bidirectional mirroring between clusters
- **No Overhead**: No management clusters or orchestration components

### What's Not Included (Which is Good!)
- **No OCM/Hub**: No complex cluster management overhead
- **No Submariner**: Direct cluster-to-cluster communication
- **No RamenDR Operators**: Focus purely on underlying CSI capabilities
- **No ArgoCD/Velero**: Simplified environment for CSI testing

## Prerequisites

### System Requirements

- **Operating System**: Linux (with virtualization support)
- **Memory**: At least 16GB RAM (8GB per cluster)
- **CPU**: At least 8 CPU cores (4 cores per cluster)
- **Disk**: 100GB+ free disk space
- **Network**: Internet connectivity for downloading container images

### Required Tools

The drenv setup will verify and guide you through installing required tools. For manual installation:

- **Python 3** with drenv virtual environment
- **minikube** (v1.37.0+)
- **kubectl** (v1.34.1+) 
- **libvirt** (for KVM virtualization)

See the [main test README](../../test/README.md#setup-on-linux) for detailed installation instructions.

### Virtualization Setup

Ensure libvirt is properly configured:

```bash
# Install libvirt (Fedora/RHEL/CentOS)
sudo dnf install @virtualization

# Add user to libvirt group
sudo usermod -a -G libvirt $(whoami)

# Logout and login again
```

## Environment Configuration

The environment is defined in [`test/envs/csi-replication.yaml`](../../test/envs/csi-replication.yaml):

### Default Configuration

- **Cluster Names**: `dr1`, `dr2`
- **Driver**: VM-based clusters (configurable via `$vm` variable)
- **Memory per Cluster**: 8GB
- **CPU per Cluster**: 4 cores
- **Storage**: 30GB disk + 2 extra disks per cluster for Ceph
- **Container Runtime**: containerd

### Customization

You can customize the setup by modifying the environment file or using environment variables:

```bash
# Use different driver (if supported)
export vm=docker  # or other supported driver

# Use different network
export network=default

# Then run the setup
make setup-csi-replication
```

## What Gets Installed

### Automatic Configuration Fixes

The setup process automatically applies these fixes for optimal operation:

1. **CSI Addons TLS Configuration**
   - **Problem**: CSI Addons controller expects TLS by default, but Ceph CSI sidecars provide plain gRPC
   - **Fix**: Automatically disables TLS authentication with `--enable-auth=false`
   - **Result**: Eliminates "TLS handshake failed" errors and enables CSI replication functionality

2. **Storage Classes and RBD Pools** 
   - **Problem**: Default rook environment doesn't create RBD storage classes and pools
   - **Fix**: Automatically runs `rook-pool` addon to create required storage classes and pools
   - **Result**: Ready-to-use `rook-ceph-block` and `rook-ceph-block-2` storage classes with RBD pools

3. **Volume Replication Classes**
   - **Problem**: VolumeReplicationClasses not created by default
   - **Fix**: Automatically applies VRC resources with 2m and 5m scheduling intervals  
   - **Result**: Functional CSI replication with `rbd-volumereplicationclass` and `rbd-volumereplicationclass-5m`

### Per-Cluster Components

Each cluster (dr1, dr2) includes:

1. **Kubernetes Cluster** 
   - 4 CPU cores, 8GB RAM
   - 2 extra disks for Ceph OSDs
   - containerd runtime with device ownership support

2. **Ceph Storage** (via Rook addons)
   - `rook-operator`: Ceph operator for management
   - `rook-cluster`: Ceph cluster with monitors, managers, OSDs
   - `rook-toolbox`: Debugging and administration tools
   - `rook-pool`: RBD pools for block storage

3. **CSI Components**
   - `external-snapshotter`: Kubernetes snapshot support
   - `csi-addons`: Volume replication controllers and CRDs

### Cross-Cluster Components

- **RBD Mirroring**: `rbd-mirror` addon configures bidirectional mirroring between dr1 and dr2

## Setup Process

The drenv-based setup runs through these phases:

1. **Prerequisite Check**: Verify tools and system requirements
2. **Cluster Creation**: Create minikube VMs for dr1 and dr2
3. **Addon Deployment**: Deploy addons in dependency order:
   - Rook operator and Ceph clusters
   - External snapshotter
   - CSI addons
   - RBD mirroring configuration

Total setup time: **15-25 minutes** (depending on hardware and network)

## Verification

After setup completes, verify the installation:

```bash
# Check cluster contexts
kubectl config get-contexts
# Should show dr1 and dr2 contexts

# Check nodes
kubectl --context=dr1 get nodes
kubectl --context=dr2 get nodes

# Check Ceph cluster status
kubectl --context=dr1 -n rook-ceph get cephcluster
kubectl --context=dr2 -n rook-ceph get cephcluster

# Check storage classes
kubectl --context=dr1 get storageclass
kubectl --context=dr2 get storageclass

# Check CSI addons
kubectl --context=dr1 -n csi-addons-system get pods
kubectl --context=dr2 -n csi-addons-system get pods

# Check RBD mirror status
kubectl --context=dr1 -n rook-ceph get cephrbdmirror
kubectl --context=dr2 -n rook-ceph get cephrbdmirror

# Access Ceph tools
kubectl --context=dr1 -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
```

## Testing CSI Replication

### Running Tests

```bash
# Run comprehensive CSI replication test
make test-csi-replication

# Run failover test (demote/promote workflow)
make test-csi-failover
```

The tests validate:
- ✅ **Infrastructure**: CSI Addons controllers and VolumeReplicationClasses
- ✅ **Storage**: PVC creation and binding to Ceph RBD volumes 
- ✅ **Replication**: VolumeReplication resource creation and primary state
- ✅ **Cross-cluster**: RBD mirroring status and peer connectivity
- ✅ **Secondary cluster**: Verification that replicated resources exist on DR2
- ✅ **Failover flow**: Complete demote/promote cycle between clusters

### Enhanced Test Output

The test now provides comprehensive cross-cluster verification:

```
=== CSI Replication Health Check ===

8. Verifying cross-cluster replication...

Checking DR2 cluster for replicated resources...
DR2 RBD Images:
csi-vol-def1f65a-bfd2-4759-a65f-4f1c9424de4f

DR2 Mirror Status for csi-vol-def1f65a-bfd2-4759-a65f-4f1c9424de4f:
  state:       up+stopped
  description: replaying (receiving replication data)
  peer_sites:
    state: up+replaying
    description: local image is secondary

DR2 Storage Resources Status:
Storage Classes:
rook-ceph-block          rook-ceph.rbd.csi.ceph.com   2h

Volume Replication Classes:
vrc-1m    rook-ceph.rbd.csi.ceph.com   45m
vrc-5m    rook-ceph.rbd.csi.ceph.com   45m

Cross-cluster replication summary:
✓ Primary volume on DR1: pv-12345
✓ RBD image being replicated: csi-vol-def1f65a-bfd2-4759-a65f-4f1c9424de4f
✓ DR2 RBD images count: 1
✓ DR2 mirror peers configured: 1
```

This enhanced verification confirms that:
- **RBD images are replicated** to the secondary cluster (DR2)
- **Mirror status shows active replication** between clusters
- **Storage resources exist on both clusters** (StorageClasses, VRCs)
- **Cross-cluster mirroring is functional** with peer connectivity
```

## Direct CSI Replication Testing

Now you can test CSI replication directly using the underlying infrastructure without RamenDR:

### Available Resources

The environment provides ready-to-use:
- **Storage Class**: `rook-ceph-block` for RBD volumes
- **VolumeReplicationClasses**: 
  - `vrc-1m` (1-minute sync interval)
  - `vrc-5m` (5-minute sync interval)
- **RBD Mirroring**: Automatic between dr1 ↔ dr2

### Create a Test PVC with Replication

```yaml
# test-pvc-replication.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: rook-ceph-block
---
apiVersion: replication.storage.openshift.io/v1alpha1
kind: VolumeReplication
metadata:
  name: test-pvc-replication
  namespace: default
spec:
  volumeReplicationClass: vrc-1m
  replicationState: primary
  dataSource:
    kind: PersistentVolumeClaim
    name: test-pvc
  autoResync: true
```

Apply and test:

```bash
# Create on primary cluster
kubectl --context=dr1 apply -f test-pvc-replication.yaml

# Monitor replication status
kubectl --context=dr1 get volumereplication test-pvc-replication -o yaml

# Check RBD mirroring
kubectl --context=dr1 -n rook-ceph exec -it deploy/rook-ceph-tools -- \
  rbd mirror pool status replicapool

# Verify on secondary cluster
kubectl --context=dr2 -n rook-ceph exec -it deploy/rook-ceph-tools -- \
  rbd ls replicapool
```

### Test Failover Scenario

```bash
# Change replication state to secondary on dr1
kubectl --context=dr1 patch volumereplication test-pvc-replication \
  --type='merge' -p='{"spec":{"replicationState":"secondary"}}'

# Check status
kubectl --context=dr1 get volumereplication test-pvc-replication -w

# Create corresponding VR on dr2 as primary
kubectl --context=dr2 apply -f - <<EOF
apiVersion: replication.storage.openshift.io/v1alpha1
kind: VolumeReplication
metadata:
  name: test-pvc-replication
  namespace: default
spec:
  volumeReplicationClass: vrc-1m
  replicationState: primary
  dataSource:
    kind: PersistentVolumeClaim
    name: test-pvc
  autoResync: true
EOF
```

## Testing CSI Replication

### Create a Test PVC with Replication

```yaml
# test-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: rook-ceph-block
---
apiVersion: replication.storage.openshift.io/v1alpha1
kind: VolumeReplication
metadata:
  name: test-pvc-replication
  namespace: default
spec:
  volumeReplicationClass: rook-ceph-block-vrc
  replicationState: primary
  dataSource:
    kind: PersistentVolumeClaim
    name: test-pvc
```

Apply and monitor:

```bash
# Create resources
kubectl --context=dr1 apply -f test-pvc.yaml

# Monitor replication
kubectl --context=dr1 get volumereplication -w
kubectl --context=dr1 describe volumereplication test-pvc-replication

# Check RBD mirroring status
kubectl --context=dr1 -n rook-ceph exec -it deploy/rook-ceph-tools -- \
  rbd mirror pool status replicapool
```

### Test Application with Replication

Use the basic test from the main test suite:

```bash
cd test
source ../venv

# Deploy sample application
basic-test/deploy dr1

# The basic test includes PVC creation and can be extended for replication testing
```

## Troubleshooting

### Common Issues

1. **Clusters won't start**
   ```bash
   # Check system resources
   free -h
   nproc
   
   # Check minikube status  
   minikube status -p dr1
   minikube status -p dr2
   ```

2. **Ceph cluster unhealthy**
   ```bash
   # Check Ceph status
   kubectl --context=dr1 -n rook-ceph get pods
   kubectl --context=dr1 -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
   
   # Check Rook operator logs
   kubectl --context=dr1 -n rook-ceph logs -f deploy/rook-ceph-operator
   ```

3. **CSI Addons connection issues**
   ```bash
   # Check CSI Addons controller logs for TLS errors
   kubectl --context=dr1 -n csi-addons-system logs -f deploy/csi-addons-controller-manager
   
   # Apply TLS fix manually if needed (automatically applied by make setup-csi-replication)
   make fix-csi-addons-tls
   
   # Check CSIAddonsNode resources
   kubectl --context=dr1 get csiaddonsnode -A
   kubectl --context=dr2 get csiaddonsnode -A
   ```

4. **RBD mirroring not working**
   ```bash
   # Check RBD mirror daemon logs
   kubectl --context=dr1 -n rook-ceph logs deploy/rook-ceph-rbd-mirror-a
   kubectl --context=dr2 -n rook-ceph logs deploy/rook-ceph-rbd-mirror-a
   
   # Check mirror pool status
   kubectl --context=dr1 -n rook-ceph exec -it deploy/rook-ceph-tools -- \
     rbd mirror pool info replicapool
   ```

5. **Duplicate resources after multiple setup attempts**
   ```bash
   # Check for duplicates
   kubectl --context=dr1 get storageclass | grep rook-ceph-block
   kubectl --context=dr1 -n rook-ceph get cephblockpool | grep replicapool
   
   # Clean up duplicates
   make clean-csi-duplicates
   
   # Retry setup
   make setup-csi-replication
   ```

### Debug Commands

```bash
# Show drenv environment details
cd test && drenv dump envs/csi-replication.yaml

# Check addon execution logs
cd test && drenv logs envs/csi-replication.yaml

# Manual addon testing
cd test/addons/rook-operator && ./start dr1
cd test/addons/csi-addons && ./start dr1
```

### Clean Recovery

```bash
# Complete cleanup
make delete-csi-replication

# Or clean up manually
cd test
drenv delete envs/csi-replication.yaml

# Remove minikube profiles if needed
minikube delete -p dr1
minikube delete -p dr2
```

## Comparison with Full RamenDR

| Component | CSI Replication Env | Full RamenDR (regional-dr) |
|-----------|--------------------|-----------------------------|
| **Clusters** | 2 (dr1, dr2) | 3 (hub, dr1, dr2) |
| **Management** | Manual kubectl | RamenDR operators + ArgoCD |
| **Networking** | Direct | Submariner mesh |
| **Storage** | Ceph RBD | Ceph RBD + CephFS |
| **Backup** | None | Velero + MinIO |
| **Monitoring** | Basic | Full metrics stack |
| **Use Case** | CSI API testing | Full DR orchestration |

## Extending the Environment

### Add Additional Components

To add more components, edit `test/envs/csi-replication.yaml`:

```yaml
# Add to cluster template workers
- addons:
    - name: volsync  # Add VolSync for async replication
    - name: minio    # Add object storage
    - name: velero   # Add backup capabilities
```

### Create Custom Addons

Follow the pattern in `test/addons/` to create custom addons for your testing needs.

### Integration Testing

This environment provides the foundation for integration testing:

```bash
# Use with RamenDR e2e tests
cd e2e
# Configure config.yaml to point to dr1/dr2 clusters
./run.sh
```

## Contributing

When modifying the CSI replication environment:

1. Test with both VM and container drivers (if available)
2. Verify all Ceph components start correctly
3. Test RBD mirroring functionality
4. Update documentation for any new features
5. Follow the existing drenv patterns and conventions

## Support

For issues and questions:

- Check the [drenv documentation](../../test/README.md)
- Review the [RamenDR testing guide](local-environment-setup.md)  
- Examine existing environment files in `test/envs/`
- Open issues in the RamenDR repository