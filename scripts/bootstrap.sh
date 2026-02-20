#!/usr/bin/env bash
set -euo pipefail

echo "==> Installing Mac prerequisites via Homebrew..."
brew install ansible sops age helm kubectl cloudflared

AGE_KEY_DIR="${HOME}/Library/Application Support/sops/age"
AGE_KEY_FILE="${AGE_KEY_DIR}/keys.txt"

if [[ -f "${AGE_KEY_FILE}" ]]; then
    echo "==> Age key already exists at ${AGE_KEY_FILE}"
else
    echo "==> Generating age keypair..."
    mkdir -p "${AGE_KEY_DIR}"
    age-keygen -o "${AGE_KEY_FILE}" 2>&1
    echo "==> Age key saved to ${AGE_KEY_FILE}"
fi

PUBLIC_KEY=$(grep -o 'age1[a-z0-9]*' "${AGE_KEY_FILE}" | head -1)
echo ""
echo "==> Your age public key: ${PUBLIC_KEY}"
echo ""
echo "IMPORTANT: Update .sops.yaml with this public key:"
echo "  Replace AGE_PUBLIC_KEY_PLACEHOLDER with: ${PUBLIC_KEY}"
echo ""
echo "Then create the encrypted Ansible secrets file:"
echo "  sops ansible/group_vars/all.sops.yml"
echo ""
echo "Bootstrap complete!"
