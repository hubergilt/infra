#!/bin/bash
# create-win19.sh — Create a Windows Server 2019 VM with virt-install
# Run as root or a user in the libvirt group

# — Configuration —
VM_NAME="win19"
ISO_PATH="/home/huber/Downloads/en-us_windows_server_2019_x64_dvd_f9475476.iso"
DISK_PATH="/vms/win19.qcow2"
DISK_SIZE=50       # GB
RAM=4096          # MB  (adjust as needed)
VCPUS=2           # vCPUs (adjust as needed)

# — Pre-flight checks —
if [ ! -f "$ISO_PATH" ]; then
  echo "ERROR: ISO not found at $ISO_PATH"
  exit 1
fi

if [ ! -d "/vms" ]; then
  echo "Creating /vms directory..."
  mkdir -p /vms
fi

# — Create the disk image —
echo "Creating disk image at $DISK_PATH (${DISK_SIZE}GB)..."
qemu-img create -f qcow2 "$DISK_PATH" "${DISK_SIZE}G"

# — Create the VM —
echo "Starting virt-install for $VM_NAME..."
virt-install \
  --name           "$VM_NAME" \
  --ram            "$RAM" \
  --vcpus          "$VCPUS" \
  --os-variant     win2k19 \
  --disk           path="$DISK_PATH",format=qcow2,bus=virtio \
  --cdrom          "$ISO_PATH" \
  --network        network=default,model=virtio \
  --graphics       spice \
  --video          qxl \
  --boot           cdrom,hd \
  --noautoconsole

echo "VM '$VM_NAME' created. Connect with:"
echo "  virt-viewer $VM_NAME   or   virt-manager"
