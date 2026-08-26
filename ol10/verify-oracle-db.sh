#!/bin/bash
# verify-oracle-db.sh — Post-deployment checks for ora01
# Mirrors the phaseX-*-verify.ps1 pattern used elsewhere in this repo
# (dcs/phase3-ad01-verify.ps1, etc.) but for the Oracle Linux data-tier VM.
#
# Usage: ./verify-oracle-db.sh   (run on ora01 as huber)

set -uo pipefail

ORACLE_SID=ORCL
PDB_NAME=ORCLPDB
ORACLE_HOME=/u01/app/oracle/product/23ai/dbhome_1
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"

pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; ERRORS=$((ERRORS+1)); }
ERRORS=0

echo "========================================="
echo "  ora01 — Oracle AI Database 23ai checks"
echo "========================================="

echo ""
echo "--- OS / service prerequisites ---"
id oracle &>/dev/null && pass "oracle OS user exists" || fail "oracle OS user missing"
[ -d "$ORACLE_HOME" ] && pass "ORACLE_HOME present ($ORACLE_HOME)" || fail "ORACLE_HOME missing"
grep -q "^${ORACLE_SID}:${ORACLE_HOME}:Y" /etc/oratab 2>/dev/null \
  && pass "/etc/oratab entry correct" || fail "/etc/oratab entry missing/incorrect"
[ -f /etc/profile.d/oracle.sh ] && pass "System-wide ORACLE_HOME env (/etc/profile.d/oracle.sh) present" || fail "/etc/profile.d/oracle.sh missing"

echo ""
echo "--- systemd service ---"
if systemctl is-active --quiet oracle; then
  pass "oracle.service active"
else
  fail "oracle.service not active"
fi
systemctl is-enabled --quiet oracle && pass "oracle.service enabled at boot" || fail "oracle.service not enabled"

echo ""
echo "--- Listener ---"
if sudo -u oracle bash -lc "lsnrctl status" 2>/dev/null | grep -q "READY"; then
  pass "Listener READY on 1521"
else
  fail "Listener not responding"
fi

echo ""
echo "--- Database connectivity ---"
CDB_CHECK=$(sudo -u oracle bash -lc "sqlplus -s / as sysdba <<< 'select status from v\$instance;'" 2>/dev/null | grep -i OPEN)
[ -n "$CDB_CHECK" ] && pass "CDB $ORACLE_SID instance OPEN" || fail "CDB $ORACLE_SID not OPEN"

PDB_STATE=$(sudo -u oracle bash -lc "sqlplus -s / as sysdba <<< \"select open_mode from v\\\$pdbs where name='${PDB_NAME}';\"" 2>/dev/null | grep -i "READ WRITE")
[ -n "$PDB_STATE" ] && pass "PDB $PDB_NAME OPEN (READ WRITE)" || fail "PDB $PDB_NAME not open read-write"

echo ""
echo "--- Remote connectivity (TNS) ---"
if command -v tnsping &>/dev/null; then
  sudo -u oracle bash -lc "tnsping ${HOSTNAME_FQDN}:1521/${ORACLE_SID}" 2>/dev/null | grep -q "OK" \
    && pass "tnsping to CDB service OK" || fail "tnsping to CDB service failed"
fi

echo ""
echo "--- Firewall ---"
sudo firewall-cmd --list-ports 2>/dev/null | grep -q "1521/tcp" \
  && pass "1521/tcp open in firewalld" || fail "1521/tcp not open in firewalld"

echo ""
echo "--- Kernel / resource prerequisites (Phases 3-5) ---"
[ -f /etc/sysctl.d/97-oracle-db.conf ] && pass "sysctl 97-oracle-db.conf present" || fail "sysctl file missing"
[ -f /etc/security/limits.d/97-oracle-db.conf ] && pass "limits 97-oracle-db.conf present" || fail "limits file missing"
THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
echo "$THP" | grep -q "\[never\]" && pass "THP disabled ([never])" || fail "THP not disabled: $THP"

echo ""
echo "========================================="
if [ "$ERRORS" -eq 0 ]; then
  echo "✅ All checks passed."
else
  echo "❌ $ERRORS check(s) failed — see above."
fi
echo "========================================="

exit "$ERRORS"
