#!/usr/bin/env bash
# Creates a TrueNAS SCALE VM on Proxmox with UEFI, q35, VirtIO SCSI, and
# 4TB USB passthrough disk. After creation, follow Output/truenas-setup-guide.md.
# Usage: ./truenas-vm-create.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../Resources/proxmox.env"

# ── Config (edit these if needed) ────────────────────────────────────────────
TRUENAS_VM_NAME="truenas-scale"
TRUENAS_CORES=6
TRUENAS_RAM_MB=16384          # 16 GB
TRUENAS_BOOT_DISK_GB=32
TRUENAS_ISO_FILENAME="TrueNAS-SCALE-25.10.3.iso"
# Check https://download.truenas.com/ for newer versions
TRUENAS_ISO_URL="https://download.truenas.com/TrueNAS-SCALE-Goldeye/25.10.3/TrueNAS-SCALE-25.10.3.iso"
RAM_WARN_THRESHOLD_MB=24576   # warn if host RAM <= 24 GB (Win11 VM = 18 GB + TrueNAS = 16 GB = 34 GB conflict)
USB_DISK_HINT="sdb"           # physical device name — change if your 4TB drive isn't /dev/sdb

# ── Output capture ────────────────────────────────────────────────────────────
OUTPUT_DIR="$SCRIPT_DIR/../Output"
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="$OUTPUT_DIR/truenas-vm-$(date +%Y%m%d).txt"
exec > >(tee -a "$OUTPUT_FILE") 2>&1

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date +%H:%M:%S)] ==> $*"; }
die()  { echo "[ERROR] $*"; exit 1; }
warn() { echo "[WARN]  $*"; }

run() {
    "$PLINK" -pw "$PROXMOX_PASS" -hostkey "$PROXMOX_HOSTKEY" -batch \
        -P "$PROXMOX_PORT" "${PROXMOX_USER}@${PROXMOX_HOST}" "$1"
}

# ── Phase 1: Pre-flight ───────────────────────────────────────────────────────
log "Starting TrueNAS SCALE VM creation"
log "Output log: $OUTPUT_FILE"

[[ -x "$PLINK" ]] || die "plink not found at: $PLINK — install PuTTY first"

log "Testing SSH connectivity to $PROXMOX_HOST..."
run "echo 'SSH OK'" || die "Cannot reach Proxmox host at $PROXMOX_HOST:$PROXMOX_PORT"

log "Proxmox version:"
run "pveversion"

log "Checking host RAM (Windows 11 VM uses 18 GB — TrueNAS needs 16 GB)..."
HOST_RAM_MB=$(run "free -m | awk '/^Mem:/{print \$2}'")
log "Host total RAM: ${HOST_RAM_MB} MB"

if [[ "$HOST_RAM_MB" -le "$RAM_WARN_THRESHOLD_MB" ]]; then
    warn "============================================================"
    warn "  HOST RAM IS ${HOST_RAM_MB} MB (threshold: ${RAM_WARN_THRESHOLD_MB} MB)"
    warn "  TrueNAS VM will use 16 GB. Windows 11 VM uses 18 GB."
    warn "  Running both simultaneously WILL cause OOM on this host."
    warn "  RECOMMENDED: Stop the Windows 11 VM before running TrueNAS."
    warn "  You can stop it with: ./proxmox-manage.sh  (stop-vm option)"
    warn "============================================================"
    warn "  Continuing in 10 seconds — Ctrl+C now to abort..."
    warn "============================================================"
    sleep 10
fi

HOST_CORES=$(run "nproc")
TOTAL_VCPUS=$((TRUENAS_CORES + 15))
log "Host CPU cores: ${HOST_CORES} | Allocated vCPUs after this VM: ${TOTAL_VCPUS}"
if [[ "$TOTAL_VCPUS" -gt "$HOST_CORES" ]]; then
    warn "Total allocated vCPUs (${TOTAL_VCPUS}) exceeds host cores (${HOST_CORES}) — Proxmox allows CPU overcommit, this is OK."
fi

# ── Phase 2: Storage detection ────────────────────────────────────────────────
log "Detecting available storage pools..."
STORAGE_STATUS=$(run "pvesm status")
echo "$STORAGE_STATUS"

if echo "$STORAGE_STATUS" | grep -qw "local-lvm"; then
    STORAGE="local-lvm"
elif echo "$STORAGE_STATUS" | grep -qw "local"; then
    STORAGE="local"
else
    STORAGE=$(echo "$STORAGE_STATUS" | awk 'NR>1 && $2=="active" {print $1; exit}')
    [[ -n "$STORAGE" ]] || die "No active storage pools found — check Proxmox storage config"
fi
log "Using storage pool: $STORAGE"

ISO_DIR="/var/lib/vz/template/iso"

# ── Phase 3: VM ID selection ──────────────────────────────────────────────────
log "Scanning for next available VM ID (starting at 200)..."
TAKEN_IDS=$(run "qm list 2>/dev/null | awk 'NR>1 {print \$1}'" || echo "")
VMID=""
for id in $(seq 200 999); do
    if ! echo "$TAKEN_IDS" | grep -qw "$id"; then
        VMID="$id"
        break
    fi
done
[[ -n "$VMID" ]] || die "No free VM ID found in range 200-999"
log "Using VM ID: $VMID"

# ── Phase 4: USB disk detection ───────────────────────────────────────────────
log "Detecting 4TB USB drive by-id path (looking for /dev/${USB_DISK_HINT})..."

DISK_BY_ID=$(run "
ls -la /dev/disk/by-id/ 2>/dev/null | grep -v part | grep '/${USB_DISK_HINT}$' | awk '{print \$(NF-2)}' | head -1
" || echo "")

if [[ -z "$DISK_BY_ID" ]]; then
    warn "Could not auto-detect by-id path for /dev/${USB_DISK_HINT}."
    warn "Full /dev/disk/by-id listing (look for entries pointing to -> ../../${USB_DISK_HINT}):"
    run "ls -la /dev/disk/by-id/ | grep -v part | grep -v 'dm-\|md-'" || true
    die "Set USB_DISK_HINT at the top of this script to match your disk device name and re-run."
fi

DISK_BYID_PATH="/dev/disk/by-id/${DISK_BY_ID}"
log "Found by-id entry: ${DISK_BY_ID}"

DISK_RESOLVED=$(run "readlink -f ${DISK_BYID_PATH}")
log "Resolves to: ${DISK_RESOLVED}"

DISK_SIZE=$(run "lsblk -d -o SIZE ${DISK_RESOLVED} 2>/dev/null | tail -1 | tr -d ' '" || echo "unknown")
log "Disk size: ${DISK_SIZE}"

DISK_SERIAL=$(run "
udevadm info --query=property --name=${DISK_RESOLVED} 2>/dev/null \
    | grep -E '^ID_SERIAL_SHORT=' | cut -d= -f2 | head -1
" || echo "")
if [[ -z "$DISK_SERIAL" ]]; then
    DISK_SERIAL=$(run "
udevadm info --query=property --name=${DISK_RESOLVED} 2>/dev/null \
    | grep -E '^ID_SERIAL=' | cut -d= -f2 | head -1
" || echo "usb-disk")
fi
log "Disk serial: ${DISK_SERIAL}"

# ── Phase 5: TrueNAS SCALE ISO ───────────────────────────────────────────────
log "Checking for TrueNAS SCALE ISO..."
ISO_STATUS=$(run "ls ${ISO_DIR}/${TRUENAS_ISO_FILENAME} 2>/dev/null && echo EXISTS || echo MISSING")

if echo "$ISO_STATUS" | grep -q "MISSING"; then
    log "Downloading TrueNAS SCALE ISO via wget (~2.2 GB, takes 10-30 min depending on connection)..."
    run "wget -c --progress=dot:giga -O ${ISO_DIR}/${TRUENAS_ISO_FILENAME} '${TRUENAS_ISO_URL}' && echo 'ISO download complete.'"

    # Sanity check — ISO should be at least 2 GB
    ISO_BYTES=$(run "stat -c%s ${ISO_DIR}/${TRUENAS_ISO_FILENAME} 2>/dev/null || echo 0")
    [[ "$ISO_BYTES" -gt 2000000000 ]] || die "ISO file is too small (${ISO_BYTES} bytes) — download may have failed. Check the URL in TRUENAS_ISO_URL."
else
    log "TrueNAS SCALE ISO already present — skipping download."
fi

# ── Phase 6: VM creation ──────────────────────────────────────────────────────
log "Creating VM ${VMID} (${TRUENAS_VM_NAME}): ${TRUENAS_CORES} cores | ${TRUENAS_RAM_MB} MB RAM | q35 + UEFI..."

run "qm create ${VMID} \
    --name ${TRUENAS_VM_NAME} \
    --memory ${TRUENAS_RAM_MB} \
    --cores ${TRUENAS_CORES} \
    --cpu host \
    --machine q35 \
    --bios ovmf \
    --ostype l26 \
    --net0 virtio,bridge=vmbr0"

log "Attaching EFI disk (4 MB, no Secure Boot keys — TrueNAS does not use Secure Boot)..."
run "qm set ${VMID} --efidisk0 ${STORAGE}:1,efitype=4m,pre-enrolled-keys=0"

log "Configuring VirtIO SCSI controller..."
run "qm set ${VMID} --scsihw virtio-scsi-pci"

log "Attaching ${TRUENAS_BOOT_DISK_GB} GB boot disk on ${STORAGE}..."
run "qm set ${VMID} --scsi0 ${STORAGE}:${TRUENAS_BOOT_DISK_GB},cache=writeback,discard=on"

log "Attaching TrueNAS SCALE ISO as ide2 (install media)..."
run "qm set ${VMID} --ide2 local:iso/${TRUENAS_ISO_FILENAME},media=cdrom"

log "Setting boot order: CD-ROM first, then disk..."
run "qm set ${VMID} --boot order='ide2;scsi0'"

log "Configuring display and tablet input..."
run "qm set ${VMID} --vga std --tablet 1"

# ── Phase 7: USB disk passthrough ─────────────────────────────────────────────
log "Attaching 4TB USB passthrough disk as scsi1..."
log "  by-id path : ${DISK_BYID_PATH}"
log "  serial     : ${DISK_SERIAL}"

run "qm set ${VMID} --scsi1 ${DISK_BYID_PATH},serial=${DISK_SERIAL}"

# ── Phase 8: Verification ─────────────────────────────────────────────────────
log "Verifying final VM configuration..."
FINAL_CONFIG=$(run "qm config ${VMID}")
echo "$FINAL_CONFIG"

echo "$FINAL_CONFIG" | grep -q "scsi0"   || warn "scsi0 (boot disk) not found — check VM config"
echo "$FINAL_CONFIG" | grep -q "scsi1"   || warn "scsi1 (4TB passthrough) not found — check VM config"
echo "$FINAL_CONFIG" | grep -q "efidisk" || warn "EFI disk not found — check VM config"

# ── Phase 9: Write post-install guide ────────────────────────────────────────
GUIDE_FILE="$OUTPUT_DIR/truenas-setup-guide.md"
log "Writing post-install guide to $GUIDE_FILE..."

cat > "$GUIDE_FILE" << GUIDE_EOF
# TrueNAS SCALE Post-Install Setup Guide
Generated: $(date)
VM ID: ${VMID} | Boot disk: scsi0 on ${STORAGE} | Data disk: ${DISK_BYID_PATH} (${DISK_SIZE})

---

## Step 1 — Start the VM and run the installer

1. Open Proxmox Web UI: https://${PROXMOX_HOST}:8006
2. Click VM **${VMID}** (${TRUENAS_VM_NAME}) → **Start**
3. Click **Console** to open the VM screen
4. TrueNAS installer will boot from the ISO
5. Select **Install/Upgrade** → choose **da0** (the 32 GB virtual disk = scsi0)
   - **CRITICAL: Do NOT select the 4TB disk (da1 / scsi1) — that is your data drive**
6. Confirm the warning, set an admin password, proceed
7. After install completes → **Reboot** (installer will prompt)
8. Remove ISO after reboot: Proxmox Web UI → VM ${VMID} → Hardware → ide2 → Edit → "Do not use any media"

---

## Step 2 — Find TrueNAS IP and first login

- The VM console login screen shows the assigned IP (e.g. \`192.168.1.50\`)
- Or check your router's DHCP leases table for a host named \`${TRUENAS_VM_NAME}\`
- Open \`http://<truenas-ip>\` in a browser
- Login: username \`admin\`, password you set during install

---

## Step 3 — Set a static IP (do this first, before anything else)

1. Network → Interfaces → **vnet0** → Edit
2. Disable DHCP
3. Set: IP Address \`192.168.1.50\` / Prefix \`24\`, Default Gateway \`192.168.1.1\`, DNS \`1.1.1.1\`
4. Save → Test Changes → Confirm
5. Reconnect at \`http://192.168.1.50\`

---

## Step 4 — Create ZFS pool on the 4TB drive

> **WARNING: Single-disk pool = NO redundancy. A drive failure = total data loss.**
> If you add a second 4TB drive later: \`zpool attach tank <current-disk-id> <new-disk-id>\`

1. Storage → **Create Pool**
2. Pool name: \`tank\`
3. Layout: **Stripe** (single disk — only option with one drive)
4. Add disk: the 4TB drive (~3.6 TiB usable)
5. Confirm redundancy warning → **Create**

**Create datasets** (Storage → tank → Add Dataset for each):

| Dataset | Compression | ACL Mode | Purpose |
|---|---|---|---|
| photos | lz4 | Restricted | Immich photo library |
| documents | lz4 | Passthrough | SMB share for Windows |
| videos | lz4 | Passthrough | SMB share for Windows |

---

## Step 5 — SMB shares for Windows file access

**Create a local user** (Credentials → Local Users → Add):
- Username: \`homelab\` (or your preference)
- Password: set one (this is your Windows network drive credential)
- Shell: \`nologin\`

**Set dataset permissions** (Storage → tank → documents → Edit Permissions):
- Owner User: \`homelab\` | Owner Group: \`homelab\`
- Apply permissions recursively: yes
- ACL Preset: **Open** (full LAN access — fine for home lab)
- Repeat for \`videos\` dataset

**Create SMB shares** (Shares → Windows (SMB) Shares → Add):
- Share 1: Name \`documents\` → Path \`/mnt/tank/documents\`
- Share 2: Name \`videos\` → Path \`/mnt/tank/videos\`

**Enable SMB service**: Services → SMB → toggle ON → set **Start Automatically**

**Connect from Windows**:
- Windows Explorer address bar: \`\\\\192.168.1.50\\documents\`
- Credential: \`homelab\` / your password
- Right-click → **Map network drive** for persistent access

---

## Step 6 — Install Immich from the app catalog

1. Apps → **Discover Apps** → search **Immich** → Install
2. Configure:
   - Application Name: \`immich\`
   - **Storage → Library path: \`/mnt/tank/photos\`** ← CRITICAL: change from default ix-volumes
   - Port: \`3001\` (default)
   - Machine Learning: enabled (uses CLIP for smart photo search)
3. Click **Install** — Docker images pull in 5-10 minutes

**First-run setup**:
- Open \`http://192.168.1.50:3001\`
- Create admin account (first registered user is admin)
- Settings → Storage Template (configure folder organization)

> **Note:** If Immich is not in the official catalog, use Apps → **Custom App** with:
> Image: \`ghcr.io/immich-app/immich-server:release\` and follow the official
> Immich Docker Compose documentation at https://immich.app/docs/install/docker-compose

---

## Step 7 — Cloudflare Tunnel (public internet access)

**Prerequisites:**
- Free Cloudflare account at https://cloudflare.com
- A domain added to Cloudflare (OR use free \`*.cfargotunnel.com\` URL — no domain needed)

**Create the tunnel** (Cloudflare Zero Trust dashboard → https://one.dash.cloudflare.com):
1. Networks → Tunnels → **Create a tunnel**
2. Connector: Cloudflared | Name: \`truenas-immich\` → Save
3. Copy the **tunnel token** shown on screen
4. Public Hostname tab:
   - Subdomain: \`photos\` | Domain: \`yourdomain.com\`
   - Service: \`http://192.168.1.50:3001\`
5. Save tunnel

**Install cloudflared on TrueNAS** (Apps → Custom App):

\`\`\`
Application Name: cloudflared
Image Repository: cloudflare/cloudflared
Image Tag: latest
Command: tunnel
Args: --no-autoupdate run --token <PASTE_YOUR_TOKEN_HERE>
Network mode: host
Restart Policy: unless-stopped
\`\`\`

Click Install. After it starts, check Cloudflare dashboard — tunnel status should turn green.

> No router port forwarding required — cloudflared connects outbound to Cloudflare's edge.

---

## Access summary

| Method | URL | Notes |
|---|---|---|
| Local LAN | \`http://192.168.1.50:3001\` | Fastest, direct |
| Tailscale | \`http://192.168.1.50:3001\` | Works from anywhere via Proxmox subnet router |
| Cloudflare public | \`https://photos.yourdomain.com\` | Internet-accessible, HTTPS |
| SMB documents | \`\\\\192.168.1.50\\documents\` | Windows Explorer / Map drive |
| SMB videos | \`\\\\192.168.1.50\\videos\` | Windows Explorer / Map drive |

---

## Resource reminder

Running Windows 11 VM (18 GB) + TrueNAS VM (16 GB) simultaneously requires 34+ GB host RAM.
- If RAM is tight: shut down Windows 11 VM when TrueNAS is running
- TrueNAS/Immich is designed to run 24/7; Windows VM can be started on demand

GUIDE_EOF

log "Post-install guide saved: $GUIDE_FILE"

# ── Phase 10: Final banner ────────────────────────────────────────────────────
echo ""
echo "======================================================================"
echo "  TrueNAS SCALE VM Created Successfully"
echo "======================================================================"
echo "  VM ID      : ${VMID}"
echo "  VM Name    : ${TRUENAS_VM_NAME}"
echo "  CPU        : ${TRUENAS_CORES} cores (host type)"
echo "  RAM        : ${TRUENAS_RAM_MB} MB (16 GB)"
echo "  Boot Disk  : ${TRUENAS_BOOT_DISK_GB} GB scsi0 on ${STORAGE}"
echo "  Data Disk  : scsi1 -> ${DISK_BYID_PATH} (${DISK_SIZE})"
echo "  Machine    : q35 + OVMF/UEFI (no TPM, no Secure Boot)"
echo "  Network    : virtio on vmbr0 (check DHCP, then set static IP)"
echo "----------------------------------------------------------------------"
echo "  RAM NOTE: Win11 VM (18 GB) + TrueNAS (16 GB) = 34 GB combined."
echo "  Do NOT run both VMs at the same time if host RAM <= 32 GB."
echo "----------------------------------------------------------------------"
echo "  Web UI     : https://${PROXMOX_HOST}:8006/#v1:0:=qemu/${VMID}:4:::::"
echo "----------------------------------------------------------------------"
echo "  NEXT STEPS:"
echo "    1. Open Proxmox Web UI -> Start VM ${VMID}"
echo "    2. Click Console -> complete TrueNAS installer"
echo "       Install to: scsi0 (32 GB) — NOT scsi1 (4TB data disk!)"
echo "    3. After reboot, find TrueNAS IP in DHCP table or VM console"
echo "    4. Follow the guide: $GUIDE_FILE"
echo "======================================================================"
echo "  Log saved  : $OUTPUT_FILE"
echo "======================================================================"
