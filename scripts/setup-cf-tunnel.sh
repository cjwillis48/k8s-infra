#!/usr/bin/env bash
set -euo pipefail

TUNNEL_NAME="k8s-ghost-blog"
HOSTNAME="blog.charliewillis.com"
SERVICE_URL="http://ghost.ghost.svc.cluster.local:2368"
SECRET_FILE="$(cd "$(dirname "$0")/.." && pwd)/k8s/cloudflared/secret.sops.yml"

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

echo ""
echo "==> Updating K8s secret file with tunnel token..."
cat > "${SECRET_FILE}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflared-tunnel-token
  namespace: cloudflare
type: Opaque
stringData:
  token: "${TUNNEL_TOKEN}"
EOF

echo "==> Encrypting secret with SOPS..."
sops -e -i "${SECRET_FILE}"

echo ""
echo "==> Also updating Ansible secrets..."
echo ""
echo "Run the following to add the token to Ansible vars:"
echo "  sops ansible/group_vars/all.sops.yml"
echo "  # Set cloudflare_tunnel_token to: ${TUNNEL_TOKEN}"
echo ""
echo "==> Tunnel setup complete!"
echo "Deploy with: make deploy"
