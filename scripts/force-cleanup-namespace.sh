#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Force cleanup stuck namespaces by directly manipulating the finalizers

set -e

NAMESPACE=${1:-rook-cephfs-test}
CONTEXT=${2:-dr1}

echo "Force cleaning namespace $NAMESPACE in context $CONTEXT..."

# Get the namespace and remove finalizers
kubectl --context=$CONTEXT get namespace $NAMESPACE -o json | \
  jq '.spec.finalizers = []' | \
  kubectl --context=$CONTEXT replace --raw "/api/v1/namespaces/$NAMESPACE" -f -

echo "✓ Finalizers removed from namespace $NAMESPACE"
echo "Waiting for namespace to be deleted..."

# Wait for deletion
for i in {1..30}; do
  if ! kubectl --context=$CONTEXT get namespace $NAMESPACE 2>/dev/null; then
    echo "✓ Namespace $NAMESPACE successfully deleted"
    exit 0
  fi
  echo "  Waiting... ($i/30)"
  sleep 2
done

echo "⚠️  Namespace may still be present after 60 seconds"