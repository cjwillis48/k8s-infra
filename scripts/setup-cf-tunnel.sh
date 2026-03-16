#!/usr/bin/env bash
set -euo pipefail

TUNNEL_NAME="k8s-ghost-blog"
HOSTNAME="blog.charliewillis.com"
SERVICE_URL="http://ghost.blog.svc.cluster.local:2368"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEALED_FILE="${REPO_ROOT}/k8s/cloudflared/tunnel-token.sealed.yml"
SEAL_CERT="${REPO_ROOT}/k8s/sealed-secrets/sealed-secrets-pub.pem"

echo "==> Cloudflare Tunnel Setup"
echo ""
echo "This script helps you create a remotely-managed Cloudflare Tunnel."
echo "You must be logged into cloudflared first."
echo ""

# Check if logged in
if ! cloudflared tunnel list &>/dev/null; then
    echo "==> Logging into Cloudflare..."
    cloudflared tunnel login
fi

echo ""
echo "==> Next steps (done in the Cloudflare Zero Trust dashboard):"
echo ""
echo "1. Go to: https://one.dash.cloudflare.com → Networks → Tunnels"
echo "2. Create a tunnel named: ${TUNNEL_NAME}"
echo "3. Copy the tunnel token"
echo "4. Add a public hostname:"
echo "   - Subdomain: blog"
echo "   - Domain: charliewillis.com"
echo "   - Service type: HTTP"
echo "   - URL: ${SERVICE_URL}"
echo ""

read -rp "Paste your tunnel token here: " TUNNEL_TOKEN

if [[ -z "${TUNNEL_TOKEN}" ]]; then
    echo "Error: No token provided."
    exit 1
fi

TEMP_SECRET=$(mktemp)
trap 'rm -f "${TEMP_SECRET}"' EXIT

echo ""
echo "==> Creating temporary secret and sealing with kubeseal..."
cat > "${TEMP_SECRET}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflared-tunnel-token
  namespace: cloudflare
type: Opaque
stringData:
  token: "${TUNNEL_TOKEN}"
EOF

kubeseal --format yaml \
    --cert "${SEAL_CERT}" \
    < "${TEMP_SECRET}" > "${SEALED_FILE}"

echo "==> Sealed secret written to ${SEALED_FILE}"
echo ""
echo "==> Tunnel setup complete!"
echo "Commit the sealed secret and push — ArgoCD will deploy it."
