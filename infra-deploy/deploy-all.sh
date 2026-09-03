#!/usr/bin/env bash
# Orchestrates the full unattended build of sql01 and sql02:
#   1. define/start the "data" libvirt network
#   2. render autounattend.xml for each VM from the template
#   3. build each VM's answer-media ISO
#   4. virt-install each VM, fully unattended
#
# Required environment variables (see README.md):
#   WIN_ISO VIRTIO_ISO SQL_ISO DOMAIN_JOIN_USER DOMAIN_JOIN_PASS
#   LOCAL_ADMIN_PASSWORD SA_PASSWORD
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for req in WIN_ISO VIRTIO_ISO SQL_ISO DOMAIN_JOIN_USER DOMAIN_JOIN_PASS LOCAL_ADMIN_PASSWORD SA_PASSWORD; do
  if [[ -z "${!req:-}" ]]; then
    echo "ERROR: required env var '${req}' is not set. See README.md 'Usage'." >&2
    exit 1
  fi
done

echo "== 1/4: libvirt network =="
"${SCRIPT_DIR}/nets/setup-networks.sh"

VMS=(sql01 sql02)

echo "== 2/4: render autounattend.xml =="
for vm in "${VMS[@]}"; do
  "${SCRIPT_DIR}/win25/generate-autounattend.sh" "${SCRIPT_DIR}/win25/vars/${vm}.env"
done

echo "== 3/4: build answer-media ISOs =="
for vm in "${VMS[@]}"; do
  "${SCRIPT_DIR}/scripts/make-answer-iso.sh" "${vm}"
done

echo "== 4/4: deploy VMs (unattended) =="
for vm in "${VMS[@]}"; do
  "${SCRIPT_DIR}/scripts/deploy-vm.sh" "${SCRIPT_DIR}/win25/vars/${vm}.env"
done

echo
echo "Both VMs are installing unattended. Each will:"
echo "  - partition/install Windows Server 2025"
echo "  - set its static IP + DNS"
echo "  - join ${DOMAIN_FQDN:-ad.lab}"
echo "  - silently install SQL Server 2025 and open TCP 1433"
echo
echo "Once both report healthy, optionally run:"
echo "  scripts/ag/Setup-AlwaysOn.ps1 -Primary sql01.ad.lab -Secondary sql02.ad.lab -ListenerIP 10.0.6.72"
echo "from a management host to wire them into an Always On AG."
