#!/bin/bash
# create-ora01-unattend.sh — Oracle Linux 10.1 unattended install (ora01)
# Fully hands-off: virt-install extracts kernel/initrd from the DVD ISO,
# injects ks-ol10.cfg, and Anaconda installs + configures Phases 1-6
# from README.md with zero prompts. Attach to lab-data (10.0.6.0/24).
#
# Requirements: virtinst, qemu-utils
#   apt install virtinst qemu-utils
#
# Usage: ./create-ora01-unattend.sh

set -e

VM_NAME="${1:-ora01}"
ORIG_ISO="/home/huber/Downloads/OracleLinux-R10-U2-x86_64-dvd-20260709.iso"
KS_FILE="$(pwd)/ks-ol10.cfg"
DISK_PATH="/vms/${VM_NAME}.qcow2"
DISK_SIZE=80        # GB — DB home (~10GB) + oradata + headroom
RAM=4096             # MB — bump to 8192+ for a real workload
VCPUS=2
NETWORK="lab-data"   # falls back to lab-lan if lab-data isn't defined yet
MAC="52:54:00:6f:6a:01"

# Oracle Linux 10 isn't in every osinfo-db release yet (checked via your
# os.list — no ol10.x entries, only up to ol9.4). OL10 is RHEL10-based,
# so rhel10.0 is the correct stand-in until osinfo-db catches up.
OS_VARIANT="rhel10.0"

# ── dependency checks ────────────────────────────────────────────
for cmd in virt-install qemu-img virsh; do
  command -v "$cmd" &>/dev/null || {
    echo "ERROR: '$cmd' not found."
    echo "  Install: sudo apt install virtinst qemu-utils"
    exit 1
  }
done

[ ! -f "$ORIG_ISO" ] && echo "ERROR: ISO not found: $ORIG_ISO" && exit 1
[ ! -f "$KS_FILE" ]  && echo "ERROR: Kickstart not found: $KS_FILE (edit sshkey/password first!)" && exit 1

# ── verify the os-variant exists locally, else fall back ─────────
if command -v osinfo-query &>/dev/null; then
  if ! osinfo-query os short-id="$OS_VARIANT" &>/dev/null; then
    echo "WARNING: '$OS_VARIANT' not found in local osinfo-db, falling back to 'rhel10-unknown'."
    OS_VARIANT="rhel10-unknown"
    if ! osinfo-query os short-id="$OS_VARIANT" &>/dev/null; then
      echo "WARNING: '$OS_VARIANT' also not found, falling back to 'generic'."
      OS_VARIANT="generic"
    fi
  fi
fi

if grep -q "REPLACE_WITH_YOUR_SSH_PUBLIC_KEY" "$KS_FILE"; then
  echo "WARNING: ks-ol10.cfg still has the placeholder SSH key."
  echo "         Edit it with your real public key before continuing."
  read -rp "Continue anyway? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

# ── validate kickstart syntax before booting, if ksvalidator is available ─
# Catches removed/renamed options (OL10.1 -> OL10.2 changed several, per
# Oracle's release notes) before you burn 10 minutes on a failed install.
if command -v ksvalidator &>/dev/null; then
  echo "Validating kickstart syntax (ksvalidator -v RHEL10)..."
  if ! ksvalidator -v RHEL10 "$KS_FILE"; then
    echo "ERROR: ksvalidator found problems in $KS_FILE — fix them before continuing."
    exit 1
  fi
else
  echo "NOTE: 'ksvalidator' not found (pip/dnf install pykickstart) — skipping pre-flight syntax check."
fi

mkdir -p /vms

# ── make sure the target network exists, else fall back ─────────
if ! virsh net-info "$NETWORK" &>/dev/null; then
  echo "WARNING: libvirt network '$NETWORK' not defined."
  echo "  Define it first:  virsh net-define nets/lab-data.xml && virsh net-start lab-data && virsh net-autostart lab-data"
  echo "  Falling back to 'lab-lan' for this run."
  NETWORK="lab-lan"
fi

# ── clean old VM if re-running ───────────────────────────────────
echo "[1/3] Cleaning old VM if exists..."
virsh destroy  "$VM_NAME" 2>/dev/null || true
virsh undefine "$VM_NAME" --nvram 2>/dev/null || true
rm -f "$DISK_PATH"

# ── create disk ───────────────────────────────────────────────────
echo "[2/3] Creating disk image at $DISK_PATH (${DISK_SIZE}G)..."
qemu-img create -f qcow2 "$DISK_PATH" "${DISK_SIZE}G"

# ── launch unattended install ────────────────────────────────────
echo "[3/3] Launching $VM_NAME (fully unattended, text-mode kickstart)..."
virt-install \
  --name           "$VM_NAME" \
  --ram            "$RAM" \
  --vcpus          "$VCPUS" \
  --os-variant     "$OS_VARIANT" \
  --machine        q35 \
  --disk           path="$DISK_PATH",format=qcow2,bus=virtio \
  --location       "$ORIG_ISO" \
  --initrd-inject  "$KS_FILE" \
  --extra-args     "inst.ks=file:/ks-ol10.cfg console=ttyS0 inst.text" \
  --network        network="$NETWORK",model=virtio,mac="$MAC" \
  --graphics       none \
  --noautoconsole \
  --wait -1

echo ""
echo "✅ ora01 install kicked off unattended."
echo "   Watch the text install:  virsh console $VM_NAME"
echo "   Poll state:               virsh domstate $VM_NAME"
echo ""
echo "Once it reboots into a login prompt, SSH in as huber and run:"
echo "   scp deploy-oracle-db.sh V1054592-01.zip huber@10.0.6.80:~/"
echo "   ssh huber@10.0.6.80 './deploy-oracle-db.sh'"
