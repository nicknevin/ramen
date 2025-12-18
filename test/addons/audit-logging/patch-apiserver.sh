#!/bin/bash

# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Helper script to patch kube-apiserver manifest for audit logging.
# This script runs on the minikube node using sed.
#
# Strategy:
# 1. Move manifest to /root to stop the apiserver
# 2. Wait for apiserver to stop
# 3. Patch the manifest
# 4. Move it back to /etc/kubernetes/manifests to start apiserver

set -e

MANIFEST_DIR="/etc/kubernetes/manifests"
MANIFEST="$MANIFEST_DIR/kube-apiserver.yaml"
WORK_DIR="/root"
WORK_MANIFEST="$WORK_DIR/kube-apiserver.yaml"
BACKUP="$WORK_DIR/kube-apiserver.yaml.backup"

echo "Step 1: Moving manifest to $WORK_DIR to stop apiserver"
mv "$MANIFEST" "$WORK_MANIFEST"

echo "Step 2: Waiting for apiserver to stop..."
# Wait for the apiserver container to stop (max 60 seconds)
for i in {1..60}; do
    if ! crictl ps 2>/dev/null | grep -q kube-apiserver; then
        echo "API server stopped after $i seconds"
        break
    fi
    sleep 1
done

echo "Step 3: Creating backup and patching manifest"
# Create backup
cp "$WORK_MANIFEST" "$BACKUP"

# Add command line arguments after the "command:" line containing "kube-apiserver"
sed -i '/- kube-apiserver/a\
    - --audit-log-maxage=30\
    - --audit-log-maxbackup=10\
    - --audit-log-maxsize=100\
    - --audit-log-path=/var/log/audit/audit.log\
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml' "$WORK_MANIFEST"

# Add volumeMounts for audit-log and audit-policy
sed -i '/^    volumeMounts:/a\
    - mountPath: /var/log/audit\
      name: audit-log\
    - mountPath: /etc/kubernetes/audit-policy.yaml\
      name: audit-policy\
      readOnly: true' "$WORK_MANIFEST"

# Add volumes for audit-log and audit-policy
sed -i '/^  volumes:/a\
  - hostPath:\
      path: /var/log/audit\
      type: DirectoryOrCreate\
    name: audit-log\
  - hostPath:\
      path: /etc/kubernetes/audit-policy.yaml\
      type: File\
    name: audit-policy' "$WORK_MANIFEST"

echo "Step 4: Moving patched manifest back to $MANIFEST_DIR to start apiserver"
mv "$WORK_MANIFEST" "$MANIFEST"

echo "kube-apiserver manifest patched successfully"
echo "Backup saved at: $BACKUP"
