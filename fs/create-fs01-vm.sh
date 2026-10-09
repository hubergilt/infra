#!/bin/bash
# create-fs01-vm.sh
# Creates the fs01 VM (Windows Server 2025 Core) — fully unattended OS
# install AND fully unattended file-server provisioning (domain join,
# FS role, shares, DFS Namespace + Replication).
#
# Same pattern as create-sql01-vm.sh / create-ad01-vm.sh: a custom
# answer file lives in this folder (fs01-autounattend.xml) with hostname
# (FS01) and static IP (10.0.6.31/24, lab-data) baked in directly, and
# its FirstLogonCommands stage phase3-fs01-unattended.ps1 onto the guest
# via the install media and launch it once. From there the guest joins
# ad.lab, installs the File Server + DFS roles, creates shares, and
# stands up the \\ad.lab\Files DFS Namespace with fs01 as the active
# (highest-priority) target — with zero console interaction after this
# command is run. See fs/README.md for the full chain, including how
# fs02 (standby) plugs into the same namespace/replication group.
#
# Requirements: p7zip-full, genisoimage, qemu-utils, virtinst, ovmf
#   apt install p7zip-full genisoimage qemu-utils virtinst ovmf
#
# Run from inside the fs/ folder:
#   ./create-fs01-vm.sh

set -e

VM_NAME="${1:-fs01}"

# Windows Server 2025 install media — same media used by msql25/create-sql01-vm.sh
# and win25/create-win25-unnatend.sh.
ORIG_ISO="/home/huber/Downloads/en-us_windows_server_2025_updated_july_2026_x64_dvd_4e6f5a42.iso"

ANSWER_FILE="$(pwd)/fs01-autounattend.xml"
PROVISION_SCRIPT="$(pwd)/phase3-fs01-unattended.ps1"
NEW_ISO="$(pwd)/${VM_NAME}-unattended.iso"
WORK_DIR="/tmp/${VM_NAME}-iso-work"
DISK_PATH="/vms/${VM_NAME}.qcow2"
DATA_DISK_PATH="/vms/${VM_NAME}-data.qcow2"
NETKVM_SRC="$(pwd)/../win25/NetKVM"
NETKVM_DST="$WORK_DIR/NetKVM"
OS_DISK_SIZE=50
DATA_DISK_SIZE=100
RAM=4096
VCPUS=2
NETWORK="lab-data"

# Dependency check
for cmd in 7z genisoimage qemu-img virt-install; do
    command -v "$cmd" &>/dev/null || {
        echo "ERROR: '$cmd' not found."
        echo "  Install: apt install p7zip-full genisoimage qemu-utils virtinst ovmf"
        exit 1
    }
done

[ ! -f "$ORIG_ISO" ] && echo "ERROR: ISO not found: $ORIG_ISO" && exit 1
[ ! -f "$ANSWER_FILE" ] && echo "ERROR: Answer file not found: $ANSWER_FILE (expected in fs/)" && exit 1
[ ! -f "$PROVISION_SCRIPT" ] && echo "ERROR: Provisioning script not found: $PROVISION_SCRIPT" && exit 1

# Check OVMF firmware is available for UEFI
if [ ! -f /usr/share/OVMF/OVMF_CODE.fd ] && [ ! -f /usr/share/ovmf/OVMF.fd ]; then
    echo "ERROR: OVMF not found. Install with: apt install ovmf"
    exit 1
fi

mkdir -p /vms

# 1. Extract ISO
echo "[1/5] Extracting ISO..."
rm -rf "$WORK_DIR" && mkdir -p "$WORK_DIR"
7z x "$ORIG_ISO" -o"$WORK_DIR" -y > /dev/null

# 2. Inject answer file, NetKVM VirtIO driver, and the file-server
#    provisioning script via an $OEM$ folder so it lands at C:\Provision
#    on the guest with no CD-ROM lookup required (same as msql25).
echo "[2/5] Injecting fs01-autounattend.xml, NetKVM driver, and Provision\\phase3-fs01-unattended.ps1..."
cp "$ANSWER_FILE" "$WORK_DIR/autounattend.xml"

if [ ! -d "$NETKVM_SRC" ]; then
    echo "ERROR: NetKVM driver folder not found at $NETKVM_SRC"
    echo "  Download virtio-win drivers from https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/"
    echo "  and place the NetKVM/w2k22/amd64/ contents in ../win25/NetKVM/"
    exit 1
fi
cp -r "$NETKVM_SRC" "$NETKVM_DST"

OEM_DIR="$WORK_DIR/sources/\$OEM\$/\$1/Provision"
mkdir -p "$OEM_DIR"
cp "$PROVISION_SCRIPT" "$OEM_DIR/phase3-fs01-unattended.ps1"

# 3. Rebuild bootable ISO
echo "[3/5] Rebuilding ISO at $NEW_ISO ..."
genisoimage \
    -iso-level 4 \
    -l -R -J \
    -no-emul-boot \
    -b boot/etfsboot.com \
    -boot-load-size 8 \
    -boot-load-seg 0x07C0 \
    -eltorito-alt-boot \
    -e efi/microsoft/boot/efisys_noprompt.bin \
    -no-emul-boot \
    -allow-limited-size \
    -relaxed-filenames \
    -o "$NEW_ISO" \
    "$WORK_DIR"

# 4. Clean up old VM, create disks, launch with UEFI.
#    A second virtio disk (DATA_DISK_PATH) is attached for share content —
#    fs01-autounattend.xml only touches DiskID 0 (the OS disk);
#    phase3-fs01-unattended.ps1 initializes and formats this second disk
#    as D: on first run, then creates shares under D:\Shares.
echo "[4/5] Creating disks and launching VM (UEFI)..."
virsh destroy "$VM_NAME" 2>/dev/null || true
virsh undefine "$VM_NAME" --nvram 2>/dev/null || true
rm -f "$DISK_PATH" "$DATA_DISK_PATH"
qemu-img create -f qcow2 "$DISK_PATH" "${OS_DISK_SIZE}G"
qemu-img create -f qcow2 "$DATA_DISK_PATH" "${DATA_DISK_SIZE}G"

# See create-ad01-vm.sh for the rationale behind --wait + --noautoconsole
# (keeps virt-install babysitting install-time reboots instead of leaving
# the domain "shut off" for someone to notice by hand). Domain join and
# role installation happen later, driven entirely from inside the guest
# by phase3-fs01-unattended.ps1 — this --wait window only covers the OS
# install.
virt-install \
    --name "$VM_NAME" \
    --ram "$RAM" \
    --vcpus "$VCPUS" \
    --os-variant win2k22 \
    --machine q35 \
    --boot uefi \
    --disk path="$DISK_PATH",format=qcow2,bus=sata \
    --disk path="$DATA_DISK_PATH",format=qcow2,bus=virtio \
    --cdrom "$NEW_ISO" \
    --network network="$NETWORK",model=virtio \
    --graphics spice \
    --video qxl \
    --wait 60 \
    --noautoconsole

# 5. Clean WORK_DIR
echo "[5/5] Clean WORK_DIR"
rm -rf "$WORK_DIR"

echo ""
echo "Done. VM '$VM_NAME' is installing unattended (UEFI/GPT)."
echo "  Watch progress : virt-viewer $VM_NAME"
echo "  Check state    : virsh domstate $VM_NAME"
echo "  List VMs       : virsh list --all"
echo ""
echo "NEXT: nothing to do by hand. Once Windows Setup finishes, fs01 renames"
echo "  itself to FS01, sets 10.0.6.31/24, joins ad.lab, installs the File"
echo "  Server + DFS roles, formats the data disk as D:, creates shares, and"
echo "  publishes \\\\ad.lab\\Files (active target) automatically, rebooting"
echo "  once for the domain join."
echo "  Track progress from inside the guest:"
echo "    Get-Content C:\\ProvisionState\\fs01-unattended.log -Wait"
echo "    Get-Content C:\\ProvisionState\\fs01.stage   (0=join domain, 1=FS role+shares, 2=DFS-N/DFS-R, 3=verified)"
echo "  Once fs01.stage reaches 3, run:"
echo "    ./create-fs02-vm.sh"
