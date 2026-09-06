#!/bin/bash
# create-dhcp01-vm.sh
# Creates the dhcp01 VM (Windows Server 2025 Core) — fully unattended OS
# install AND fully unattended DHCP Server role install/configuration.
#
# Same pattern as dcs/create-ad01-vm.sh and msql25/create-sql01-vm.sh: a
# custom answer file lives in this folder (dhcp01-autounattend.xml) with
# hostname (DHCP01) and static IP baked in directly, and its
# FirstLogonCommands stage phase3-dhcp01-unattended.ps1 onto the guest and
# launch it once. From there the guest joins ad.lab, installs the DHCP
# Server feature, configures the scope for the lab-clients segment, and
# authorizes itself in AD — all with zero console interaction: OS install
# -> first boot -> join domain -> reboot -> install DHCP -> configure
# scope -> authorize -> verify. See dhcp01/README.md for how the chain
# works.
#
# Per general-nw.puml (Identity/PKI tier, 10.0.7.0/24): dhcp01 sits
# alongside ad01/ad02 on lab-identity and serves DHCP to the lab-clients
# segment (10.0.4.0/24) via fw01's ip-helper relay — it is no longer on
# the flat lab-lan/App-GW segment used by the older services/ scripts.
#
# Requirements: p7zip-full, genisoimage, qemu-utils, virtinst, ovmf
#   apt install p7zip-full genisoimage qemu-utils virtinst ovmf
#
# Prerequisite: ad01 and ad02 already promoted and replicating (dcs/).
#
# Run from inside the dhcp01/ folder:
#   ./create-dhcp01-vm.sh

set -e

VM_NAME="${1:-dhcp01}"

# Windows Server 2025 install media — same media as win25/create-win25-unnatend.sh
# and msql25/create-sql01-vm.sh. Point this at your local copy.
ORIG_ISO="/home/huber/Downloads/en-us_windows_server_2025_updated_july_2026_x64_dvd_4e6f5a42.iso"

ANSWER_FILE="$(pwd)/dhcp01-autounattend.xml"
PROVISION_SCRIPT="$(pwd)/phase3-dhcp01-unattended.ps1"
NEW_ISO="$(pwd)/${VM_NAME}-unattended.iso"
WORK_DIR="/tmp/${VM_NAME}-iso-work"
DISK_PATH="/vms/${VM_NAME}.qcow2"
NETKVM_SRC="$(pwd)/../win25/NetKVM"
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

[ ! -f "$ORIG_ISO" ]         && echo "ERROR: ISO not found: $ORIG_ISO"                                       && exit 1
[ ! -f "$ANSWER_FILE" ]      && echo "ERROR: Answer file not found: $ANSWER_FILE (expected in dhcp01/)"      && exit 1
[ ! -f "$PROVISION_SCRIPT" ] && echo "ERROR: Provisioning script not found: $PROVISION_SCRIPT"               && exit 1

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

# 2. Inject answer file, NetKVM VirtIO driver, and the DHCP role
#    provisioning script. Staged at the ISO root under Provision\ (same
#    D:\Provision approach as dcs/create-ad01-vm.sh) so FirstLogonCommands
#    can copy it with no dependency on a network share being reachable yet.
echo "[2/5] Injecting dhcp01-autounattend.xml, NetKVM driver, and Provision\\phase3-dhcp01-unattended.ps1..."
cp "$ANSWER_FILE" "$WORK_DIR/autounattend.xml"

if [ ! -d "$NETKVM_SRC" ]; then
  echo "ERROR: NetKVM driver folder not found at $NETKVM_SRC"
  echo "  Download virtio-win drivers from https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/"
  echo "  and place the NetKVM/w2k22/amd64/ contents in ../win25/NetKVM/"
  exit 1
fi
cp -r "$NETKVM_SRC" "$NETKVM_DST"

mkdir -p "$WORK_DIR/Provision"
cp "$PROVISION_SCRIPT" "$WORK_DIR/Provision/phase3-dhcp01-unattended.ps1"

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

# --wait keeps virt-install alive to babysit Windows Setup's own
# install-time reboots (see dcs/README.md section 2.4) — without it the
# VM ends up "shut off" after the multistep --cdrom install completes,
# needing a manual `virsh start`.
virt-install \
  --name           "$VM_NAME" \
  --ram            "$RAM" \
  --vcpus          "$VCPUS" \
  --os-variant     win2k22 \
  --machine        q35 \
  --boot           uefi \
  --disk           path="$DISK_PATH",format=qcow2,bus=sata \
  --cdrom          "$NEW_ISO" \
  --network        network="$NETWORK",model=virtio \
  --graphics       spice \
  --video          qxl \
  --wait           60 \
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
echo "NEXT: nothing to do by hand. Once Windows Setup finishes, dhcp01 renames"
echo "  itself to DHCP01, sets 10.0.7.30/24 on lab-identity, joins ad.lab,"
echo "  installs the DHCP Server role, configures the lab-clients scope"
echo "  (10.0.4.0/24), and authorizes itself in AD automatically, rebooting"
echo "  once after the domain join."
echo "  Track progress from inside the guest:"
echo "    Get-Content C:\\ProvisionState\\dhcp01-unattended.log -Wait"
echo "    Get-Content C:\\ProvisionState\\dhcp01.stage   (0=joining domain, 1=installing DHCP, 2=verified)"
