#!/usr/bin/env bash
# Proxmox VM and LXC container management over SSH.
# Usage: ./proxmox-manage.sh <command> [args]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../Resources/proxmox.env"

run() {
    "$PLINK" -pw "$PROXMOX_PASS" -hostkey "$PROXMOX_HOSTKEY" -batch -P "$PROXMOX_PORT" \
        "${PROXMOX_USER}@${PROXMOX_HOST}" "$1"
}

usage() {
    cat <<EOF
Usage: proxmox-manage.sh <command> [args]

VM commands:
  list-vms                  List all VMs
  start-vm <id>             Start a VM
  stop-vm <id>              Gracefully shut down a VM
  kill-vm <id>              Force stop a VM
  snapshot-vm <id> <name>   Create a VM snapshot
  delete-snap <id> <name>   Delete a VM snapshot
  status-vm <id>            Show VM status

Container commands:
  list-cts                  List all LXC containers
  start-ct <id>             Start a container
  stop-ct <id>              Stop a container
  snapshot-ct <id> <name>   Create a container snapshot

Node commands:
  storage                   Show storage pool status
  node-tasks                Show recent task log
  help                      Show this help

EOF
}

CMD="${1:-help}"
shift || true

case "$CMD" in
    list-vms)       run "qm list" ;;
    start-vm)       run "qm start $1" ;;
    stop-vm)        run "qm shutdown $1" ;;
    kill-vm)        run "qm stop $1" ;;
    snapshot-vm)    run "qm snapshot $1 $2 --description 'snapshot via proxmox-manage'" ;;
    delete-snap)    run "qm delsnapshot $1 $2" ;;
    status-vm)      run "qm status $1" ;;

    list-cts)       run "pct list" ;;
    start-ct)       run "pct start $1" ;;
    stop-ct)        run "pct stop $1" ;;
    snapshot-ct)    run "pct snapshot $1 $2 --description 'snapshot via proxmox-manage'" ;;

    storage)        run "pvesm status" ;;
    node-tasks)     run "pvesh get /nodes/\$(hostname)/tasks --limit 20 2>/dev/null || journalctl -u pvedaemon --no-pager -n 30" ;;

    help|--help|-h) usage ;;
    *) echo "Unknown command: $CMD"; usage; exit 1 ;;
esac
