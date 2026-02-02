# Quick Reference: CSI Replication Fixes

## One-Command Setup

```bash
# Complete CSI replication environment with all fixes applied automatically
make setup-csi-replication
```

That's it! The make target now includes all fixes automatically.

## What Gets Fixed

| Issue | Fix | Components | Critical? |
|-------|-----|------------|-----------|
| **Missing replication secrets** | Add `replication-secret-name` and `replication-secret-namespace` parameters | VolumeReplicationClass | ⚠️ **CRITICAL** |
| **CSI Addons versions** | Use official images: `controller:latest`, `sidecar:v0.11.0` | CSI Addons controller/sidecars | ⚠️ **CRITICAL** |
| Flag format | `-nodeid` (single dash) for cephcsi | csi-rbdplugin, csi-cephfsplugin | Required |
| Socket paths | Hardcoded `/csi/csi-provisioner.sock` | csi-resizer containers | Required |
| Container images | `quay.io/cephcsi/cephcsi:v3.15.0` | Provisioner deployments | Required |
| Log-collector | `while true; do sleep 3600; done` | Daemonsets | Required |
| CSI Addons flags | `--node-id` (double dash) | csi-addons containers | Required |
| TLS auth | Disabled for Ceph compatibility | CSI Addons controllers | Required |

## Individual Fix Commands

If you need to apply fixes separately:

```bash
# Fix CSI provisioner image and flag issues
make fix-csi-provisioners

# Fix CSI Addons images and connectivity
make fix-csi-addons-versions

# Fix CSI Addons TLS and NODE_ID configuration
make fix-csi-addons-tls

# Fix everything
make fix-csi-provisioners && make fix-csi-addons-versions && make fix-csi-addons-tls
```

## Critical Fix: VolumeReplicationClass Replication Secrets

**MUST HAVE** for CSI replication to work. The VolumeReplicationClass requires these parameters:

```yaml
apiVersion: replication.storage.openshift.io/v1alpha1
kind: VolumeReplicationClass
metadata:
  name: rbd-volumereplicationclass
spec:
  provisioner: rook-ceph.rbd.csi.ceph.com
  parameters:
    # CRITICAL: These parameters are REQUIRED for authentication
    replication.storage.openshift.io/replication-secret-name: rook-csi-rbd-provisioner
    replication.storage.openshift.io/replication-secret-namespace: rook-ceph
    mirroringMode: snapshot
    schedulingInterval: "2m"
```

**Without these parameters:**
- CSI Addons sidecar logs: `Failed to get secret in namespace : resource name may not be empty`
- VolumeReplication fails with: `rpc error: code = Internal desc = resource name may not be empty`
- Replication never progresses to Primary/Secondary state

**Fix:** The `test/yaml/objects/volume-replication-class.yaml` file now includes these parameters by default.

## Critical Fix: CSI Addons Image Versions

**MUST USE** official quay.io/csiaddons images with compatible versions:

```bash
# Controller: latest (gRPC compatible)
quay.io/csiaddons/k8s-controller:latest

# Sidecar: v0.11.0 (matches controller protocol)
quay.io/csiaddons/k8s-sidecar:v0.11.0
```

**Why this matters:**
- Private/custom images (e.g., `quay.io/nladha/csiaddons-sidecar:cg`) have gRPC protocol incompatibilities
- Version mismatches cause `error reading server preface: EOF`
- Controller can't connect to sidecars → VolumeReplication never gets status
- Old CSIAddonsNode objects cache wrong pod addresses → require cleanup

**Fix:** Run `make fix-csi-addons-versions` to update all images and clean up connections.

## Verification

```bash
# Check all CSI pods are running
kubectl --context=dr1 get pods -n rook-ceph | grep csi
kubectl --context=dr2 get pods -n rook-ceph | grep csi

# Expected: All pods should show "Running" state
# ✅ csi-rbdplugin-*              4/4 Running
# ✅ csi-cephfsplugin-*           3/3 Running
# ✅ csi-rbdplugin-provisioner-*  8/8 Running
# ✅ csi-cephfsplugin-provisioner-* 7/7 Running

# Verify CSIAddonsNode connections established
kubectl --context=dr1 get csiaddonsnode -A
kubectl --context=dr2 get csiaddonsnode -A
# Expected: Should show nodes for rbd and cephfs provisioners

# Check VolumeReplicationClass has secrets configured
kubectl --context=dr1 get volumereplicationclass rbd-volumereplicationclass -o jsonpath='{.spec.parameters}' | jq .
# Expected output should include:
# {
#   "mirroringMode": "snapshot",
#   "replication.storage.openshift.io/replication-secret-name": "rook-csi-rbd-provisioner",
#   "replication.storage.openshift.io/replication-secret-namespace": "rook-ceph",
#   "schedulingInterval": "2m"
# }

# Test VolumeReplication works
kubectl --context=dr1 apply -f test/yaml/objects/test-volume-replication.yaml
kubectl --context=dr1 get volumereplication test-volume-replication -o jsonpath='{.status.state}'
# Expected: "Primary" (after volume is promoted)
```

## What Changed

### Files Modified
- ✅ **Makefile** - Added `fix-csi-provisioners`, `fix-csi-addons-versions` targets, updated `setup-csi-replication` to call them
- ✅ **test/yaml/objects/volume-replication-class.yaml** - Added replication secret parameters (CRITICAL FIX)
- ✅ **hack/fix-csi-addons-versions.sh** - New script to align CSI Addons controller/sidecar versions
- ✅ **test/yaml/patches/csi-provisioner-fixes.yaml** - Reference patch file documenting all fixes
- ✅ **docs/testing/CSI_FIXES_QUICK_REFERENCE.md** - This comprehensive documentation

### Files NOT Modified
- ❌ **settings.yaml** - No changes needed
- ❌ **Shell scripts** - Only new scripts added, existing ones unchanged
- ❌ **Python files** - No changes needed  
- ❌ **Configuration YAML** - Only Kubernetes deployments patched at runtime

## Troubleshooting

### Problem: VolumeReplication stuck without status

**Symptoms:**
- VolumeReplication resource created but `status` field is empty
- No `desiredState` or `currentState` populated
- Controller reconciling but no progress

**Root Cause:** Missing replication secret parameters in VolumeReplicationClass

**Fix:**
```bash
# Check if VRC has replication secrets
kubectl --context=dr1 get volumereplicationclass rbd-volumereplicationclass -o yaml | grep replication-secret

# If missing, update VRC (requires deletion - parameters are immutable)
kubectl --context=dr1 delete volumereplicationclass --all
kubectl --context=dr2 delete volumereplicationclass --all
kubectl --context=dr1 apply -f test/yaml/objects/volume-replication-class.yaml
kubectl --context=dr2 apply -f test/yaml/objects/volume-replication-class.yaml

# Recreate VolumeReplication resources
kubectl --context=dr1 delete volumereplication --all
kubectl --context=dr1 apply -f test/yaml/objects/test-volume-replication.yaml
```

### Problem: CSI Addons connection errors

**Symptoms:**
- Controller logs: `error reading server preface: EOF`
- No CSIAddonsNode resources created
- VolumeReplication never gets status

**Root Cause:** Version mismatch or wrong images between controller and sidecars

**Fix:**
```bash
# Run version alignment script
make fix-csi-addons-versions

# Or manually for specific cluster
bash hack/fix-csi-addons-versions.sh dr1
bash hack/fix-csi-addons-versions.sh dr2
```

### Problem: CSI Addons sidecar authentication errors

**Symptoms:**
- Sidecar logs: `Failed to get secret in namespace : resource name may not be empty`
- VolumeReplication error: `rpc error: code = Internal desc = resource name may not be empty`

**Root Cause:** VolumeReplicationClass missing secret parameters

**Fix:** Apply the VolumeReplicationClass fix above (same as VolumeReplication stuck issue)

### Problem: Replication taking longer than expected

**Explanation:**
- Snapshot-based mirroring uses `schedulingInterval` parameter
- Default: `schedulingInterval: "2m"` = replicate every 2 minutes
- NOT continuous synchronous replication

**Options:**
```yaml
# Faster testing (30 seconds)
schedulingInterval: "30s"

# Standard (2 minutes) - default
schedulingInterval: "2m"

# Less frequent (5 minutes)
schedulingInterval: "5m"
```

**Note:** Shorter intervals increase resource usage and network traffic.

## Why These Fixes Are Needed

### 1. Replication Secret Parameters (CRITICAL)
The CSI Addons sidecar needs to authenticate with Ceph to enable/disable replication:
- Without secret parameters: sidecar can't read Ceph credentials
- Result: `resource name may not be empty` error
- Impact: VolumeReplication never progresses beyond creation

### 2. CSI Addons Version Alignment (CRITICAL)
Controller and sidecars communicate via gRPC protocol:
- Version mismatches cause protocol incompatibilities
- Private/custom builds may use different gRPC versions
- Result: `error reading server preface: EOF`
- Impact: Controller can't discover volumes, VolumeReplication has no status

### 3. Ceph CSI Flag Format
Ceph CSI plugins have specific requirements:
1. They use non-standard flag format (single dash for compound flags)
2. They communicate via specific socket paths
3. Different sidecars expect different flag formats (csi-addons uses double dash)
4. Environment variables aren't expanded in Kubernetes args (only in env)
5. Container images need to be specific compatible versions

## Next Steps

After setup is complete:

```bash
# Test CSI replication functionality
make test-csi-replication

# Test failover workflow
make test-csi-failover

# Create a volume with replication
kubectl --context=dr1 apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: replicated-volume
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: rook-ceph-block
  resources:
    requests:
      storage: 1Gi
EOF
```

## Documentation

For comprehensive details, see:
- [CSI Provisioner Fixes Documentation](./CSI_PROVISIONER_FIXES.md)
- [SetupCSICluster.md](./SetupCSICluster.md) - Full setup guide
- [test/yaml/patches/csi-provisioner-fixes.yaml](../test/yaml/patches/csi-provisioner-fixes.yaml) - Patch reference

## Key Insights

**Single Dash vs Double Dash:**
- Ceph CSI binary: `-nodeid` (single dash, no equals needed)
- CSI Addons project: `--node-id` (double dash, with equals)
- Standard K8s sidecars: `--flag=value` (double dash with equals)

**Socket Paths:**
- Node server: `/csi/csi.sock`
- Controller/Provisioner: `/csi/csi-provisioner.sock`
- CSI Addons: `/csi/csi-addons.sock`

**Pod Lifecycle:**
- Daemonsets: One pod per node + log-collector needs sleep loop
- Deployments: Multiple pod replicas for high availability
- Sidecars: Helper containers providing additional features

---

**Status:** ✅ All fixes automated in make targets
