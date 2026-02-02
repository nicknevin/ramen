# CSI Provisioner Fixes for Ceph CSI Compatibility

## Summary

This document explains the CSI provisioner fixes that were discovered and automated in the RamenDR testing environment. These fixes ensure seamless integration between Ceph CSI plugins and Rook operator deployments.

## Critical Issues Fixed

### 1. **Container Flag Format Mismatch** ⚠️
**Problem:** Ceph CSI binary requires **single-dash flags** (`-nodeid`), not double-dash flags (`--node-id`)

**Affected Components:**
- `csi-rbdplugin-provisioner` (RBD plugin controller)
- `csi-cephfsplugin-provisioner` (CephFS plugin controller)
- `csi-rbdplugin` daemonset (RBD plugin node server)
- `csi-cephfsplugin` daemonset (CephFS plugin node server)

**Fix Applied:**
```bash
# Change from: --node-id=$(NODE_ID)
# Change to:   -nodeid=$(NODE_ID)
```

**Why This Matters:** The cephcsi binary uses a different argument parser than standard GNU getopt, requiring single-dash flags with optional equals signs.

---

### 2. **Log-Collector Container Crashes** 💥
**Problem:** Log-collector containers were exiting immediately because they had invalid command-line arguments

**Affected Components:**
- `csi-rbdplugin` daemonset
- `csi-cephfsplugin` daemonset

**Original Configuration:**
```yaml
args:
  - "-nodeid"  # Invalid - log-collector doesn't use flags
  - "-type"
```

**Fix Applied:**
```yaml
command: ["sh", "-c"]
args:
  - |
    while true; do
      sleep 3600
    done
```

**Why This Matters:** Containers need a long-running process to stay alive. A simple sleep loop is ideal for sidecar containers that aren't expected to do anything until explicitly invoked.

---

### 3. **Wrong Container Images** 🖼️
**Problem:** CSI provisioner deployments were using wrong container images

**Affected Containers:**
- `csi-provisioner` in rbdplugin-provisioner deployment
- `csi-rbdplugin` in rbdplugin-provisioner deployment
- `csi-provisioner` in cephfsplugin-provisioner deployment
- `csi-cephfsplugin` in cephfsplugin-provisioner deployment

**Original Image:** (incorrect variant)
**Fixed Image:** `quay.io/cephcsi/cephcsi:v3.15.0`

**Why This Matters:** Using the correct official Ceph CSI image ensures compatibility with all required features and flags.

---

### 4. **CSI Socket Path Configuration** 🔌
**Problem:** Container arguments used environment variable expansion (`$(ADDRESS)`), but Kubernetes doesn't expand variables in args

**Affected Containers:**
- `csi-resizer` in both provisioner deployments
- Potentially other containers expecting variable expansion

**Original Configuration:**
```yaml
args:
  - "--csi-address=$(ADDRESS)"  # Won't expand!
```

**Fix Applied:**
```yaml
args:
  - "--csi-address=/csi/csi-provisioner.sock"  # Hardcoded actual path
```

**Why This Matters:** Kubernetes only supports variable expansion for `env` fields, not `args`. Container arguments must use literal values.

---

### 5. **Unnecessary Flags in Sidecars** 🚫
**Problem:** Standard CSI sidecar containers don't support certain flags that were being passed

**Affected Containers:**
- `csi-snapshotter` (doesn't support `-nodeid`)
- `csi-resizer` (doesn't support `-nodeid`)

**Fix Applied:** Removed unsupported flags from sidecar argument lists

**Why This Matters:** Passing unsupported flags causes "flag provided but not defined" errors and pod failures.

---

### 6. **CSI Addons Flag Format** 🔄
**Problem:** CSI addons sidecar expects **double-dash flags** (`--node-id`), while cephcsi expects single-dash

**Affected Containers:**
- `csi-addons` in both provisioner deployments

**Correct Format for CSI Addons:**
```yaml
args:
  - "--node-id=$(NODE_ID)"  # Double dash for csi-addons
```

**Why This Matters:** Different projects use different flag conventions. CSI addons (from the csi-addons project) uses GNU getopt with double dashes.

---

## Automation

### Make Targets

#### `make fix-csi-provisioners`
Applies all container image and flag format fixes to CSI provisioner deployments:
- Fixes `csi-rbdplugin-provisioner` deployment
- Fixes `csi-cephfsplugin-provisioner` deployment
- Fixes `csi-rbdplugin` and `csi-cephfsplugin` daemonsets
- Corrects socket paths for csi-resizer containers

#### `make fix-csi-addons-tls`
Applies configuration fixes to CSI Addons controllers:
- Disables TLS authentication (required for Ceph CSI sidecar compatibility)
- Sets NODE_ID environment variables
- Restarts provisioner pods to establish fresh connections

#### `make setup-csi-replication`
Main setup target that now includes CSI provisioner fixes automatically

### Kubernetes Patch Format

All fixes use strategic merge patch operations:

```bash
kubectl patch deployment csi-rbdplugin-provisioner \
  --type='json' \
  -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "quay.io/cephcsi/cephcsi:v3.15.0"}]'
```

---

## Testing the Fixes

### Verify CSI Pods Are Running

```bash
# Check all CSI pods on dr1
kubectl --context=dr1 get pods -n rook-ceph | grep csi

# Expected output:
# ✅ csi-rbdplugin-jzmcr                       4/4   Running
# ✅ csi-cephfsplugin-llhrr                    3/3   Running
# ✅ csi-rbdplugin-provisioner-679c97d4d8-g5m7d   8/8   Running
# ✅ csi-cephfsplugin-provisioner-774f54db7b-tcl92   7/7   Running
```

### Check Container Logs

```bash
# Verify log-collector is running
kubectl --context=dr1 logs -n rook-ceph csi-rbdplugin-jzmcr -c log-collector

# Should show infinite sleep loop (no errors)
```

### Verify Socket Connectivity

```bash
# Check if containers can access the CSI socket
kubectl --context=dr1 exec -it -n rook-ceph <pod-name> -c csi-resizer -- \
  ls -la /csi/csi-provisioner.sock
```

---

## Related Files

- **Patch Reference:** [test/yaml/patches/csi-provisioner-fixes.yaml](../test/yaml/patches/csi-provisioner-fixes.yaml)
- **Make Targets:** [Makefile](../../Makefile) - search for `fix-csi-provisioners`
- **Setup Configuration:** [test/envs/rook.yaml](../test/envs/rook.yaml)

---

## Troubleshooting

### Pod Still Crashing?

1. Check the specific error in pod events:
   ```bash
   kubectl --context=dr1 describe pod <pod-name> -n rook-ceph
   ```

2. Review container logs:
   ```bash
   kubectl --context=dr1 logs <pod-name> -n rook-ceph -c <container-name>
   ```

3. Common errors and fixes:
   - **"flag provided but not defined"** → Check flag format (single vs double dash)
   - **"connection refused"** → Check socket path in arguments
   - **Container exits immediately** → Check command/args configuration

### Manual Fix Application

If automatic fixes aren't applied, manually run:
```bash
make fix-csi-provisioners
make fix-csi-addons-tls
```

---

## Technical Details

### CSI Component Architecture

- **Daemonsets:** Run on every node for local storage operations (node servers)
- **Deployments:** Run on control plane for centralized operations (controllers)
- **Sidecars:** Helper containers that provide additional functionality

### Environment Variables in Kubernetes

- **Supported in `env`:** `$(POD_NAME)`, `$(POD_NAMESPACE)`, etc.
- **NOT supported in `args`:** Must use hardcoded literal values

### Socket Communication

All CSI components communicate via Unix sockets:
- **RBD Plugin Socket:** `/csi/csi.sock` (node server) or `/csi/csi-provisioner.sock` (controller)
- **CephFS Plugin Socket:** `/csi/csi.sock` (node server) or `/csi/csi-provisioner.sock` (controller)
- **CSI Addons Socket:** `/csi/csi-addons.sock` (separate for replication operations)

---

## References

- [Ceph CSI GitHub Repository](https://github.com/ceph/ceph-csi)
- [CSI Addons Project](https://github.com/csi-addons/kubernetes-csi-addons)
- [Rook Ceph Documentation](https://rook.io/docs/rook/v1.18/Storage-Configuration/Ceph-CSI/ceph-csi/)
- [Kubernetes CSI Spec](https://kubernetes-csi.github.io/docs/)

---

**Last Updated:** 2025-01-10
**Status:** ✅ All fixes integrated into make targets and automated setup
