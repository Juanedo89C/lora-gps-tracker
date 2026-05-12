#!/usr/bin/env bash
# Installs and configures Tailscale on Proxmox as a subnet router.
# Run from any machine on the same LAN as Proxmox (first-time only).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../Resources/proxmox.env"
source "$ENV_FILE"

run() {
    "$PLINK" -pw "$PROXMOX_PASS" -hostkey "$PROXMOX_HOSTKEY" -batch -P "$PROXMOX_PORT" \
        "${PROXMOX_USER}@${PROXMOX_HOST}" "$1"
}

echo "==> Installing Tailscale via official install script..."
run "curl -fsSL https://tailscale.com/install.sh | sh 2>&1"

echo "==> Enabling IP forwarding..."
run "printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' \
    > /etc/sysctl.d/99-tailscale.conf && sysctl -p /etc/sysctl.d/99-tailscale.conf"

echo "==> Fixing UDP GRO on vmbr0..."
run "ethtool -K vmbr0 rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null || true"

echo ""
echo "==> Starting Tailscale (subnet router). Open the auth URL in your browser:"
echo ""
"$PLINK" -pw "$PROXMOX_PASS" -hostkey "$PROXMOX_HOSTKEY" -batch -P "$PROXMOX_PORT" \
    "${PROXMOX_USER}@${PROXMOX_HOST}" \
    "tailscale up --advertise-routes=${PROXMOX_SUBNET} --accept-routes 2>&1 || true"

TS_IP=$(run "tailscale ip -4 2>/dev/null || echo ''")
if [[ -n "$TS_IP" ]]; then
    sed -i "s|^TAILSCALE_IP=.*|TAILSCALE_IP=\"$TS_IP\"|" "$ENV_FILE"
    sed -i "s|^PROXMOX_HOST=.*|PROXMOX_HOST=\"$TS_IP\"|" "$ENV_FILE"
    echo "Updated proxmox.env: PROXMOX_HOST=$TS_IP"
fi

echo ""
echo "======================================================"
echo "  NEXT STEPS"
echo "======================================================"
echo "  1. Approve subnet route at https://login.tailscale.com/admin/machines"
echo "     -> Click '$PROXMOX_HOST' -> Edit route settings -> approve ${PROXMOX_SUBNET}"
echo "  2. On each client: install Tailscale and enable 'Accept routes'"
echo "======================================================"
