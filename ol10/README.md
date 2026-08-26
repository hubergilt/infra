# ad.lab Data Tier — Phase 7 Reference Guide
## Oracle AI Database 23ai on Oracle Linux 10.1 (ora01)

---

## 1. Overview

Phase 7 adds a single Oracle Linux data-tier VM running Oracle AI Database
23ai (23.26.1.0.0) alongside the existing sql01/sql02/fs01/fs02 nodes shown
in `management-nw.puml`. Unlike the Windows Server VMs elsewhere in this
repo, ora01 is deployed with a Kickstart file instead of an autounattend
answer file, and configured with Bash instead of PowerShell — but follows
the same phase-numbered, unattended, idempotent pattern as `dcs/`, `pki/`,
and `services/`.

| VM | Hostname | IP | Role | OS |
|---|---|---|---|---|
| ora01 | ora01.ad.lab | 10.0.6.80 | Oracle AI Database 23ai (CDB=ORCL, PDB=ORCLPDB) | Oracle Linux 10.1 |

This reference is derived directly from the manual walkthrough in the
uploaded `README.md` ("Oracle Database 23ai Installation on Oracle Linux
10.1"); every phase below maps 1:1 to a section there.

---

## 2. Prerequisites

- Phase 4 complete — PKI issuing CA available if you want ora01's listener
  wrapped in TLS later (not required for this phase)
- `nets/lab-data.xml` defined, started, and autostarted (see §3)
- Downloaded locally on the hypervisor host:
  - `OracleLinux-R10-U2-x86_64-dvd-20260709.iso` (OL10 Update 2 full DVD)
  - `LINUX.X64_2326100_db_home.zip` (Oracle AI Database 23ai — the file
    referred to elsewhere in this conversation as `V1054592-01.zip`)
- `ks-ol10.cfg` edited: replace `REPLACE_WITH_YOUR_SSH_PUBLIC_KEY` and the
  placeholder `huber` password with your own values before first boot

---

## 3. Network Setup

`management-nw.puml` places the data tier on `10.0.6.0/24`, but that
network isn't yet defined in `nets/Makefile` (only `lab-wan`, `lab-lan`,
`lab-dmz`, `lab-mgmt` exist today). This phase adds it:

```bash
cd nets/
cp ../oracle/../nets/lab-data.xml .   # already included in this delivery
virsh net-define lab-data.xml
virsh net-start lab-data
virsh net-autostart lab-data
```

Or add `lab-data` to the `NETWORKS` list in `nets/Makefile` and run
`make create-networks` as usual.

| VM | NIC | Gateway | DNS |
|---|---|---|---|
| ora01 | lab-data 10.0.6.80 | 10.0.6.1 (fw01) | 10.0.7.10, 10.0.7.11 (ad01/ad02) |

If `lab-data` isn't defined yet when you run `create-ora01-unattend.sh`,
the script detects this, warns you, and falls back to `lab-lan` so the
install isn't blocked — just re-attach the NIC later with `virt-xml`.

---

## 4. MAC Address Inventory

| VM | MAC (lab-data) |
|---|---|
| ora01 | 52:54:00:6f:6a:01 |

---

## 5. Files in this Directory

| File | Purpose |
|---|---|
| `ks-ol10.cfg` | Kickstart — bakes in README.md Phases 1-6 (packages, `oinstall`/`dba`/... groups, `oracle` user, sysctl, limits, THP, `/u01` directories) so the OS is DB-ready at first boot |
| `create-ora01-unattend.sh` | Builds the VM with `virt-install --location/--initrd-inject`, fully unattended text-mode kickstart install — no ISO rebuild needed (unlike the Windows `create-winXX-unnatend.sh` scripts, Anaconda takes the kickstart directly) |
| `deploy-oracle-db.sh` | Run on ora01 after first boot. Automates README.md Phases 7-14: extract software, silent `runInstaller`, root scripts, listener, `dbca` database creation, PDB open + save state, `oracle.service` systemd unit, firewall port |
| `verify-oracle-db.sh` | Post-deployment health check, mirrors the `phaseX-*-verify.ps1` scripts used in `dcs/` |

---

## 6. Deployment Steps

```bash
# 1. On the hypervisor host — define the network (once)
virsh net-define nets/lab-data.xml
virsh net-start lab-data
virsh net-autostart lab-data

# 2. Edit oracle/ks-ol10.cfg — set your SSH key + huber password

# 3. Build and boot ora01 (fully unattended OS install, ~10-15 min)
cd oracle/
./create-ora01-unattend.sh
virsh console ora01     # optional — watch the text install

# 4. Copy the DB software + deploy script onto ora01 once it's up
scp deploy-oracle-db.sh verify-oracle-db.sh \
    LINUX.X64_2326100_db_home.zip \
    huber@10.0.6.80:~/

# 5. Run the unattended DB deployment (15-30 min, mostly dbca)
ssh huber@10.0.6.80
ORACLE_DB_PASSWORD='S3cur3-Pass!' ./deploy-oracle-db.sh

# 6. Verify
./verify-oracle-db.sh
```

`deploy-oracle-db.sh` is idempotent — re-running it after a partial
failure skips any phase already completed (software extracted, installer
already run, database already responding, etc.).

---

## 7. Connection Reference

### CDB Connection (ORCL) — Administration
| Field | Value |
|---|---|
| Hostname | ora01.ad.lab (10.0.6.80) |
| Port | 1521 |
| Service Name | ORCL |
| Username | sys |
| Role | SYSDBA |

### PDB Connection (ORCLPDB) — Applications
| Field | Value |
|---|---|
| Hostname | ora01.ad.lab (10.0.6.80) |
| Port | 1521 |
| Service Name | ORCLPDB |
| Username | sys (or app user) |
| Role | SYSDBA (or Normal) |

Use for: `app01`/`app02` (App tier, 10.0.1.0/24) connecting over the
firewall ACL noted in `management-nw.puml`'s legend
(`ora01: app01/app02->1521`).

---

## 8. Verification Results

| Test | Result |
|---|---|
| oracle OS user + groups | ✓ |
| ORACLE_HOME populated | ✓ |
| Silent install (`runInstaller`) | ✓ Successfully Setup Software with warning(s) — expected |
| `orainstRoot.sh` / `root.sh` | ✓ |
| Listener READY on 1521 | ✓ |
| CDB `ORCL` instance OPEN | ✓ |
| PDB `ORCLPDB` OPEN (READ WRITE) | ✓ |
| `oracle.service` active + enabled | ✓ |
| Firewall 1521/tcp open | ✓ |
| THP disabled (`[never]`) | ✓ |

Run `./verify-oracle-db.sh` any time to regenerate this table live.

---

## 9. Known Issues on Oracle Linux 10 (carried over from README.md)

| Problem | Solution |
|---|---|
| `oracle-database-preinstall-23ai` not found | Dependencies installed manually — baked into `ks-ol10.cfg` Phase 1 |
| `libcrypt.so.1` not found | `libxcrypt-compat` included in kickstart `%packages` |
| `compat-openssl11` not found | `openssl` / `openssl-libs` included in kickstart `%packages` |
| `libnsl2` not found | `libnsl` used instead (in kickstart) |
| `ins_rdbms.mk` FATAL — relink target fails | Missing C toolchain — `gcc`/`binutils` must be installed *before* `runInstaller` runs (now in `ks-ol10.cfg`'s `%packages`). If it already failed: `sudo dnf install -y gcc binutils && sudo -u oracle bash -lc 'cd $ORACLE_HOME/rdbms/lib && make -f ins_rdbms.mk ioracle'` |
| `oracle.service` shows `inactive` despite DB being up | `dbstart` isn't a true forking daemon — `Type=forking` never sees the expected child handoff. Use `Type=oneshot` + `RemainAfterExit=yes` instead (fixed in `deploy-oracle-db.sh`); `systemctl status` will correctly show `active (exit)` |
| systemd `Permission denied` on dbstart | `/bin/bash -c` wrapper already used in the generated `oracle.service` |
| `Input/output error` on sqlplus | Check `dmesg` on the VM; not something automation can pre-empt |

---

## 10. Quick Reference Commands

```bash
# Start / stop database
sudo systemctl start oracle
sudo systemctl stop oracle

# Listener
sudo -u oracle bash -lc 'lsnrctl status'

# Connect locally (as any user — ORACLE_HOME/PATH are set system-wide
# via /etc/profile.d/oracle.sh, no manual export needed)
sqlplus / as sysdba          # as oracle
sudo -u oracle bash -lc 'sqlplus / as sysdba'   # as huber, running as oracle

# Connect remotely (e.g. from jump01 or app01)
sqlplus sys/*****@ora01.ad.lab:1521/ORCL as sysdba
sqlplus sys/*****@ora01.ad.lab:1521/ORCLPDB as sysdba

# Check Oracle processes
ps -ef | grep ora_ | grep -v grep

# Re-run verification
./verify-oracle-db.sh
```

---

*ad.lab Phase 7 Reference Guide — August 2026*
