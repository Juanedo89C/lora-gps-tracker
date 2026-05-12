#!/usr/bin/env bash
# Quick health and status dashboard for the Proxmox node.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../Resources/proxmox.env"

run() {
    "$PLINK" -pw "$PROXMOX_PASS" -hostkey "$PROXMOX_HOSTKEY" -batch -P "$PROXMOX_PORT" \
        "${PROXMOX_USER}@${PROXMOX_HOST}" "$1" 2>/dev/null
}

sep() { echo "--------------------------------------"; }

echo "======================================"
echo "  Proxmox Status: $PROXMOX_HOST"
echo "  $(date)"
echo "======================================"

echo ""
echo "[ NODE ]"
run "echo \"Hostname : \$(hostname)\" && echo \"Uptime   : \$(uptime -p)\" && pveversion 2>/dev/null"

sep

echo ""
echo "[ CPU ]"
run "top -bn1 | grep 'Cpu(s)' | awk '{printf \"Usage    : %.1f%%\n\", 100-\$8}'"

sep

echo ""
echo "[ RAM ]"
run "free -h | awk '/^Mem:/{printf \"Total: %s  Used: %s  Free: %s\n\", \$2, \$3, \$4}'"

sep

echo ""
echo "[ DISK ]"
run "df -h --output=source,size,used,avail,pcent,target | grep -v tmpfs | grep -v udev | head -20"

sep

echo ""
echo "[ STORAGE POOLS ]"
run "pvesm status 2>/dev/null || echo '(none)'"

sep

echo ""
echo "[ VIRTUAL MACHINES ]"
run "qm list 2>/dev/null || echo '(none)'"

sep

echo ""
echo "[ LXC CONTAINERS ]"
run "pct list 2>/dev/null || echo '(none)'"

sep

echo ""
echo "[ NETWORK ]"
run "ip -brief addr show | grep -v '^lo'"

sep

echo ""
echo "[ TAILSCALE ]"
run "tailscale status 2>/dev/null || echo 'not running'"

echo ""
echo "======================================"
