#!/bin/bash
# create-ad01-vm.sh
# Creates the ad01 VM (Windows Server 2019 Core) — fully unattended OS
# install AND fully unattended AD DS forest-root promotion.
#
# Unlike the earlier version of this script, the answer file is a custom
# copy that lives in this folder (ad01-autounattend.xml) instead of a
# reference to ../win19/autounattend.xml — hostname (AD01) and static IP
# (10.0.7.10/24) are baked in directly, and its FirstLogonCommands stage
# phase3-ad01-unattended.ps1 onto the guest and launch it once. From there
# the guest promotes itself to the ad.lab forest root with zero console
# interaction: OS install -> first boot -> AD DS/DNS install -> promote ->
# reboot -> verify. See dcs/README.md section 7 for how the chain works.
#
# Requirements: p7zip-full, genisoimage, qemu-utils, virtinst, ovmf
#   apt install p7zip-full genisoimage qemu-utils virtinst ovmf
#
# Run from inside the dcs/ folder:
#   ./create-ad01-vm.sh

set -e

VM_NAME="${1:-ad01}"
ORIG_ISO="/home/huber/Downloads/en-us_windows_server_2019_x64_dvd_f9475476.iso"
ANSWER_FILE="$(pwd)/ad01-autounattend.xml"
PROVISION_SCRIPT="$(pwd)/phase3-ad01-unattended.ps1"
NEW_ISO="$(pwd)/${VM_NAME}-unattended.iso"
WORK_DIR="/tmp/${VM_NAME}-iso-work"
DISK_PATH="/vms/${VM_NAME}.qcow2"
NETKVM_SRC="$(pwd)/../win19/NetKVM"
NETKVM_DST="$WORK_DIR/NetKVM"
DISK_SIZE=50
RAM=2048
VCPUS=2
NETWORK="lab-identity"

# Dependency check
for cmd in 7z genisoimage qemu-img virt-install; do
  command -v "$cmd" &>/dev/null || {
    echo "ERROR: '$cmd' not found."
    echo "  Install: apt install p7zip-full genisoimage qemu-utils virtinst ovmf"
    exit 1
  }
done

[ ! -f "$ORIG_ISO" ]         && echo "ERROR: ISO not found: $ORIG_ISO"                                   && exit 1
[ ! -f "$ANSWER_FILE" ]      && echo "ERROR: Answer file not found: $ANSWER_FILE (expected in dcs/)"      && exit 1
[ ! -f "$PROVISION_SCRIPT" ] && echo "ERROR: Provisioning script not found: $PROVISION_SCRIPT"            && exit 1

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

# 2. Inject answer file, NetKVM VirtIO driver, and the DC promotion script
echo "[2/5] Injecting ad01-autounattend.xml, NetKVM driver, and Provision\\phase3-ad01-unattended.ps1..."
cp "$ANSWER_FILE" "$WORK_DIR/autounattend.xml"

if [ ! -d "$NETKVM_SRC" ]; then
  echo "ERROR: NetKVM driver folder not found at $NETKVM_SRC"
  echo "  Download virtio-win drivers from https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/"
  echo "  and place the NetKVM/w2k19/amd64/ contents in ../win19/NetKVM/"
  exit 1
fi
cp -r "$NETKVM_SRC" "$NETKVM_DST"

mkdir -p "$WORK_DIR/Provision"
cp "$PROVISION_SCRIPT" "$WORK_DIR/Provision/phase3-ad01-unattended.ps1"

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

# 4. Clean up old VM, create disk, launch with UEFI
echo "[4/5] Creating disk and launching VM (UEFI)..."
virsh destroy  "$VM_NAME" 2>/dev/null || true
virsh undefine "$VM_NAME" --nvram 2>/dev/null || true
rm -f "$DISK_PATH"

qemu-img create -f qcow2 "$DISK_PATH" "${DISK_SIZE}G"

virt-install \
  --name           "$VM_NAME" \
  --ram            "$RAM" \
  --vcpus          "$VCPUS" \
  --os-variant     win2k19 \
  --machine        q35 \
  --boot           uefi \
  --disk           path="$DISK_PATH",format=qcow2,bus=sata \
  --cdrom          "$NEW_ISO" \
  --network        network="$NETWORK",model=virtio \
  --graphics       spice \
  --video          qxl \
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
echo "NEXT: nothing to do by hand. Once Windows Setup finishes, ad01 renames"
echo "  itself to AD01, sets 10.0.7.10/24, installs AD DS + DNS, and promotes"
echo "  itself as the ad.lab forest root automatically, rebooting as needed."
echo "  Track progress from inside the guest:"
echo "    Get-Content C:\\ProvisionState\\ad01-unattended.log -Wait"
echo "    Get-Content C:\\ProvisionState\\ad01.stage   (0=installing AD DS, 1=promoted, 2=verified)"
echo "  Once ad01.stage reaches 2, run ./create-ad02-vm.sh."
