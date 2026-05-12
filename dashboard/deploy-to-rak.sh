#!/usr/bin/env bash
# Run this on your LOCAL machine to copy the dashboard to the RAK7248.
# Usage:  bash deploy-to-rak.sh <gateway-ip>
# Example: bash deploy-to-rak.sh 192.168.1.50

set -e
RAK_IP="${1:?Usage: $0 <gateway-ip>}"
RAK_USER="juaneduardocruz"
REMOTE_DIR="/opt/lora-dashboard"

echo "==> Copying dashboard to ${RAK_USER}@${RAK_IP}:${REMOTE_DIR}"
ssh "${RAK_USER}@${RAK_IP}" "mkdir -p ${REMOTE_DIR}/public"

scp server.js package.json "${RAK_USER}@${RAK_IP}:${REMOTE_DIR}/"
scp public/index.html public/app.js "${RAK_USER}@${RAK_IP}:${REMOTE_DIR}/public/"

echo "==> Installing Node.js v20 (if not already installed)"
ssh "${RAK_USER}@${RAK_IP}" "
  if ! node --version 2>/dev/null | grep -q 'v2'; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
  fi
  node --version
"

echo "==> Installing npm dependencies"
ssh "${RAK_USER}@${RAK_IP}" "cd ${REMOTE_DIR} && npm install --omit=dev"

echo "==> Installing systemd service"
scp lora-dashboard.service "${RAK_USER}@${RAK_IP}:/etc/systemd/system/"
ssh "${RAK_USER}@${RAK_IP}" "
  systemctl daemon-reload
  systemctl enable lora-dashboard
  systemctl restart lora-dashboard
  systemctl status lora-dashboard --no-pager
"

echo ""
echo "Done. Dashboard available at http://${RAK_IP}:3000"
echo "IMPORTANT: Edit /etc/systemd/system/lora-dashboard.service"
echo "           and set CHIRPSTACK_API_TOKEN to your actual token,"
echo "           then run: systemctl restart lora-dashboard"
