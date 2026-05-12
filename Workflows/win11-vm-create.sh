#!/usr/bin/env bash
# Creates a Windows 11 Pro VM on Proxmox with TPM 2.0, UEFI, VirtIO SCSI, and balloon driver.
# Usage: ./win11-vm-create.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../Resources/proxmox.env"

# ── Output capture ────────────────────────────────────────────────────────────
OUTPUT_DIR="$SCRIPT_DIR/../Output"
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="$OUTPUT_DIR/win11-vm-$(date +%Y%m%d).txt"
exec > >(tee -a "$OUTPUT_FILE") 2>&1

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[$(date +%H:%M:%S)] ==> $*"; }
die() { echo "[ERROR] $*"; exit 1; }

run() {
    "$PLINK" -pw "$PROXMOX_PASS" -hostkey "$PROXMOX_HOSTKEY" -batch \
        -P "$PROXMOX_PORT" "${PROXMOX_USER}@${PROXMOX_HOST}" "$1"
}

# ── Phase 1: Pre-flight ───────────────────────────────────────────────────────
log "Starting Windows 11 Pro VM creation"
log "Output log: $OUTPUT_FILE"

[[ -x "$PLINK" ]] || die "plink not found at: $PLINK — install PuTTY first"

log "Testing SSH connectivity to $PROXMOX_HOST..."
run "echo 'SSH OK'" || die "Cannot reach Proxmox host at $PROXMOX_HOST:$PROXMOX_PORT"

log "Proxmox version:"
run "pveversion"

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

# ── Phase 4: VirtIO drivers ISO ───────────────────────────────────────────────
VIRTIO_ISO="virtio-win.iso"
VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
ISO_DIR="/var/lib/vz/template/iso"

log "Checking for VirtIO drivers ISO..."
VIRTIO_STATUS=$(run "ls ${ISO_DIR}/${VIRTIO_ISO} 2>/dev/null && echo EXISTS || echo MISSING")
if echo "$VIRTIO_STATUS" | grep -q "MISSING"; then
    log "Downloading VirtIO ISO via Proxmox storage API (this takes a few minutes)..."
    run "pvesh create /nodes/pve/storage/local/download-url \
        --url '${VIRTIO_URL}' \
        --filename '${VIRTIO_ISO}' \
        --content iso 2>&1 || true"
    # pvesh download-url runs as a background task; poll until the file appears
    log "Waiting for VirtIO ISO download to complete..."
    run "
for i in \$(seq 1 60); do
    if ls ${ISO_DIR}/${VIRTIO_ISO} 2>/dev/null; then
        echo 'VirtIO ISO ready.'
        break
    fi
    echo \"Waiting... (\$i/60)\"
    sleep 10
done
ls ${ISO_DIR}/${VIRTIO_ISO} || { echo 'TIMEOUT: VirtIO ISO not found after 10 minutes'; exit 1; }
"
else
    log "VirtIO ISO already present — skipping download."
fi

# ── Phase 5: Windows 11 ISO ───────────────────────────────────────────────────
WIN_ISO="win11.iso"
log "Checking for Windows 11 ISO..."
WIN_STATUS=$(run "ls ${ISO_DIR}/${WIN_ISO} 2>/dev/null && echo EXISTS || echo MISSING")

if echo "$WIN_STATUS" | grep -q "MISSING"; then
    log "Windows 11 ISO not found. Fetching ESD URL from Microsoft MediaCreationTool catalog..."

    # The MCT catalog (CAB) contains direct ESD download URLs from Microsoft's CDN.
    # We parse it locally on the Windows workstation, then download the ESD on Proxmox
    # and convert ESD → bootable ISO using wimlib + xorriso (all on Proxmox).
    WIN11_ESD_URL=$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "
\$ProgressPreference='SilentlyContinue'
\$ErrorActionPreference='Stop'
try {
    \$r = Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?LinkId=2156292' -UseBasicParsing
    \$cabUrl = \$r.BaseResponse.ResponseUri.AbsoluteUri
    \$cabPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'Win11MCT.cab')
    \$xmlDir  = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'Win11MCT')
    New-Item -ItemType Directory -Force -Path \$xmlDir | Out-Null
    Invoke-WebRequest -Uri \$cabUrl -OutFile \$cabPath -UseBasicParsing
    \$shell = New-Object -ComObject Shell.Application
    \$shell.Namespace(\$xmlDir).CopyHere(\$shell.Namespace(\$cabPath).Items(), 1044)
    Start-Sleep -Seconds 3
    [xml]\$xml = Get-Content (Get-ChildItem \$xmlDir -Filter '*.xml')[0].FullName
    \$f = \$xml.MCT.Catalogs.Catalog.PublishedMedia.Files.File |
        Where-Object { \$_.LanguageCode -eq 'en-us' -and \$_.Architecture -eq 'x64' -and \$_.Edition -eq 'Professional' } |
        Select-Object -First 1
    Write-Output \$f.FilePath.Trim()
    Remove-Item -Recurse -Force \$xmlDir,\$cabPath -ErrorAction SilentlyContinue
} catch { Write-Error \$_.Exception.Message }
" 2>/dev/null | tr -d '\r\n' | grep -o 'http[s]*://[^ ]*')

    [[ -n "$WIN11_ESD_URL" ]] || die "Could not retrieve Windows 11 ESD URL from Microsoft MCT catalog."
    log "Got ESD URL: ${WIN11_ESD_URL:0:80}..."

    # Install conversion tools on Proxmox
    log "Installing ISO build tools on Proxmox (wimtools, xorriso)..."
    run "DEBIAN_FRONTEND=noninteractive apt-get install -y wimtools xorriso 2>&1 | grep -E 'Setting up|already installed|0 newly' | head -5"

    # Work directory on local storage (86 GB available)
    WORK_DIR="/var/lib/vz/tmp/win11build"
    run "mkdir -p ${WORK_DIR}/isofiles"

    # Download ESD on Proxmox directly from Microsoft CDN (~5 GB)
    log "Downloading Windows 11 ESD on Proxmox (~5 GB — 15-30 min)..."
    run "wget -c --progress=dot:giga -O ${WORK_DIR}/win11.esd '${WIN11_ESD_URL}' && echo 'ESD download complete.'"

    # Show image list (for debugging)
    log "Windows 11 ESD image list:"
    run "wimlib-imagex info ${WORK_DIR}/win11.esd 2>&1 | grep -E '^(Index|Name):'"

    # Extract the full installer directory from image 1 (contains boot/, efi/, sources/, setup.exe)
    log "Extracting ISO structure from ESD image 1 (installer layout + boot files)..."
    run "wimlib-imagex apply ${WORK_DIR}/win11.esd 1 ${WORK_DIR}/isofiles 2>&1 | tail -3"

    # Find Professional edition index and export it
    log "Exporting Windows 11 Pro edition to install.esd..."
    run "
set -e
PRO_IDX=\$(wimlib-imagex info ${WORK_DIR}/win11.esd | awk '/^Index:/{idx=\$2} /^Name:.*[Pp]ro(fessional)?(\$| )/{print idx; exit}')
echo \"Professional edition index: \$PRO_IDX\"
[ -n \"\$PRO_IDX\" ] || { echo 'ERROR: Professional edition not found in ESD'; exit 1; }
rm -f ${WORK_DIR}/isofiles/sources/install.wim
wimlib-imagex export ${WORK_DIR}/win11.esd \$PRO_IDX \
    ${WORK_DIR}/isofiles/sources/install.esd \
    --compress=LZMS --solid 2>&1 | tail -3
echo 'Pro edition exported.'
"

    # Verify boot files are present in the extracted image
    log "Verifying boot files exist in extracted ISO structure..."
    run "
ls ${WORK_DIR}/isofiles/boot/etfsboot.com 2>/dev/null && echo 'etfsboot.com OK' || echo 'WARNING: etfsboot.com missing'
ls ${WORK_DIR}/isofiles/efi/microsoft/boot/efisys.bin 2>/dev/null && echo 'efisys.bin OK' || echo 'WARNING: efisys.bin missing'
ls ${WORK_DIR}/isofiles/sources/install.esd 2>/dev/null && echo 'install.esd OK' || echo 'WARNING: install.esd missing'
"

    # Build the bootable ISO (-boot-load-seg not supported in xorriso 1.5.6, removed)
    log "Building bootable Windows 11 Pro ISO with xorriso..."
    run "
set -e
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid 'WIN11PRO' \
    -b boot/etfsboot.com \
    -no-emul-boot \
    -boot-load-size 8 \
    -eltorito-alt-boot \
    -e efi/microsoft/boot/efisys.bin \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -output ${ISO_DIR}/${WIN_ISO} \
    ${WORK_DIR}/isofiles/ 2>&1 | tail -8
echo 'ISO built successfully.'
"

    # Only clean up after confirmed success
    log "Removing temporary build files..."
    run "rm -rf ${WORK_DIR}"

    WIN_CHECK=$(run "ls -lh ${ISO_DIR}/${WIN_ISO} 2>/dev/null && echo OK || echo FAILED")
    echo "$WIN_CHECK" | grep -q "OK" || die "Windows 11 ISO build failed. Check /var/lib/vz/ storage space on Proxmox and re-run."
    log "Windows 11 Pro ISO ready."
else
    log "Windows 11 ISO already present — skipping download."
fi

# ── Phase 6: VM creation ──────────────────────────────────────────────────────
log "Creating VM ${VMID} (win11-pro): 15 cores | 18 GB RAM | 500 GB disk..."

run "qm create ${VMID} \
    --name win11-pro \
    --memory 18432 \
    --cores 15 \
    --cpu host \
    --machine q35 \
    --bios ovmf \
    --ostype win11 \
    --net0 virtio,bridge=vmbr0"

log "Attaching EFI disk (UEFI + Secure Boot keys)..."
run "qm set ${VMID} --efidisk0 ${STORAGE}:0,efitype=4m,pre-enrolled-keys=1"

log "Attaching TPM 2.0 state disk..."
run "qm set ${VMID} --tpmstate0 ${STORAGE}:0,version=v2.0"

log "Configuring VirtIO SCSI controller (required for vioscsi driver)..."
run "qm set ${VMID} --scsihw virtio-scsi-pci"

log "Attaching 500 GB OS disk (VirtIO SCSI)..."
run "qm set ${VMID} --scsi0 ${STORAGE}:500,cache=writeback,discard=on"

log "Attaching Windows 11 ISO as ide2 (primary boot CD)..."
run "qm set ${VMID} --ide2 local:iso/${WIN_ISO},media=cdrom"

log "Attaching VirtIO drivers ISO as ide3..."
run "qm set ${VMID} --ide3 local:iso/${VIRTIO_ISO},media=cdrom"

log "Setting boot order: CD-ROM first, then disk..."
run "qm set ${VMID} --boot order='ide2;scsi0'"

log "Configuring display (std) and tablet input..."
run "qm set ${VMID} --vga std --tablet 1"

log "Enabling memory balloon device (18 GB floor)..."
run "qm set ${VMID} --balloon 18432"

# ── Phase 7: Verification ─────────────────────────────────────────────────────
log "Verifying final VM configuration..."
FINAL_CONFIG=$(run "qm config ${VMID}")
echo "$FINAL_CONFIG"

echo ""
echo "======================================================================"
echo "  Windows 11 Pro VM Created Successfully"
echo "======================================================================"
echo "  VM ID      : ${VMID}"
echo "  VM Name    : win11-pro"
echo "  Storage    : ${STORAGE}"
echo "  CPU        : 15 cores (host type)"
echo "  RAM        : 18432 MB (18 GB) + balloon driver"
echo "  Disk       : 500 GB scsi0 (VirtIO SCSI, writeback cache)"
echo "  Machine    : q35 + OVMF/UEFI + TPM 2.0"
echo "  Network    : virtio on vmbr0"
echo "  Boot Order : ide2 (Win11 ISO) -> scsi0 (disk)"
echo "----------------------------------------------------------------------"
echo "  DRIVERS (on ide3 — VirtIO ISO):"
echo "    vioscsi  — SSD/disk visibility (load during install at disk screen)"
echo "    Balloon  — RAM balloon driver  (install after Windows is running)"
echo "    NetKVM   — Network adapter     (install after Windows is running)"
echo "    vioserial— Guest agent channel (install after Windows is running)"
echo "  TIP: After install run virtio-win-gt-x64.msi from ide3 root for all drivers at once"
echo "----------------------------------------------------------------------"
echo "  Web UI     : https://${PROXMOX_HOST}:8006/#v1:0:=qemu/${VMID}:4:::::"
echo "  VNC        : Click 'Console' in the Proxmox Web UI after starting"
echo "----------------------------------------------------------------------"
echo "  NEXT STEP  : Open the Web UI -> click 'Start' on VM ${VMID}"
echo "               At the 'Where to install Windows?' screen:"
echo "               1. Click 'Load driver'"
echo "               2. Browse to ide3 -> vioscsi -> w11 -> amd64"
echo "               3. Click OK -> install vioscsi -> your 500 GB disk appears"
echo "======================================================================"
echo "  Log saved  : $OUTPUT_FILE"
echo "======================================================================"
