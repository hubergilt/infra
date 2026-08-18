#!/bin/bash
# create-opnsense26.sh — using OPNsense Importer (documented method)
# Attaches a FAT32 config disk as a second virtual drive
# OPNsense Importer reads it automatically at boot

set -e

VM_NAME="fw01"
ORIG_ISO="/home/huber/Downloads/OPNsense-26.1.2-dvd-amd64.iso"
DISK_PATH="/vms/fw01.qcow2"
CONFIG_DISK="/vms/fw01-config.img"   # FAT32 virtual USB drive
CONFIG_SRC="$(pwd)/config.xml"

DISK_SIZE=20
RAM=2048
VCPUS=2

WAN_NET="lab-wan"
LAN_NET="lab-lan"
DMZ_NET="lab-dmz"
MGMT_NET="lab-mgmt"

# ── checks ────────────────────────────────────────────────────
for cmd in virt-install qemu-img virsh mkfs.fat mcopy mmd; do
  command -v "$cmd" &>/dev/null || {
    echo "ERROR: '$cmd' not found."
    echo "Install: sudo apt install virtinst qemu-utils mtools dosfstools"
    exit 1
  }
done

[ ! -f "$ORIG_ISO" ] && \
  echo "ERROR: ISO not found: $ORIG_ISO" && exit 1

[ ! -f "$CONFIG_SRC" ] && \
  echo "ERROR: config/conf/config.xml not found in $(pwd)" && exit 1

mkdir -p /vms

# ── clean old VM ──────────────────────────────────────────────
echo "[1/4] Cleaning old VM if exists..."
virsh destroy  "$VM_NAME" 2>/dev/null || true
virsh undefine "$VM_NAME" --nvram 2>/dev/null || true
rm -f "$DISK_PATH" "$CONFIG_DISK"

# ── create main disk ──────────────────────────────────────────
echo "[2/4] Creating main disk ${DISK_SIZE}G..."
qemu-img create -f qcow2 "$DISK_PATH" "${DISK_SIZE}G"

# ── create FAT32 config disk with conf/config.xml ─────────────
# This is the "second USB drive" described in OPNsense docs.
# OPNsense Importer scans for a FAT/FAT32 device containing
# /conf/config.xml and loads it before the live environment starts.
echo "[3/4] Building FAT32 config disk..."

# Create raw disk
qemu-img create -f raw "$CONFIG_DISK" 64M

# Setup loop device
LOOP_DEV=$(sudo losetup --find --show "$CONFIG_DISK")

# Partition (MBR + FAT32)
sudo parted -s "$LOOP_DEV" mklabel msdos
sudo parted -s "$LOOP_DEV" mkpart primary fat32 1MiB 100%
sudo parted -s "$LOOP_DEV" set 1 boot on

# Critical: Tell kernel to re-read partition table
sleep 1
sudo partprobe "$LOOP_DEV" || true
sleep 1

LOOP_PART="${LOOP_DEV}p1"

# Format with -I (force on partitioned loop device) and bigger cluster if needed
echo "Formatting ${LOOP_PART} as FAT32..."
sudo mkfs.vfat -F 32 -n "OPNSENSE" -I "$LOOP_PART" || {
    echo "ERROR: mkfs.vfat failed"
    sudo losetup -d "$LOOP_DEV"
    exit 1
}

# Mount and copy config
MOUNT_POINT=$(mktemp -d)
sudo mount "$LOOP_PART" "$MOUNT_POINT"
sudo mkdir -p "$MOUNT_POINT/conf"
sudo cp "$CONFIG_SRC" "$MOUNT_POINT/conf/config.xml"
sudo chmod 644 "$MOUNT_POINT/conf/config.xml"
sync

echo "Config disk contents:"
ls -la "$MOUNT_POINT/conf/"

# Cleanup
sudo umount "$MOUNT_POINT"
sudo losetup -d "$LOOP_DEV"
rmdir "$MOUNT_POINT"

echo "✓ Config disk created: $CONFIG_DISK"

# ── launch VM ─────────────────────────────────────────────────
echo "[4/4] Launching $VM_NAME..."

virt-install \
  --name           "$VM_NAME" \
  --ram            "$RAM" \
  --vcpus          "$VCPUS" \
  --os-variant     freebsd10.0 \
  --machine        q35 \
  --boot           cdrom,hd \
  --disk           path="$DISK_PATH",format=qcow2,bus=virtio \
  --cdrom          "$ORIG_ISO" \
  --disk           path="$CONFIG_DISK",format=raw,bus=usb \
  --network        network="$WAN_NET",model=virtio \
  --network        network="$LAN_NET",model=virtio \
  --network        network="$DMZ_NET",model=virtio \
  --network        network="$MGMT_NET",model=virtio \
  --graphics       spice \
  --video          virtio \
  --noautoconsole

echo ""
echo "✅ $VM_NAME started. Open console:"
echo ""
echo "   virt-viewer $VM_NAME"
echo ""
echo "════════════════════════════════════════════════"
echo " IMPORTANT — watch for this prompt at boot:"
echo ""
echo '   "Press any key to start the configuration importer"'
echo ""
echo " Press any key immediately when you see it."
echo " Then type the device name of the config disk."
echo " It will be:  da0  or  da1  (the USB/virtio disk)"
echo ""
echo " If importer succeeds you will see:"
echo '   "Configuration loaded"'
echo " and boot continues into the live environment"
echo " with your custom interfaces already assigned."
echo ""
echo " Then login as installer / opnsense"
echo " and run the disk installer normally."
echo "════════════════════════════════════════════════"
