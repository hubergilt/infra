#!/bin/bash
# create-opnsense26.sh — fw01.ad.lab fresh install
# Creates fw01 from scratch with all 8 network segments per general-nw.puml
# Uses OPNsense Importer (FAT32 config disk method)
#
# Serial console (ttyu0/115200) is enabled by injecting loader.conf into the
# ISO before booting — virsh console fw01 works from the very first boot
# without needing virt-viewer.

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
VM_NAME="fw01"
ORIG_ISO="/home/huber/Downloads/OPNsense-26.7-dvd-amd64.iso"
PATCHED_ISO="/vms/fw01-opnsense-serial.iso"
DISK_PATH="/vms/fw01.qcow2"
CONFIG_DISK="/vms/fw01-config.img"
CONFIG_SRC="$(cd "$(dirname "$0")" && pwd)/config.xml"

DISK_SIZE=20    # GB
RAM=2048        # MB
VCPUS=2

# ── Network order matches vtnet assignment in config.xml ──────────────────────
# vtnet0=WAN  vtnet1=APP  vtnet2=DMZ_WEB  vtnet3=MGMT
# vtnet4=CLIENTS  vtnet5=DMZ_VPN  vtnet6=DATA  vtnet7=IDENTITY
WAN_NET="lab-wan"
APP_NET="lab-app"
DMZ_WEB_NET="lab-dmz-web"
MGMT_NET="lab-mgmt"
CLIENTS_NET="lab-clients"
DMZ_VPN_NET="lab-dmz-vpn"
DATA_NET="lab-data"
IDENTITY_NET="lab-identity"

ALL_NETS="$WAN_NET $APP_NET $DMZ_WEB_NET $MGMT_NET $CLIENTS_NET $DMZ_VPN_NET $DATA_NET $IDENTITY_NET"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
echo "══════════════════════════════════════════════════"
echo " fw01 — OPNsense 26 fresh install"
echo "══════════════════════════════════════════════════"

for cmd in virt-install qemu-img virsh mkfs.fat xorriso; do
  command -v "$cmd" &>/dev/null || {
    echo "ERROR: '$cmd' not found."
    echo "Install: sudo apt install virtinst qemu-utils mtools dosfstools xorriso"
    exit 1
  }
done

[ ! -f "$ORIG_ISO" ] && {
  echo "ERROR: ISO not found: $ORIG_ISO"
  echo "Download from: https://opnsense.org/download/"
  exit 1
}

[ ! -f "$CONFIG_SRC" ] && {
  echo "ERROR: config.xml not found: $CONFIG_SRC"
  exit 1
}

# Verify all 8 libvirt networks exist and are active
echo "[0/5] Verifying libvirt networks..."
for net in $ALL_NETS; do
  if virsh net-list --all | grep -qE "^\s+${net}\s+active"; then
    echo "  ✅ $net — active"
  else
    echo "  ❌ $net — NOT active"
    echo ""
    echo "Run: cd ../nets && make create-networks"
    exit 1
  fi
done

mkdir -p /vms

# ── [1/5] Patch ISO — inject serial console loader.conf ──────────────────────
# FreeBSD reads /boot/loader.conf from the ISO before the kernel starts.
# Setting console=comconsole redirects all output to ttyu0 (serial/pty)
# so virsh console works from the very first boot prompt.
# We also set the baud rate and keep vidconsole as a fallback.
echo ""
echo "[1/5] Patching ISO for serial console..."

ISO_WORK=$(mktemp -d)
trap 'rm -rf "$ISO_WORK"' EXIT

# Pull just the original loader.conf so we can append to it rather than
# clobber it, then graft the updated file back into a *copy* of the ISO
# using xorriso's own modification mode. "-boot_image any replay" tells
# xorriso to reuse the source ISO's existing El Torito (BIOS) and UEFI
# boot catalog entries verbatim, so the FreeBSD boot1/boot2/cdboot images
# and their offsets stay intact — unlike rebuilding the whole ISO with
# `mkisofs` from extracted files, which easily produces a boot catalog
# the BIOS can't read ("Read Error: 0x01" at boot).
echo "  Extracting original loader.conf..."
xorriso -osirrox on -indev "$ORIG_ISO" \
  -extract /boot/loader.conf "$ISO_WORK/loader.conf" 2>/dev/null
chmod u+w "$ISO_WORK/loader.conf"

# comconsole = serial (ttyu0), vidconsole = VGA fallback
# console order: comconsole first means virsh console gets output
cat >> "$ISO_WORK/loader.conf" << 'EOF'

# Serial console — injected by create-opnsense26.sh
console="comconsole,vidconsole"
comconsole_speed="115200"
comconsole_port="0x3F8"
autoboot_delay="3"
EOF

echo "  Patching ISO in place (preserving boot catalog)..."
rm -f "$PATCHED_ISO"
if ! xorriso -indev "$ORIG_ISO" -outdev "$PATCHED_ISO" \
  -boot_image any keep \
  -map "$ISO_WORK/loader.conf" /boot/loader.conf \
  -commit -end; then
  echo ""
  echo "ERROR: xorriso failed to patch the ISO (see output above)."
  echo "Your xorriso version: $(xorriso -version 2>&1 | head -1)"
  exit 1
fi

echo "  ✅ Patched ISO: $PATCHED_ISO"

# ── [2/5] Clean old VM ────────────────────────────────────────────────────────
echo ""
echo "[2/5] Cleaning old VM if exists..."
virsh destroy  "$VM_NAME" 2>/dev/null && echo "  Stopped $VM_NAME" || true
virsh undefine "$VM_NAME" --nvram 2>/dev/null && echo "  Undefined $VM_NAME" || true
rm -f "$DISK_PATH" "$CONFIG_DISK"
echo "  ✅ Clean"

# ── [3/5] Create main disk ────────────────────────────────────────────────────
echo ""
echo "[3/5] Creating main disk ${DISK_SIZE}G at $DISK_PATH..."
qemu-img create -f qcow2 "$DISK_PATH" "${DISK_SIZE}G"
echo "  ✅ Disk created"

# ── [4/5] Build FAT32 config disk ────────────────────────────────────────────
# OPNsense Importer scans for a FAT/FAT32 device containing /conf/config.xml
# and loads it automatically at boot before the live environment starts.
echo ""
echo "[4/5] Building FAT32 config disk at $CONFIG_DISK..."

qemu-img create -f raw "$CONFIG_DISK" 64M

LOOP_DEV=$(sudo losetup --find --show "$CONFIG_DISK")
echo "  Loop device: $LOOP_DEV"

sudo parted -s "$LOOP_DEV" mklabel msdos
sudo parted -s "$LOOP_DEV" mkpart primary fat32 1MiB 100%
sudo parted -s "$LOOP_DEV" set 1 boot on

sleep 1
sudo partprobe "$LOOP_DEV" || true
sleep 1

LOOP_PART="${LOOP_DEV}p1"

echo "  Formatting ${LOOP_PART} as FAT32..."
sudo mkfs.vfat -F 32 -n "OPNSENSE" -I "$LOOP_PART" || {
  echo "ERROR: mkfs.vfat failed"
  sudo losetup -d "$LOOP_DEV"
  exit 1
}

MOUNT_POINT=$(mktemp -d)
sudo mount "$LOOP_PART" "$MOUNT_POINT"
sudo mkdir -p "$MOUNT_POINT/conf"
sudo cp "$CONFIG_SRC" "$MOUNT_POINT/conf/config.xml"
sudo chmod 644 "$MOUNT_POINT/conf/config.xml"

# Also drop loader.conf.local on the config disk as a belt-and-suspenders
# fallback in case the ISO boot sector injection didn't carry through.
sudo mkdir -p "$MOUNT_POINT/boot"
sudo tee "$MOUNT_POINT/boot/loader.conf.local" > /dev/null << 'EOF'
console="comconsole,vidconsole"
comconsole_speed="115200"
EOF

sync

echo "  Config disk contents:"
find "$MOUNT_POINT" -type f | sed 's|^|    |'

sudo umount "$MOUNT_POINT"
sudo losetup -d "$LOOP_DEV"
rmdir "$MOUNT_POINT"
echo "  ✅ Config disk ready"

# ── [5/5] Launch VM ───────────────────────────────────────────────────────────
echo ""
echo "[5/5] Launching $VM_NAME with 8 NICs..."

virt-install \
  --name           "$VM_NAME" \
  --ram            "$RAM" \
  --vcpus          "$VCPUS" \
  --os-variant     freebsd10.0 \
  --machine        q35 \
  --boot           cdrom,hd \
  --disk           path="$DISK_PATH",format=qcow2,bus=virtio \
  --cdrom          "$PATCHED_ISO" \
  --disk           path="$CONFIG_DISK",format=raw,bus=usb \
  --network        network="$WAN_NET",model=virtio \
  --network        network="$APP_NET",model=virtio \
  --network        network="$DMZ_WEB_NET",model=virtio \
  --network        network="$MGMT_NET",model=virtio \
  --network        network="$CLIENTS_NET",model=virtio \
  --network        network="$DMZ_VPN_NET",model=virtio \
  --network        network="$DATA_NET",model=virtio \
  --network        network="$IDENTITY_NET",model=virtio \
  --serial         pty \
  --graphics       spice \
  --video          virtio \
  --noautoconsole

echo ""
echo "✅ $VM_NAME started"
echo ""
echo "══════════════════════════════════════════════════"
echo " Connect to console (serial — no virt-viewer needed):"
echo ""
echo "   virsh console $VM_NAME"
echo ""
echo " If the console is blank, press Enter once."
echo " The boot menu appears in ~5 seconds."
echo ""
echo " IMPORTANT — watch for this prompt immediately after boot:"
echo ""
echo '   "Press any key to start the configuration importer"'
echo ""
echo " Press any key → enter the config disk device: da0 or da1"
echo " A successful import shows:"
echo '   "Configuration loaded"'
echo ""
echo " NIC → network → IP assignment:"
echo "   vtnet0  $WAN_NET      10.0.0.2/30   WAN"
echo "   vtnet1  $APP_NET      10.0.1.1/24   APP"
echo "   vtnet2  $DMZ_WEB_NET  10.0.2.1/24   DMZ_WEB"
echo "   vtnet3  $MGMT_NET     10.0.3.1/24   MGMT"
echo "   vtnet4  $CLIENTS_NET  10.0.4.1/24   CLIENTS"
echo "   vtnet5  $DMZ_VPN_NET  10.0.5.1/24   DMZ_VPN"
echo "   vtnet6  $DATA_NET     10.0.6.1/24   DATA"
echo "   vtnet7  $IDENTITY_NET 10.0.7.1/24   IDENTITY"
echo ""
echo " After config import, log in as installer / opnsense"
echo " and run the disk installer."
echo "══════════════════════════════════════════════════"
