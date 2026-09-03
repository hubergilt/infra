#!/usr/bin/env bash
# Fully unattended virt-install for a single sqlNN VM.
# Usage: ./deploy-vm.sh win25/vars/sql01.env
set -euo pipefail

VARS_FILE="${1:?Usage: $0 win25/vars/<vm>.env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1090
source "${VARS_FILE}"

: "${WIN_ISO:?Set WIN_ISO to your Windows Server 2025 install ISO path}"
: "${VIRTIO_ISO:?Set VIRTIO_ISO to your virtio-win.iso path}"
: "${SQL_ISO:?Set SQL_ISO to your SQL Server 2025 ISO path}"

ANSWER_ISO="${REPO_ROOT}/win25/build/${VM_NAME}/answer-media.iso"
DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"

if [[ ! -f "${ANSWER_ISO}" ]]; then
  echo "ERROR: ${ANSWER_ISO} not found — run make-answer-iso.sh for ${VM_NAME} first." >&2
  exit 1
fi

if virsh dominfo "${VM_NAME}" >/dev/null 2>&1; then
  echo "[deploy] '${VM_NAME}' already exists — skipping (virsh undefine --remove-all-storage to rebuild)."
  exit 0
fi

echo "[deploy] creating ${VM_NAME} (${IP_ADDRESS}) on network '${NETWORK}'"

# osinfo-db may not have a win2k25 entry yet depending on how recently it
# was updated on this host; fall back to win2k22 (closest known-good
# device/driver profile) with a warning rather than hard-failing.
OS_VARIANT="win2k25"
if command -v osinfo-query >/dev/null 2>&1 && ! osinfo-query os short-id="${OS_VARIANT}" >/dev/null 2>&1; then
  echo "[deploy] WARNING: osinfo-db has no '${OS_VARIANT}' entry on this host, falling back to 'win2k22'. Run 'osinfo-db-import' to update." >&2
  OS_VARIANT="win2k22"
fi

virt-install \
  --name "${VM_NAME}" \
  --memory "${RAM_MB}" \
  --vcpus "${VCPUS}" \
  --os-variant "${OS_VARIANT}" \
  --disk path="${DISK_PATH}",size="${DISK_GB}",bus=virtio,format=qcow2 \
  --disk "${WIN_ISO}",device=cdrom \
  --disk "${VIRTIO_ISO}",device=cdrom \
  --disk "${ANSWER_ISO}",device=cdrom \
  --disk "${SQL_ISO}",device=cdrom \
  --network network="${NETWORK}",model=virtio \
  --graphics vnc,listen=127.0.0.1 \
  --boot cdrom,hd \
  --noautoconsole \
  --wait -1

echo "[deploy] '${VM_NAME}' install kicked off unattended. Watch progress with:"
echo "         virsh console ${VM_NAME}   (or connect VNC to 127.0.0.1)"
echo "[deploy] SQL Server install runs automatically at first boot via"
echo "         C:\\Windows\\Setup\\Scripts\\SetupComplete.cmd — check"
echo "         C:\\Windows\\Setup\\Scripts\\logs\\ inside the guest once it's up."
