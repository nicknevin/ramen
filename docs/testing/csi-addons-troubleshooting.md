# CSI Addons Troubleshooting Guide

## Overview

This document describes the troubleshooting process and resolution for CSI Addons connectivity issues encountered in the RamenDR testing environment with Rook-Ceph storage.

## Issue Description

The CSI Addons controller was failing to establish connections with CSI plugin sidecar containers, resulting in repeated TLS handshake failures and automatic deletion of CSIAddonsNode resources.

### Symptoms

- **Primary Error**: `transport: authentication handshake failed: tls: first record does not look like a TLS handshake`
- **Behavior**: CSI Addons controller repeatedly attempts connections, fails after 3 attempts, and deletes CSIAddonsNode resources
- **Impact**: CSI Addons functionality (volume replication, reclaim space, encryption key rotation) unavailable

### Error Logs Example

```
2026-02-01T14:02:06.361Z    ERROR    Failed to establish connection with sidecar    {"controller": "csiaddonsnode", "controllerGroup": "csiaddons.openshift.io", "controllerKind": "CSIAddonsNode", "CSIAddonsNode": {"name":"csi-cephfsplugin-provisioner-66c4d88f9c-2mct2","namespace":"rook-ceph"}, "namespace": "rook-ceph", "name": "csi-cephfsplugin-provisioner-66c4d88f9c-2mct2", "reconcileID": "8dcf556d-5357-4f68-9c75-82785bcdeda1", "NodeID": "dr1", "DriverName": "rook-ceph.cephfs.csi.ceph.com", "EndPoint": "10.244.0.53:9070", "attempt": 3, "error": "rpc error: code = Unavailable desc = connection error: desc = \"transport: authentication handshake failed: tls: first record does not look like a TLS handshake\""}
```

## Root Cause Analysis

### Investigation Steps

1. **Checked CSI Addons Controller Logs**
   ```bash
   kubectl --context=dr1 logs -n csi-addons-system csi-addons-controller-manager-<pod-id>
   ```

2. **Examined CSI Sidecar Configuration**
   ```bash
   kubectl --context=dr1 describe pod -n rook-ceph <csi-plugin-pod>
   kubectl --context=dr1 logs -n rook-ceph <csi-plugin-pod> -c csi-addons
   ```

3. **Analyzed Controller Configuration**
   ```bash
   kubectl --context=dr1 get deployment -n csi-addons-system csi-addons-controller-manager -o yaml
   ```

### Root Cause

The CSI Addons controller has TLS authentication **enabled by default** via the `--enable-auth` flag, while the CSI sidecar containers are configured to provide **plain gRPC connections without TLS**. This mismatch caused the handshake failures.

**Key Finding**: The `--enable-auth` flag in the CSI Addons controller:
- **Default value**: `true` (TLS enabled)  
- **Effect**: "Enables TLS and adds bearer token to the headers"
- **CSI Sidecar expectation**: Plain gRPC connection on port 9070

## Resolution

### Automatic Fix (Recommended)

**Since February 2026**, the CSI replication environment setup automatically applies this fix:

```bash
# The TLS fix is automatically applied during setup
make setup-csi-replication

# Or apply manually to existing environment
make fix-csi-addons-tls
```

### Manual Fix

For manual application or troubleshooting, disable TLS authentication in the CSI Addons controller:

```bash
kubectl --context=dr1 patch deployment -n csi-addons-system csi-addons-controller-manager \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args", "value": ["--enable-auth=false"]}]'
  
kubectl --context=dr2 patch deployment -n csi-addons-system csi-addons-controller-manager \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args", "value": ["--enable-auth=false"]}]'
```

### Verification Steps

1. **Wait for deployment rollout**:
   ```bash
   kubectl --context=dr1 rollout status deployment/csi-addons-controller-manager -n csi-addons-system
   ```

2. **Restart CSI plugin pods** to trigger CSIAddonsNode creation:
   ```bash
   kubectl --context=dr1 delete pod -n rook-ceph <csi-plugin-pod-name>
   ```

3. **Verify successful connections**:
   ```bash
   kubectl --context=dr1 get csiaddonsnode -A
   kubectl --context=dr1 logs -n csi-addons-system <controller-pod> | grep "Successfully connected"
   ```

## Current Status

### Working Components

✅ **CSI RBD Plugin**: Successfully connected and operational
- CSIAddonsNode resource: `csi-rbdplugin-hrr7k`
- Driver: `rook-ceph.rbd.csi.ceph.com`
- Endpoint: `pod://csi-rbdplugin-hrr7k.rook-ceph:9070`

### Partially Working Components

⚠️ **CephFS Provisioner**: Intermittent connectivity issues
- Issue: Pod IP resolution timing during startup
- Workaround: Restart pod after full initialization
- Status: Requires additional pod restart cycles for consistent operation

### Successful Connection Log

```
2026-02-01T14:11:56.017Z    INFO    Successfully connected to sidecar    {"controller": "csiaddonsnode", "controllerGroup": "csiaddons.openshift.io", "controllerKind": "CSIAddonsNode", "CSIAddonsNode": {"name":"csi-rbdplugin-hrr7k","namespace":"rook-ceph"}, "namespace": "rook-ceph", "name": "csi-rbdplugin-hrr7k", "reconcileID": "815f4c2f-901b-4512-82e5-0b7c11594d97", "NodeID": "dr1", "DriverName": "rook-ceph.rbd.csi.ceph.com", "EndPoint": "192.168.122.166:9070"}
```

## Additional Configuration Details

### CSI Addons Controller Arguments

After the fix, the controller runs with:
```yaml
containers:
- args:
  - --enable-auth=false
  image: quay.io/csiaddons/k8s-controller:latest
  name: manager
```

### CSI Sidecar Configuration

The sidecar containers are configured with:
```yaml
containers:
- name: csi-addons
  image: quay.io/csiaddons/k8s-sidecar:v0.9.1
  ports:
  - containerPort: 9070
    hostPort: 9070
    protocol: TCP
  args:
  - --node-id=$(NODE_ID)
  - --v=0
  - --csi-addons-address=$(CSIADDONS_ENDPOINT)
  - --controller-port=9070
  - --pod=$(POD_NAME)
  - --namespace=$(POD_NAMESPACE)
  - --pod-uid=$(POD_UID)
```

## Known Issues and Workarounds

### Issue: CephFS Provisioner Connection Timing

**Problem**: CephFS provisioner CSIAddonsNode may fail to be created due to IP address resolution timing during pod startup.

**Error**: `pod rook-ceph/csi-cephfsplugin-provisioner-<id> does not have an IP-address`

**Workarounds**:
1. Wait for complete pod initialization before expecting CSIAddonsNode creation
2. Restart the CephFS provisioner pod if CSIAddonsNode is not created within 2-3 minutes
3. Monitor controller logs for successful connection messages

### Issue: Leader Election Delays

**Problem**: CephFS provisioner sidecar may take time to acquire leadership, delaying CSIAddonsNode creation.

**Normal behavior**: 
```
I0201 14:15:26.894710       1 leaderelection.go:268] successfully acquired lease rook-ceph/rook-ceph-cephfs-csi-ceph-com-csi-addons
I0201 14:15:26.895091       1 main.go:141] Obtained leader status: lease name "rook-ceph-cephfs-csi-ceph-com-csi-addons", receiving CONTROLLER_SERVICE requests
```

## Future Improvements

1. **Configuration Management**: Consider using ConfigMaps or environment variables for TLS configuration
2. **Health Checks**: Implement better health checks for CSI sidecar readiness
3. **Retry Logic**: Improve retry logic for pod IP resolution during startup
4. **Documentation**: Update deployment manifests to include TLS configuration options

## Related Resources

- **CSI Addons Documentation**: [kubernetes-csi-addons](https://github.com/csi-addons/kubernetes-csi-addons)
- **RamenDR Testing**: [local-environment-setup.md](./local-environment-setup.md)
- **Replication Parameters**: [replication-parameters.md](./replication-parameters.md)

## Command Reference

### Diagnostic Commands

```bash
# Check CSI Addons controller status
kubectl --context=dr1 get pods -n csi-addons-system

# View CSI Addons nodes
kubectl --context=dr1 get csiaddonsnode -A

# Check controller logs
kubectl --context=dr1 logs -n csi-addons-system <controller-pod-name>

# Check sidecar logs
kubectl --context=dr1 logs -n rook-ceph <csi-plugin-pod> -c csi-addons

# View controller configuration
kubectl --context=dr1 get deployment -n csi-addons-system csi-addons-controller-manager -o yaml
```

### Recovery Commands

```bash
# Restart CSI Addons controller
kubectl --context=dr1 rollout restart deployment/csi-addons-controller-manager -n csi-addons-system

# Restart specific CSI plugin
kubectl --context=dr1 delete pod -n rook-ceph <csi-plugin-pod-name>

# Apply TLS fix if needed
kubectl --context=dr1 patch deployment -n csi-addons-system csi-addons-controller-manager \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args", "value": ["--enable-auth=false"]}]'
```