#!/bin/bash
# create-rodc01-vm.sh
# Creates the rodc01 VM (Windows Server 2025 Core) — fully unattended OS
# install AND fully unattended read-only replica DC (RODC) promotion.
#
# Same pattern as create-ad02-vm.sh: a custom answer file lives in this
# folder (rodc01-autounattend.xml) with hostname (RODC01) and static IPs
# baked in directly, and its FirstLogonCommands stage
# phase3-rodc01-unattended.ps1 onto the guest and launch it once. From
# there the guest waits for ad01/ad02 on its own (retrying every 2 minutes,
# no manual rerun needed) and promotes itself as a read-only replica DC
# once one of them answers. See dcs/README.md section 7 for how the chain
# works, extended for -ReadOnlyReplica.
#
# UNLIKE ad01/ad02, rodc01 is triple-homed — DMZ-Web, DMZ-VPN, and MGMT —
# so it needs three --network attachments below, each with a MAC address
# pinned to match the MAC-keyed <Interface> blocks baked into
# rodc01-autounattend.xml. Do not change these MACs without updating the
# answer file to match, or the static-IP assignment on first boot will
# silently land on the wrong NIC (or none at all).
#
# PREREQUISITE (also noted in the answer file and phase3 script headers):
# fw01 needs an outbound allow rule from lab-dmz-web AND lab-dmz-vpn to
# ad01/ad02 (10.0.7.10, 10.0.7.11) on the ADPorts alias
# (53/88/389/445/636/3268/3269) before rodc01 can promote. This is a
# documented gap in dcs/README.md section 3 — add it in opnsense26/
# beforehand, or Stage 0 of phase3-rodc01-unattended.ps1 will just retry
# forever.
#
# PREREQUISITE: ad01 and/or ad02 should already be up and promoted (see
# create-ad01-vm.sh / create-ad02-vm.sh) before rodc01 is promoted — VM
# creation itself has no such dependency, and rodc01 will simply keep
# retrying until one of them answers.
#
# Requirements: p7zip-full, genisoimage, qemu-utils, virtinst, ovmf
#   apt install p7zip-full genisoimage qemu-utils virtinst ovmf
#
# Run from inside the dcs/ folder:
#   ./create-rodc01-vm.sh

set -e

VM_NAME="${1:-rodc01}"

# Windows Server 2025 install media — same media create-win25-unnatend.sh
# and msql25/create-sql01-vm.sh use.
ORIG_ISO="/home/huber/Downloads/en-us_windows_server_2025_updated_july_2026_x64_dvd_4e6f5a42.iso"
ANSWER_FILE="$(pwd)/rodc01-autounattend.xml"
PROVISION_SCRIPT="$(pwd)/phase3-rodc01-unattended.ps1"
NEW_ISO="$(pwd)/${VM_NAME}-unattended.iso"
WORK_DIR="/tmp/${VM_NAME}-iso-work"
DISK_PATH="/vms/${VM_NAME}.qcow2"
NETKVM_SRC="$(pwd)/../win25/NetKVM"
NETKVM_DST="$WORK_DIR/NetKVM"
DISK_SIZE=50
RAM=2048
VCPUS=2

# Pinned MACs — MUST match the <Identifier> values in
# rodc01-autounattend.xml's TCPIP/DNS-Client Interface blocks exactly.
MAC_DMZ_WEB="52:54:00:02:00:15"   # lab-dmz-web  -> 10.0.2.15/24
MAC_DMZ_VPN="52:54:00:05:00:15"   # lab-dmz-vpn  -> 10.0.5.15/24
MAC_MGMT="52:54:00:03:00:14"      # lab-mgmt     -> 10.0.3.14/24

# Dependency check
for cmd in 7z genisoimage qemu-img virt-install; do
  command -v "$cmd" &>/dev/null || {
    echo "ERROR: '$cmd' not found."
    echo "  Install: apt install p7zip-full genisoimage qemu-utils virtinst ovmf"
    exit 1
  }
done

[ ! -f "$ORIG_ISO" ]         && echo "ERROR: ISO not found: $ORIG_ISO"                                     && exit 1
[ ! -f "$ANSWER_FILE" ]      && echo "ERROR: Answer file not found: $ANSWER_FILE (expected in dcs/)"        && exit 1
[ ! -f "$PROVISION_SCRIPT" ] && echo "ERROR: Provisioning script not found: $PROVISION_SCRIPT"              && exit 1

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

# 2. Inject answer file, NetKVM VirtIO driver, and the RODC promotion script
echo "[2/5] Injecting rodc01-autounattend.xml, NetKVM driver, and Provision\\phase3-rodc01-unattended.ps1..."
cp "$ANSWER_FILE" "$WORK_DIR/autounattend.xml"

if [ ! -d "$NETKVM_SRC" ]; then
  echo "ERROR: NetKVM driver folder not found at $NETKVM_SRC"
  echo "  Mount virtio-win.iso and copy the NetKVM/2k25/amd64/ (or w2k22 fallback) contents into ../win25/NetKVM/"
  exit 1
fi
cp -r "$NETKVM_SRC" "$NETKVM_DST"

mkdir -p "$WORK_DIR/Provision"
cp "$PROVISION_SCRIPT" "$WORK_DIR/Provision/phase3-rodc01-unattended.ps1"

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
echo "[4/5] Creating disk and launching VM (UEFI, 3 NICs: DMZ-Web/DMZ-VPN/MGMT)..."
virsh destroy  "$VM_NAME" 2>/dev/null || true
virsh undefine "$VM_NAME" --nvram 2>/dev/null || true
rm -f "$DISK_PATH"

qemu-img create -f qcow2 "$DISK_PATH" "${DISK_SIZE}G"

# See create-ad01-vm.sh for why --wait is here: --noautoconsole is
# documented to leave a multistep (--cdrom) install shut off once it
# completes, regardless of any reboot Windows itself requested along the
# way. --wait keeps virt-install alive so it manages those reboots itself.
virt-install \
  --name           "$VM_NAME" \
  --ram            "$RAM" \
  --vcpus          "$VCPUS" \
  --os-variant     win2k25 \
  --machine        q35 \
  --boot           uefi \
  --disk           path="$DISK_PATH",format=qcow2,bus=sata \
  --cdrom          "$NEW_ISO" \
  --network        network=lab-dmz-web,model=virtio,mac="$MAC_DMZ_WEB" \
  --network        network=lab-dmz-vpn,model=virtio,mac="$MAC_DMZ_VPN" \
  --network        network=lab-mgmt,model=virtio,mac="$MAC_MGMT" \
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
echo "NEXT: nothing to do by hand. Once Windows Setup finishes, rodc01 renames"
echo "  itself to RODC01, sets 10.0.2.15/24 (DMZ-Web), 10.0.5.15/24 (DMZ-VPN),"
echo "  and 10.0.3.14/24 (MGMT), waits for ad01/ad02 to answer (retrying every"
echo "  2 minutes on its own), installs AD DS, and promotes itself as a"
echo "  read-only replica DC for ad.lab automatically, rebooting as needed."
echo "  Track progress from inside the guest:"
echo "    Get-Content C:\\ProvisionState\\rodc01-unattended.log -Wait"
echo "    Get-Content C:\\ProvisionState\\rodc01.stage   (0=waiting/installing, 1=promoted, 2=verified)"
echo ""
echo "  If it never gets past stage 0, check the fw01 DMZ-Web/DMZ-VPN -> Identity"
echo "  ACL prerequisite noted at the top of this script and of rodc01-autounattend.xml."
