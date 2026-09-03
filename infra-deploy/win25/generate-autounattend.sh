#!/usr/bin/env bash
# Render win25/autounattend.xml.tmpl -> build/<vm>/autounattend.xml
# Usage: ./generate-autounattend.sh vars/sql01.env
set -euo pipefail

if ! command -v envsubst >/dev/null 2>&1; then
  echo "ERROR: envsubst not found (apt install gettext-base)." >&2
  exit 1
fi

VARS_FILE="${1:?Usage: $0 vars/<vm>.env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1090
source "${VARS_FILE}"

: "${DOMAIN_JOIN_USER:?Set DOMAIN_JOIN_USER in the environment}"
: "${DOMAIN_JOIN_PASS:?Set DOMAIN_JOIN_PASS in the environment}"
: "${LOCAL_ADMIN_PASSWORD:?Set LOCAL_ADMIN_PASSWORD in the environment}"
: "${WIN_IMAGE_NAME:=Windows Server 2025 SERVERDATACENTER}"
: "${TIMEZONE:=UTC}"

OUT_DIR="${SCRIPT_DIR}/build/${VM_NAME}"
mkdir -p "${OUT_DIR}"

export VM_NAME HOSTNAME IP_ADDRESS PREFIX_LENGTH GATEWAY DNS_SERVER DOMAIN_FQDN \
       DOMAIN_JOIN_USER DOMAIN_JOIN_PASS LOCAL_ADMIN_PASSWORD WIN_IMAGE_NAME TIMEZONE

envsubst < "${SCRIPT_DIR}/autounattend.xml.tmpl" > "${OUT_DIR}/autounattend.xml"

echo "[render] ${OUT_DIR}/autounattend.xml"
