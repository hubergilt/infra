#!/bin/bash
# deploy-oracle-db.sh — Unattended Oracle AI Database 23ai install (Phases 7-14)
# Run this ON ora01 as huber (sudo-capable), after Phases 1-6 have been
# baked in by ks-ol10.cfg at first boot.
#
# Usage:
#   scp deploy-oracle-db.sh V1054592-01.zip huber@10.0.6.80:~/
#   ssh huber@10.0.6.80
#   ORACLE_DB_PASSWORD='S3cur3-Pass!' ./deploy-oracle-db.sh
#
# Idempotent: safe to re-run; already-completed phases are skipped.

set -euo pipefail
trap 'echo "❌ FAILED at line $LINENO. See /var/log/deploy-oracle-db.log"; exit 1' ERR

LOG=/var/log/deploy-oracle-db.log
exec > >(sudo tee -a "$LOG") 2>&1

# ── Config (matches README.md) ───────────────────────────────────
ORACLE_BASE=/u01/app/oracle
ORACLE_HOME=/u01/app/oracle/product/23ai/dbhome_1
ORA_INVENTORY=/u01/app/oraInventory
ORACLE_SID=ORCL
PDB_NAME=ORCLPDB
DB_ZIP="${DB_ZIP:-$HOME/LINUX.X64_2326100_db_home.zip}"
# Fallback: allow the /mnt/user-data style filename seen in this chat too
[ -f "$DB_ZIP" ] || DB_ZIP="$HOME/V1054592-01.zip"

ORACLE_DB_PASSWORD="${ORACLE_DB_PASSWORD:-}"
if [ -z "$ORACLE_DB_PASSWORD" ]; then
  read -rsp "Set SYS/SYSTEM/PDB admin password for $ORACLE_SID: " ORACLE_DB_PASSWORD
  echo
fi
[ -z "$ORACLE_DB_PASSWORD" ] && { echo "ERROR: password cannot be empty."; exit 1; }

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"

echo "=== deploy-oracle-db.sh started $(date) ==="
echo "ORACLE_HOME=$ORACLE_HOME  SID=$ORACLE_SID  PDB=$PDB_NAME  ZIP=$DB_ZIP"

[ -f "$DB_ZIP" ] || { echo "ERROR: install ZIP not found at $DB_ZIP (pass DB_ZIP=/path/to.zip)"; exit 1; }
id oracle &>/dev/null || { echo "ERROR: 'oracle' OS user missing — did Phase 2 (ks-ol10.cfg) run?"; exit 1; }
[ -d "$ORACLE_HOME" ] || { echo "ERROR: $ORACLE_HOME missing — did Phase 6 (ks-ol10.cfg) run?"; exit 1; }

# ── Phase 7 — Extract the installation ZIP (idempotent) ──────────
if [ ! -x "$ORACLE_HOME/runInstaller" ]; then
  echo "[Phase 7] Extracting install ZIP into ORACLE_HOME..."
  sudo cp "$DB_ZIP" "$ORACLE_HOME/"
  sudo chown oracle:oinstall "$ORACLE_HOME/$(basename "$DB_ZIP")"
  sudo -u oracle bash -c "cd '$ORACLE_HOME' && unzip -q '$(basename "$DB_ZIP")'"
  sudo -u oracle rm -f "$ORACLE_HOME/$(basename "$DB_ZIP")"
else
  echo "[Phase 7] Software already extracted, skipping."
fi

# ── Phase 8 — Oracle environment variables (idempotent) ──────────
ORACLE_PROFILE=/home/oracle/.bash_profile
if ! sudo grep -q "^export ORACLE_HOME=$ORACLE_HOME" "$ORACLE_PROFILE" 2>/dev/null; then
  echo "[Phase 8] Writing oracle env vars to $ORACLE_PROFILE..."
  sudo tee -a "$ORACLE_PROFILE" > /dev/null << EOF

export ORACLE_BASE=$ORACLE_BASE
export ORACLE_HOME=$ORACLE_HOME
export ORACLE_SID=$ORACLE_SID
export PATH=\$ORACLE_HOME/bin:\$PATH
export LD_LIBRARY_PATH=\$ORACLE_HOME/lib:/lib:/usr/lib
EOF
  sudo chown oracle:oinstall "$ORACLE_PROFILE"
else
  echo "[Phase 8] Env vars already present, skipping."
fi

# ── Phase 9 — Silent installer (idempotent) ───────────────────────
# Checked against $ORACLE_HOME/bin/oracle, not inventory.xml: OUI
# registers the inventory *before* the RDBMS link step runs, so a
# link failure (e.g. missing gcc/binutils) still leaves inventory.xml
# behind. bin/oracle only exists after a genuinely successful build.
if [ ! -x "$ORACLE_HOME/bin/oracle" ]; then
  if [ ! -f "$ORA_INVENTORY/ContentsXML/inventory.xml" ]; then
    echo "[Phase 9] Running silent installer (Set Up Software Only)..."
    sudo -u oracle bash -c "
      cd '$ORACLE_HOME'
      ./runInstaller -silent -ignorePrereqFailure \
        oracle.install.option=INSTALL_DB_SWONLY \
        UNIX_GROUP_NAME=oinstall \
        INVENTORY_LOCATION=$ORA_INVENTORY \
        ORACLE_HOME=$ORACLE_HOME \
        ORACLE_BASE=$ORACLE_BASE \
        oracle.install.db.InstallEdition=EE \
        oracle.install.db.OSDBA_GROUP=dba \
        oracle.install.db.OSOPER_GROUP=oper \
        oracle.install.db.OSBACKUPDBA_GROUP=backupdba \
        oracle.install.db.OSDGDBA_GROUP=dgdba \
        oracle.install.db.OSKMDBA_GROUP=kmdba \
        oracle.install.db.OSRACDBA_GROUP=racdba \
        SECURITY_UPDATES_VIA_MYORACLESUPPORT=false \
        DECLINE_SECURITY_UPDATES=true
    " || echo "  (non-zero exit expected — installer reports warnings as failures; verifying below)"
  else
    echo "[Phase 9] Inventory already registered from a prior attempt."
  fi

  # RDBMS binary still missing (either never ran, or the make step
  # failed, e.g. missing gcc/binutils) — relink directly rather than
  # re-running the full installer against an existing home.
  if [ ! -x "$ORACLE_HOME/bin/oracle" ]; then
    echo "[Phase 9] RDBMS binary missing — relinking (make -f ins_rdbms.mk ioracle)..."
    command -v gcc &>/dev/null && command -v ld &>/dev/null || {
      echo "ERROR: gcc/binutils not found — install them first: sudo dnf install -y gcc binutils"
      exit 1
    }
    sudo -u oracle bash -lc "cd '$ORACLE_HOME/rdbms/lib' && make -f ins_rdbms.mk ioracle"
  fi
else
  echo "[Phase 9] RDBMS binary already present, skipping."
fi

[ -x "$ORACLE_HOME/bin/oracle" ] || { echo "ERROR: $ORACLE_HOME/bin/oracle missing — RDBMS link failed. Check /tmp/InstallActions*/installActions*.log"; exit 1; }
[ -x "$ORACLE_HOME/bin/sqlplus" ] || { echo "ERROR: sqlplus missing — Phase 9 install did not complete."; exit 1; }

# ── Phase 10 — Root scripts (idempotent) ──────────────────────────
if [ ! -f "$ORA_INVENTORY/orainstRoot.sh.done" ]; then
  echo "[Phase 10] Running orainstRoot.sh..."
  sudo "$ORA_INVENTORY/orainstRoot.sh"
  sudo touch "$ORA_INVENTORY/orainstRoot.sh.done"
else
  echo "[Phase 10] orainstRoot.sh already run, skipping."
fi

if [ ! -f "$ORACLE_HOME/install/root_${HOSTNAME_FQDN}.done" ] && [ ! -f /etc/oratab ]; then
  echo "[Phase 10] Running root.sh..."
  sudo "$ORACLE_HOME/root.sh" <<< ""
  sudo mkdir -p "$ORACLE_HOME/install"
  sudo touch "$ORACLE_HOME/install/root_${HOSTNAME_FQDN}.done"
else
  echo "[Phase 10] root.sh already run (oratab exists), skipping."
fi

# ── Phase 11 — Listener + database creation (idempotent) ─────────
echo "[Phase 11] Starting listener..."
sudo -u oracle bash -lc "lsnrctl start" || sudo -u oracle bash -lc "lsnrctl status" | grep -q "$ORACLE_SID" \
  && echo "  Listener already running."

if ! sudo -u oracle bash -lc "sqlplus -s / as sysdba <<< 'select 1 from dual;'" | grep -q "^1$" 2>/dev/null; then
  echo "[Phase 11] Creating CDB '$ORACLE_SID' with PDB '$PDB_NAME' (15-30 min)..."
  sudo -u oracle bash -lc "
    dbca -silent -createDatabase \
      -templateName General_Purpose.dbc \
      -gdbname $ORACLE_SID \
      -sid $ORACLE_SID \
      -responseFile NO_VALUE \
      -characterSet AL32UTF8 \
      -sysPassword '$ORACLE_DB_PASSWORD' \
      -systemPassword '$ORACLE_DB_PASSWORD' \
      -createAsContainerDatabase true \
      -numberOfPDBs 1 \
      -pdbName $PDB_NAME \
      -pdbAdminPassword '$ORACLE_DB_PASSWORD' \
      -databaseType MULTIPURPOSE \
      -memoryMgmtType AUTO_SGA \
      -totalMemory 2048 \
      -storageType FS \
      -datafileDestination $ORACLE_BASE/oradata \
      -redoLogFileSize 50 \
      -emConfiguration NONE \
      -ignorePreReqs
  "
else
  echo "[Phase 11] Database already responding, skipping dbca."
fi

# ── Phase 12 — Open PDB and save state (idempotent) ───────────────
echo "[Phase 12] Ensuring PDB is open and state is saved..."
sudo -u oracle bash -lc "sqlplus -s / as sysdba" << SQL
STARTUP;
ALTER PLUGGABLE DATABASE $PDB_NAME OPEN;
ALTER PLUGGABLE DATABASE $PDB_NAME SAVE STATE;
SHOW PDBS;
EXIT
SQL

# ── Phase 13 — systemd auto-start (idempotent) ─────────────────────
if [ ! -f /etc/systemd/system/oracle.service ]; then
  echo "[Phase 13] Installing oracle.service..."
  sudo tee /etc/systemd/system/oracle.service > /dev/null << EOF
[Unit]
Description=Oracle Database 23ai
After=network.target

[Service]
Type=forking
User=oracle
Group=oinstall
Environment=ORACLE_BASE=$ORACLE_BASE
Environment=ORACLE_HOME=$ORACLE_HOME
Environment=ORACLE_SID=$ORACLE_SID
ExecStart=/bin/bash -c '$ORACLE_HOME/bin/dbstart $ORACLE_HOME'
ExecStop=/bin/bash -c '$ORACLE_HOME/bin/dbshut $ORACLE_HOME'
TimeoutSec=600

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now oracle
else
  echo "[Phase 13] oracle.service already installed, ensuring it's enabled/started."
  sudo systemctl enable --now oracle
fi

sudo sed -i "s|^${ORACLE_SID}:.*:N|${ORACLE_SID}:${ORACLE_HOME}:Y|" /etc/oratab

# ── Phase 14 — Firewall ───────────────────────────────────────────
if ! sudo firewall-cmd --list-ports | grep -q "1521/tcp"; then
  echo "[Phase 14] Opening firewall port 1521/tcp..."
  sudo firewall-cmd --permanent --add-port=1521/tcp
  sudo firewall-cmd --reload
else
  echo "[Phase 14] Port 1521/tcp already open, skipping."
fi

echo ""
echo "✅ Deployment complete: $(date)"
echo "   CDB : sqlplus sys/*****@${HOSTNAME_FQDN}:1521/${ORACLE_SID} as sysdba"
echo "   PDB : sqlplus sys/*****@${HOSTNAME_FQDN}:1521/${PDB_NAME} as sysdba"
echo "   Full log: $LOG"
echo "   Run ./verify-oracle-db.sh to confirm everything is healthy."
