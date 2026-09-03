#!/bin/bash
# attach-sql-iso.sh
# Hot-attaches the SQL Server 2025 installation media to sql01 as a second
# CD-ROM, once Windows has finished OOBE and is sitting at a login prompt.
# Windows setup media is still on the first (sata) CD-ROM at that point, so
# this ISO shows up as the next drive letter — phase7-sql01.ps1 detects it
# by looking for setup.exe rather than assuming a fixed letter.
#
# Usage:
#   ./attach-sql-iso.sh sql01

set -e

VM_NAME="${1:-sql01}"
SQL_ISO="${SQL_ISO:-/home/huber/Downloads/SQLServer2025-x64-ENU-EntDev.iso}"

[ -f "$SQL_ISO" ] || {
  echo "ERROR: SQL Server ISO not found: $SQL_ISO"
  echo "  Pass a different path: SQL_ISO=/path/to.iso ./attach-sql-iso.sh $VM_NAME"
  exit 1
}

virsh domstate "$VM_NAME" 2>/dev/null | grep -q running || {
  echo "ERROR: $VM_NAME is not running. Start it first (virsh start $VM_NAME)."
  exit 1
}

echo "Attaching $SQL_ISO to $VM_NAME as sdc (cdrom, live + persistent)..."
virsh attach-disk "$VM_NAME" "$SQL_ISO" sdc \
  --type cdrom --mode readonly --sourcetype file \
  --config --live

echo "Done. Inside the guest the SQL media will appear as a new optical drive."
echo "phase7-sql01.ps1 locates it automatically (looks for setup.exe)."
