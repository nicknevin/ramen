<!--
SPDX-FileCopyrightText: The RamenDR authors
SPDX-License-Identifier: Apache-2.0
-->

# Audit Logging Addon

This addon enables Kubernetes API server audit logging for Minikube clusters managed by drenv.

## Overview

Kubernetes audit logging provides a chronological record of API calls made to the cluster. This is essential for:
- Security monitoring and threat detection
- Compliance and regulatory requirements
- Debugging and troubleshooting cluster operations
- Understanding cluster activity and access patterns

## How It Works

The addon automatically configures Kubernetes API server audit logging by:

1. **Installing the audit policy**: Copies `audit-policy.yaml` to `/etc/kubernetes/audit-policy.yaml` on the Minikube node
2. **Creating log directory**: Creates `/var/log/audit` on the node for storing audit logs
3. **Patching the API server manifest**: Uses a controlled restart sequence:
   - Moves `/etc/kubernetes/manifests/kube-apiserver.yaml` to `/root` (this stops the API server)
   - Waits for the API server container to stop
   - Uses `sed` to patch the manifest with audit configuration:
     - Add audit log command line arguments (log path, rotation settings)
     - Mount the audit policy file into the API server pod
     - Mount the log directory as a persistent volume
   - Creates a backup at `/root/kube-apiserver.yaml.backup`
   - Moves the patched manifest back to `/etc/kubernetes/manifests` (this starts the API server)
4. **Waiting for restart**: Polls until the API server restarts and becomes ready

The audit policy is configured to:

1. **Exclude noise**: Skips logging health checks, version requests, and watch operations by system components
2. **Capture secrets/configmaps**: Logs changes to sensitive resources at appropriate detail levels
3. **Log all changes**: Records all resource modifications at the Request or Metadata level
4. **Filter metadata**: Excludes RequestReceived stage to reduce log volume

Audit logs are written to `/var/log/audit/audit.log` on the node with automatic rotation (max 10 backups, 100MB per file, 30 day retention).

## Usage

### Basic Setup

1. Add the addon to your environment configuration file (e.g., `test/envs/my-env.yaml`):

```yaml
name: my-environment
templates:
  - name: "audit-cluster"
    driver: $vm
    container_runtime: containerd
    workers:
      - addons:
          - name: audit-logging
profiles:
  - name: cluster1
    template: audit-cluster
```

2. Create the environment:

```bash
drenv start test/envs/my-env.yaml
```

### Important Notes

- **No extra configuration needed**: The addon automatically configures the API server manifest
- The addon can be added to existing clusters - it will patch the configuration and wait for the API server to restart
- The API server will be unavailable for a brief period (typically 10-30 seconds) while it restarts
- Audit logs are automatically rotated (max 10 backups, 100MB per file, 30 day retention)

### Viewing Audit Logs

After the cluster is running with audit logging enabled, view the logs:

```bash
# View audit logs on the node
minikube ssh -p CLUSTER_NAME -- sudo tail -f /var/log/audit/audit.log

# Copy audit logs to your local machine
minikube cp CLUSTER_NAME:/var/log/audit/audit.log ./audit.log

# View specific audit log files (with rotation)
minikube ssh -p CLUSTER_NAME -- sudo ls -lh /var/log/audit/
```

Replace `CLUSTER_NAME` with your cluster's profile name.

You can also use standard tools to analyze the logs:

```bash
# Filter for specific events (e.g., secret access)
minikube ssh -p CLUSTER_NAME -- sudo grep secrets /var/log/audit/audit.log

# Count audit events by verb
minikube ssh -p CLUSTER_NAME -- sudo cat /var/log/audit/audit.log | grep -o '"verb":"[^"]*"' | sort | uniq -c

# Find failed requests
minikube ssh -p CLUSTER_NAME -- sudo grep '"responseStatus":{"code":4[0-9][0-9]' /var/log/audit/audit.log
```

## Configuration Options

The addon automatically configures the API server with the following settings:

- `--audit-policy-file=/etc/kubernetes/audit-policy.yaml` - Path to the audit policy file (mounted from `/etc/kubernetes/audit-policy.yaml` on the node)
- `--audit-log-path=/var/log/audit/audit.log` - Path to the audit log file (mounted from `/var/log/audit` on the node)
- `--audit-log-maxage=30` - Maximum number of days to retain old audit log files
- `--audit-log-maxbackup=10` - Maximum number of audit log files to retain
- `--audit-log-maxsize=100` - Maximum size in MB of the audit log file before it gets rotated

### Customizing Audit Settings

To change the audit log rotation settings, you can manually edit the settings in the addon's `patch-apiserver.sh` script before running it, or modify the manifest after the addon runs:

```bash
# SSH into the node
minikube ssh -p CLUSTER_NAME

# Edit the manifest (changes take effect automatically)
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

### Customizing the Audit Policy

The default audit policy in `audit-policy.yaml` provides a balanced approach. To customize:

1. Edit [audit-policy.yaml](audit-policy.yaml) to modify the policy rules
2. Re-run the addon or manually update the file on the node:
   ```bash
   minikube cp CLUSTER_NAME audit-policy.yaml /etc/kubernetes/audit-policy.yaml
   # The API server will automatically reload the policy
   ```

Common customizations:
- Change logging levels (None, Metadata, Request, RequestResponse)
- Add namespace-specific rules
- Exclude additional noisy endpoints
- Focus on specific resource types

See the [Kubernetes Audit Policy documentation](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/) for more details.

## Example Environment

Here's a complete example environment with audit logging enabled:

```yaml
name: audit-example
templates:
  - name: "audit-cluster"
    driver: kvm2
    container_runtime: containerd
    cpus: 2
    memory: 4g
    workers:
      - addons:
          - name: audit-logging
profiles:
  - name: cluster1
    template: audit-cluster
```

See [test/envs/audit-example.yaml](../../../test/envs/audit-example.yaml) for a working example.

## Troubleshooting

### Audit logs not appearing

1. Verify the audit policy file was installed:
   ```bash
   minikube ssh -p CLUSTER_NAME
   cat /etc/kubernetes/audit-policy.yaml
   ```

2. Check API server configuration:
   ```bash
   kubectl get pod kube-apiserver-CLUSTER_NAME -n kube-system -o yaml | grep audit
   ```

3. Verify the audit log directory exists and is writable:
   ```bash
   minikube ssh -p CLUSTER_NAME -- sudo ls -ld /var/log/audit
   ```

### API server not starting

If the API server fails to start after enabling audit logging:
- Check the audit policy YAML syntax is valid
- Review the API server manifest: `minikube ssh -p CLUSTER_NAME -- sudo cat /etc/kubernetes/manifests/kube-apiserver.yaml`
- Review Minikube logs: `minikube logs -p CLUSTER_NAME`
- Check kubelet logs: `minikube ssh -p CLUSTER_NAME -- sudo journalctl -u kubelet -f`

### Addon fails during patching

If the patch script fails:
- Check if manifest exists in /root (may be stuck mid-patch): `minikube ssh -p CLUSTER_NAME -- sudo ls -l /root/kube-apiserver.yaml`
- Verify backup was created: `minikube ssh -p CLUSTER_NAME -- sudo ls -l /root/kube-apiserver.yaml.backup`
- Review the patch script output for specific errors
- To restore from backup: `minikube ssh -p CLUSTER_NAME -- sudo cp /root/kube-apiserver.yaml.backup /etc/kubernetes/manifests/kube-apiserver.yaml`

## References

- [Kubernetes Auditing](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- [Minikube Audit Policy Tutorial](https://minikube.sigs.k8s.io/docs/tutorials/audit-policy/)
- [Audit Policy API Reference](https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/)
