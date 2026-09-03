#!/usr/bin/env bash
# Builds the answer-media ISO for one VM: autounattend.xml at the root
# (some ISO paths use it from the boot media instead, but we also carry it
# here for reference), plus postinstall/ and sql/ folders that specialize's
# RunSynchronousCommand xcopies onto C:\Windows\Setup\Scripts, plus a
# marker file so the guest can identify which CD-ROM this is.
#
# Usage: ./make-answer-iso.sh <vm_name>
# Requires SA_PASSWORD in the environment.
set -euo pipefail

VM_NAME="${1:?Usage: $0 <vm_name>}"
: "${SA_PASSWORD:?Set SA_PASSWORD in the environment before building the answer ISO}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STAGE_DIR="$(mktemp -d)"
trap 'shred -u "${STAGE_DIR}"/sql/credentials.ps1 2>/dev/null; rm -rf "${STAGE_DIR}"' EXIT

RENDERED_XML="${REPO_ROOT}/win25/build/${VM_NAME}/autounattend.xml"
if [[ ! -f "${RENDERED_XML}" ]]; then
  echo "ERROR: ${RENDERED_XML} not found — run win25/generate-autounattend.sh first." >&2
  exit 1
fi

mkdir -p "${STAGE_DIR}/postinstall" "${STAGE_DIR}/sql"
cp "${RENDERED_XML}" "${STAGE_DIR}/autounattend.xml"
cp "${SCRIPT_DIR}/postinstall/"*.ps1 "${SCRIPT_DIR}/postinstall/SetupComplete.cmd" "${STAGE_DIR}/postinstall/"
cp "${SCRIPT_DIR}/sql/ConfigurationFile.ini" "${STAGE_DIR}/sql/"
echo "answer-media for ${VM_NAME}" > "${STAGE_DIR}/ANSWER_MEDIA_MARKER.txt"

# SA password only ever lands on disk inside this throwaway staging dir,
# and only for the duration of genisoimage running against it.
cat > "${STAGE_DIR}/sql/credentials.ps1" <<EOF
\$SA_PASSWORD = '${SA_PASSWORD}'
EOF

OUT_DIR="${REPO_ROOT}/win25/build/${VM_NAME}"
OUT_ISO="${OUT_DIR}/answer-media.iso"

if command -v genisoimage >/dev/null 2>&1; then
  ISO_TOOL=genisoimage
elif command -v mkisofs >/dev/null 2>&1; then
  ISO_TOOL=mkisofs
else
  echo "ERROR: need genisoimage or mkisofs installed." >&2
  exit 1
fi

"${ISO_TOOL}" -o "${OUT_ISO}" -J -r -V "ANSWER_${VM_NAME}" "${STAGE_DIR}" >/dev/null

echo "[iso] built ${OUT_ISO}"
