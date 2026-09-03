# ad.lab Data Tier — Phase 7 Reference Guide
## SQL Server Implementation (sql01)

Built from `general-nw.puml` (consolidated, segmented topology) — the Data
tier is its own subnet, 10.0.6.0/24, separate from the App/Gateway tier that
earlier phases used.

---

## 1. Overview

Phase 7 deploys the single-instance SQL Server host defined in the
Data group of the diagram.

| VM | Hostname | IP | Role | OS |
|---|---|---|---|---|
| sql01 | sql01.ad.lab | 10.0.6.70 | SQL Server 2025 — single instance | Win Server 2025 Core |

Per the diagram's legend, this design intentionally has **no sql01 replica**
("removed per requirements") — this is a single point of failure by design,
not an oversight. Plan backups accordingly (`backup01`, 10.0.3.22, MGMT-only).

---

## 2. Prerequisites

- `lab-data` network defined and started: `make create-network-lab-data` (from `nets/`)
- Phase 3 complete — ad01/ad02 promoted and replicating (now at 10.0.7.10/.11
  per the corrected Identity tier addressing, not the 10.0.1.x used in
  earlier phases)
- Phase 4 complete — ca02 issuing certs (only needed here if you later add
  Force Encryption / TLS to the SQL endpoint)
- Windows Server 2025 ISO and `SQLServer2025-x64-ENU-EntDev.iso` present on
  the libvirt host (see paths in `create-sql01-unattend.sh` / `attach-sql-iso.sh`)
- `virt-install`, `genisoimage`, `p7zip-full`, `qemu-utils`, `ovmf` on the host

### ⚠️ Firewall ACL gap not in the original diagram

The nwdiag's ACL matrix defines `App->Data:1433/445` and `App->AD:389/88/445`,
but **no Data→Identity rule**. sql01 needs to reach ad01/ad02 for DNS and
Kerberos to join the domain at all. Add this on fw01 before running Phase 7:

```
Pass  Data net (10.0.6.0/24) -> Identity net (10.0.7.10, 10.0.7.11)  TCP/UDP 53,88,389,445
```

This is the same kind of gap the diagram already calls out for backup
(no offsite copy) and ora01 (no standby) — treat it as one more documented
correction rather than a silent assumption.

---

## 3. VM network config

| VM | NIC | Gateway | DNS |
|---|---|---|---|
| sql01 | lab-data 10.0.6.70/24 | 10.0.6.1 (fw01 Data leg) | 10.0.7.10, 10.0.7.11 (ad01, ad02) |

Disks:

| Disk | Bus | Size | Purpose |
|---|---|---|---|
| sql01.qcow2 | sata | 60G | OS (C:) |
| sql01-data.qcow2 | virtio | 100G | SQL data/log/tempdb/backup (F:), formatted by phase7-sql01.ps1 |

---

## 4. MAC address inventory

Fill this in after first boot — data tier has no DHCP, so unlike the LAN
tier there's no reservation table to keep in sync, but it's still useful
for asset tracking:

```bash
virsh domiflist sql01
```

| VM | MAC (lab-data) |
|---|---|
| sql01 | *(fill in after `virsh domiflist sql01`)* |

---

## 5. Deployment steps

```bash
cd sql01/

# 1. Build the Windows Server 2025 VM (unattended, static IP baked in)
./create-sql01-unattend.sh

# 2. Watch it install, wait for the login prompt
virt-viewer sql01

# 3. Hot-attach the SQL Server media
./attach-sql-iso.sh sql01

# 4. Push scripts over ssh and run the unattended SQL install
#    (prompts once for ADLAB\Administrator during domain join;
#     re-run after each reboot — every step is idempotent)
./deploy-sql01.sh
```

Manual/console alternative to step 4, run directly on sql01 (matches the
pattern used by ad01/app01 in earlier phases):

```powershell
# Copy ConfigurationFile.ini, phase7-sql01.ps1, phase7-sql01-verify.ps1
# to C:\Deploy first (scp, shared folder, or RDP clipboard), then:
cd C:\Deploy
.\phase7-sql01.ps1
.\phase7-sql01-verify.ps1
```

---

## 6. SQL Server configuration

```
Instance:      MSSQLSERVER (default)
Features:      Database Engine only
Auth mode:     Windows/Kerberos only (matches app01/web01 — no SQL logins)
Sysadmins:     ADLAB\Administrator, BUILTIN\Administrators
Service acct:  NT SERVICE\MSSQLSERVER (virtual account — no domain
               credential to rotate; upgrade to a gMSA if you later need
               cross-server Kerberos delegation, e.g. linked servers)
TCP port:      1433, statically pinned (installer only turns TCP on;
               phase7-sql01.ps1 fixes the port via SMO WMI afterwards)
Data paths:    F:\SQLData, F:\SQLLogs, F:\SQLTempDB, F:\SQLBackup
               (dedicated virtio disk, kept off the OS disk on purpose)
```

### Fix a stuck/duplicate TCP binding

If step 6 of `phase7-sql01.ps1` warns that it couldn't set the port (e.g. the
`SqlServer` PowerShell module isn't present), set it by hand:

```powershell
Import-Module SqlServer
$wmi = New-Object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer
$tcp = $wmi.ServerInstances['MSSQLSERVER'].ServerProtocols['Tcp']
$tcp.IsEnabled = $true
$tcp.IPAddresses['IPAll'].IPAddressProperties['TcpDynamicPorts'].Value = ''
$tcp.IPAddresses['IPAll'].IPAddressProperties['TcpPort'].Value = '1433'
$tcp.Alter()
Restart-Service MSSQLSERVER
```

### Test from app01 (App/Gateway tier)

```powershell
Test-NetConnection sql01.ad.lab -Port 1433
sqlcmd -S sql01.ad.lab -E -Q "SELECT @@VERSION"
```

This only works once the Data→Identity ACL gap above is closed and fw01 has
an `App -> sql01:1433` rule, per the diagram's `App->Data:1433/445` entry.

---

## 7. Verification checklist

| Test | Command |
|---|---|
| Domain joined | `Get-WmiObject Win32_ComputerSystem \| Select Domain` |
| DNS -> ad01/ad02 | `Get-DnsClientServerAddress` |
| MSSQLSERVER running | `Get-Service MSSQLSERVER` |
| TCP 1433 listening | `Test-NetConnection localhost -Port 1433` |
| Firewall rule present | `Get-NetFirewallRule -DisplayName 'SQL Server TCP 1433'` |
| Data files on F:\ | `sqlcmd -S localhost -E -Q "SELECT physical_name FROM sys.master_files"` |
| Reachable from app01 | `Test-NetConnection sql01.ad.lab -Port 1433` (from app01, after ACL fix) |

Run all of these in one shot with `phase7-sql01-verify.ps1`.

---

## 8. Known gaps carried over from the diagram

- **No replica for sql01** — by design, per the legend ("removed per
  requirements"). Rely on `backup01` (10.0.3.22) for recovery; note the
  diagram also flags that backup has **no offsite/DR copy** yet.
- **Data→Identity ACL not in the original matrix** — added above; needed
  for domain join and ongoing Kerberos auth, not just first boot.
- **fw01/vpn01/waf01/lb01 have no HA** — doesn't block Phase 7, but means a
  single fw01 failure takes the Data tier's only route to AD with it.

---

*ad.lab Phase 7 Reference Guide — August 2026*
