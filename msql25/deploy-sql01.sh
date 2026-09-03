#!/bin/bash
# deploy-sql01.sh — end-to-end remote orchestration for sql01 (Phase 7)
#
# Run this ON THE LIBVIRT HOST after:
#   1. create-sql01-unattend.sh has finished and Windows is at a login prompt
#   2. attach-sql-iso.sh has hot-attached SQLServer2025-x64-ENU-EntDev.iso
#
# It pushes phase7-sql01.ps1, phase7-sql01-verify.ps1 and
# ConfigurationFile.ini to sql01 over the OpenSSH server baked in by
# autounattend.xml, then runs the domain-join + unattended SQL install
# remotely. Domain-join needs an interactive credential prompt (by design —
# we don't want ADLAB\Administrator's password sitting in a script), so this
# script pauses once for that step, exactly like ad01/app01 do when run
# by hand.
#
# Usage:
#   ./deploy-sql01.sh

set -euo pipefail

SQL01_IP="10.0.6.70"
SSH_USER="Administrator"
REMOTE_DIR='C:\Deploy'
LOCAL_DIR="$(pwd)"

for f in phase7-sql01.ps1 phase7-sql01-verify.ps1 ConfigurationFile.ini; do
  [ -f "$LOCAL_DIR/$f" ] || { echo "ERROR: missing $LOCAL_DIR/$f"; exit 1; }
done

echo "[1/4] Waiting for sshd on sql01 ($SQL01_IP:22)..."
until nc -z -w2 "$SQL01_IP" 22 2>/dev/null; do
  sleep 5
  echo "   still waiting..."
done
echo "     sshd is up."

echo "[2/4] Creating $REMOTE_DIR and copying scripts..."
ssh "$SSH_USER@$SQL01_IP" "powershell -NonInteractive -Command \"New-Item -ItemType Directory -Force -Path '$REMOTE_DIR' | Out-Null\""
scp phase7-sql01.ps1 phase7-sql01-verify.ps1 ConfigurationFile.ini \
    "$SSH_USER@$SQL01_IP:$REMOTE_DIR/"
echo "     Files copied."

echo "[3/4] Running phase7-sql01.ps1 on sql01..."
echo "     NOTE: this will prompt for ADLAB\\Administrator's password during"
echo "     domain join, and the VM reboots twice (rename, then domain join)."
echo "     Re-run this step after each reboot until it reports completion."
ssh -t "$SSH_USER@$SQL01_IP" "powershell -NonInteractive -ExecutionPolicy Bypass -File '$REMOTE_DIR\\phase7-sql01.ps1'" || true

echo "[4/4] Running verification..."
ssh "$SSH_USER@$SQL01_IP" "powershell -NonInteractive -ExecutionPolicy Bypass -File '$REMOTE_DIR\\phase7-sql01-verify.ps1'"

echo ""
echo "Done. If phase7-sql01.ps1 rebooted the VM partway through (rename or"
echo "domain join), re-run this script — each step is idempotent and picks"
echo "up where it left off."
