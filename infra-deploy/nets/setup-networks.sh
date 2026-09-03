#!/usr/bin/env bash
# Idempotently define + start the libvirt "data" network (10.0.6.0/24).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET_NAME="data"
NET_XML="${SCRIPT_DIR}/data-network.xml"

if ! command -v virsh >/dev/null 2>&1; then
  echo "ERROR: virsh not found. Install libvirt-clients." >&2
  exit 1
fi

if virsh net-info "${NET_NAME}" >/dev/null 2>&1; then
  echo "[net] '${NET_NAME}' already defined."
else
  echo "[net] defining '${NET_NAME}' from ${NET_XML}"
  virsh net-define "${NET_XML}"
fi

if [[ "$(virsh net-info "${NET_NAME}" | awk '/^Active:/{print $2}')" != "yes" ]]; then
  echo "[net] starting '${NET_NAME}'"
  virsh net-start "${NET_NAME}"
else
  echo "[net] '${NET_NAME}' already active."
fi

virsh net-autostart "${NET_NAME}" >/dev/null
echo "[net] '${NET_NAME}' ready (autostart enabled)."
