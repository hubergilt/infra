#!/bin/bash
# create-sql01-vm.sh
# Creates the sql01 VM (Windows Server Core) — fully unattended OS install
# AND fully unattended SQL Server 2025 (Enterprise Developer/Eval) install.
#
# Same pattern as create-ad01-vm.sh: a custom answer file lives in this
# folder (sql01-autounattend.xml) with hostname (SQL01) and static IP
# baked in directly, and its FirstLogonCommands stage
# phase3-sql01-unattended.ps1 onto the guest via an $OEM$ folder and
# launch it once. From there the guest configures itself, mounts the
# SQL Server media (attached as a second virtual CD-ROM, not merged into
# the Windows ISO — SQL media is large and doesn't need WinPE access),
# and runs setup.exe /ConfigurationFile=ConfigurationFile.ini with zero
# console interaction: OS install -> first boot -> locate SQL CD-ROM ->
# unattended SQL Server install -> verify -> ready. See msql25/README.md
# for how the chain works. Lives alongside dcs/ (ad01/domain-controller
# scripts) and win19/ (Windows Server 2019 media + NetKVM drivers) at
# the repo root.
#
# Requirements: p7zip-full, genisoimage, qemu-utils, virtinst, ovmf
#   apt install p7zip-full genisoimage qemu-utils virtinst ovmf
#
# Run from inside the msql25/ folder:
#   ./create-sql01-vm.sh

set -e

VM_NAME="${1:-sql01}"

# Windows Server install media. SQL Server 2025 needs Windows Server 2016+;
# reuses the same media as create-ad01-vm.sh by default. Point this at
# 2022/2025 media instead if that's what you'd rather run SQL on.
ORIG_ISO="/home/huber/Downloads/en-us_windows_server_2019_x64_dvd_f9475476.iso"

# SQL Server 2025 install media — attached to the VM as a second CD-ROM
# rather than extracted into the Windows ISO (it's ~6GB and WinPE never
# needs to see it; the guest only needs it after first boot).
SQL_ISO="/home/huber/Downloads/SQLServer2025-x64-ENU-EntDev.iso"

ANSWER_FILE="$(pwd)/sql01-autounattend.xml"
PROVISION_SCRIPT="$(pwd)/phase3-sql01-unattended.ps1"
SQL_CONFIG_FILE="$(pwd)/ConfigurationFile.ini"
NEW_ISO="$(pwd)/${VM_NAME}-unattended.iso"
WORK_DIR="/tmp/${VM_NAME}-iso-work"
DISK_PATH="/vms/${VM_NAME}.qcow2"
NETKVM_SRC="$(pwd)/../win19/NetKVM"
NETKVM_DST="$WORK_DIR/NetKVM"
DISK_SIZE=80
RAM=4096
VCPUS=4
NETWORK="lab-identity"

# Dependency check
for cmd in 7z genisoimage qemu-img virt-install; do
    command -v "$cmd" &>/dev/null || {
        echo "ERROR: '$cmd' not found."
        echo "  Install: apt install p7zip-full genisoimage qemu-utils virtinst ovmf"
        exit 1
    }
done

[ ! -f "$ORIG_ISO" ] && echo "ERROR: ISO not found: $ORIG_ISO" && exit 1
[ ! -f "$SQL_ISO" ] && echo "ERROR: SQL Server ISO not found: $SQL_ISO" && exit 1
[ ! -f "$ANSWER_FILE" ] && echo "ERROR: Answer file not found: $ANSWER_FILE (expected in msql25/)" && exit 1
[ ! -f "$PROVISION_SCRIPT" ] && echo "ERROR: Provisioning script not found: $PROVISION_SCRIPT" && exit 1
[ ! -f "$SQL_CONFIG_FILE" ] && echo "ERROR: SQL ConfigurationFile.ini not found: $SQL_CONFIG_FILE (expected in msql25/)" && exit 1

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

# 2. Inject answer file, NetKVM VirtIO driver, and the SQL provisioning
#    files (script + ConfigurationFile.ini) via an $OEM$ folder so they
#    land at C:\Provision on the guest with no CD-ROM lookup required.
echo "[2/5] Injecting sql01-autounattend.xml, NetKVM driver, and Provision\\phase3-sql01-unattended.ps1..."
cp "$ANSWER_FILE" "$WORK_DIR/autounattend.xml"

if [ ! -d "$NETKVM_SRC" ]; then
    echo "ERROR: NetKVM driver folder not found at $NETKVM_SRC"
    echo "  Download virtio-win drivers from https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/"
    echo "  and place the NetKVM/w2k19/amd64/ contents in ../win19/NetKVM/"
    exit 1
fi
cp -r "$NETKVM_SRC" "$NETKVM_DST"

OEM_DIR="$WORK_DIR/sources/\$OEM\$/\$1/Provision"
mkdir -p "$OEM_DIR"
cp "$PROVISION_SCRIPT" "$OEM_DIR/phase3-sql01-unattended.ps1"
cp "$SQL_CONFIG_FILE" "$OEM_DIR/ConfigurationFile.ini"

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

# 4. Clean up old VM, create disk, launch with UEFI.
#    Two CD-ROMs are attached: the custom Windows install ISO (boots
#    Setup) and the untouched SQL Server ISO (read by
#    phase3-sql01-unattended.ps1 after first boot). SQL Server plus a
#    real database workload wants more than the ad01 defaults, so RAM
#    and vCPUs are bumped above create-ad01-vm.sh's.
echo "[4/5] Creating disk and launching VM (UEFI)..."
virsh destroy "$VM_NAME" 2>/dev/null || true
virsh undefine "$VM_NAME" --nvram 2>/dev/null || true
rm -f "$DISK_PATH"
qemu-img create -f qcow2 "$DISK_PATH" "${DISK_SIZE}G"

# See create-ad01-vm.sh for the rationale behind --wait + --noautoconsole
# here (keeps virt-install babysitting install-time reboots instead of
# leaving the domain "shut off" for someone to notice by hand). SQL Server
# setup itself runs later, driven entirely from inside the guest by
# phase3-sql01-unattended.ps1 — this --wait window only covers the OS
# install.
virt-install \
    --name "$VM_NAME" \
    --ram "$RAM" \
    --vcpus "$VCPUS" \
    --os-variant win2k19 \
    --machine q35 \
    --boot uefi \
    --disk path="$DISK_PATH",format=qcow2,bus=sata \
    --cdrom "$NEW_ISO" \
    --disk path="$SQL_ISO",device=cdrom,bus=sata \
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
echo "NEXT: nothing to do by hand. Once Windows Setup finishes, sql01 renames"
echo "  itself to SQL01, sets its static IP, locates the attached SQL Server"
echo "  CD-ROM, and runs an unattended SQL Server 2025 install automatically,"
echo "  rebooting if setup requests it."
echo "  Track progress from inside the guest:"
echo "    Get-Content C:\\ProvisionState\\sql01-unattended.log -Wait"
echo "    Get-Content C:\\ProvisionState\\sql01.stage   (0=installing SQL, 1=installed, 2=verified)"
echo "  Once sql01.stage reaches 2, connect with:"
echo "    sqlcmd -S sql01 -U sa -P <password> -Q \"SELECT @@VERSION;\""
