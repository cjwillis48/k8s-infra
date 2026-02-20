#!/usr/bin/env bash
set -euo pipefail

SERVER_IP="192.168.6.200"
SERVER_USER="charlie"
KUBECONFIG_LOCAL="$(cd "$(dirname "$0")/.." && pwd)/kubeconfig"

echo "==> Fetching kubeconfig from ${SERVER_IP}..."
scp "${SERVER_USER}@${SERVER_IP}:/etc/rancher/k3s/k3s.yaml" "${KUBECONFIG_LOCAL}"

echo "==> Updating server address to ${SERVER_IP}..."
sed -i '' "s|127\.0\.0\.1|${SERVER_IP}|g" "${KUBECONFIG_LOCAL}"

chmod 600 "${KUBECONFIG_LOCAL}"

echo "==> Kubeconfig saved to ${KUBECONFIG_LOCAL}"
echo ""
echo "To use:"
echo "  export KUBECONFIG=${KUBECONFIG_LOCAL}"
echo "  kubectl get nodes"
