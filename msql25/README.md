# sql01 — Unattended Windows Server + SQL Server 2025 VM

Same pattern as `create-ad01-vm.sh`: one command builds a custom install
ISO, boots a KVM/libvirt VM from it, and the guest finishes the entire
job itself — Windows Server install, hostname/static IP, and a fully
unattended SQL Server 2025 (Enterprise Developer/Eval) install — with
zero console interaction from start to finish.

```
dcs/
├── README.md                        (this file)
├── create-sql01-vm.sh                # builds the ISO and launches the VM
├── sql01-autounattend.xml            # Windows Setup answer file (host: SQL01)
├── phase3-sql01-unattended.ps1       # guest-side: finds SQL media, installs, verifies
└── ConfigurationFile.ini             # SQL Server setup.exe answer file
```

## How it works

1. **`create-sql01-vm.sh`** extracts the Windows Server install ISO,
   drops in `sql01-autounattend.xml` as `autounattend.xml`, injects the
   NetKVM VirtIO network driver, and stages `phase3-sql01-unattended.ps1`
   + `ConfigurationFile.ini` into `sources\$OEM$\$1\Provision\` — Windows
   Setup copies `$OEM$` content straight to `C:\Provision` on the guest,
   so no CD-ROM lookup is needed for these two files.
2. It rebuilds a bootable ISO with `genisoimage` and launches the VM with
   `virt-install`, attaching **two** CD-ROMs: the custom Windows install
   ISO (boots Setup) and the **untouched** `SQLServer2025-x64-ENU-EntDev.iso`
   (read later by the guest — not merged into the Windows ISO, since
   WinPE never needs it and it's ~6GB).
3. Windows installs unattended from the answer file: partitions the disk,
   sets the `SQL01` hostname and a static IP, enables RDP, and — at first
   logon — runs `phase3-sql01-unattended.ps1` exactly once
   (`FirstLogonCommands`).
4. That script finds the SQL Server CD-ROM (by looking for
   `x64\setup.exe`, which distinguishes it from the Windows install media),
   generates a random `sa` password, and runs:
   ```
   setup.exe /ConfigurationFile=C:\Provision\ConfigurationFile.ini /SAPWD=... /IACCEPTSQLSERVERLICENSETERMS
   ```
5. It checks the exit code, reboots if setup requests one (exit `3010`),
   and verifies the instance with `sqlcmd -Q "SELECT @@VERSION;"`.

## Prerequisites

On the KVM/libvirt host (same as `create-ad01-vm.sh`):
```bash
apt install p7zip-full genisoimage qemu-utils virtinst ovmf
```
- Windows Server install ISO (2019 by default, matching the ad01 script;
  swap in 2022/2025 media in `create-sql01-vm.sh` if you'd rather run
  SQL Server on newer Windows).
- SQL Server 2025 install ISO. This repo assumes:
  `/home/huber/Downloads/SQLServer2025-x64-ENU-EntDev.iso`
- NetKVM VirtIO drivers already present at `../win19/NetKVM/` (same
  driver folder `create-ad01-vm.sh` uses).
- A libvirt network named `lab-identity` (or update `NETWORK` in the
  script if SQL01 belongs on a different segment in your environment).

## Before running

Edit `sql01-autounattend.xml` and replace:
- `CHANGE_ME_EDITION_NAME` — exact edition string from your media
  (`Get-WindowsImage -ImagePath D:\sources\install.wim` on a mounted copy).
- `CHANGE_ME_ORG`, `CHANGE_ME_PRODUCT_KEY`, `CHANGE_ME_ADMIN_PASSWORD`.
- The static IP block (`10.0.7.20/24`, gateway `10.0.7.1`) and DNS
  (`10.0.7.10`, i.e. ad01) if SQL01 doesn't belong on that network/DNS
  server in your lab.

Edit `ConfigurationFile.ini` if you need different:
- `FEATURES` (defaults to `SQLENGINE,CONN,BC`).
- `SQLSYSADMINACCOUNTS` — replace `BUILTIN\Administrators` with a
  specific admin account/group before using this anywhere but a lab.
- Data/log/tempdb paths (defaults assume a `D:` data drive exists —
  add a second virtio disk in `create-sql01-vm.sh` and format it as `D:`
  in `phase3-sql01-unattended.ps1` if you want dedicated data disks
  rather than everything on `C:`).

## Running it

```bash
cd dcs/
./create-sql01-vm.sh
```

Watch it go:
```bash
virt-viewer sql01
virsh domstate sql01
```

Once Windows Setup finishes and the guest is provisioning SQL Server,
track progress from inside the guest:
```powershell
Get-Content C:\ProvisionState\sql01-unattended.log -Wait
Get-Content C:\ProvisionState\sql01.stage   # 0=installing SQL, 1=installed, 2=verified
```

## Getting the sa password

The `sa` password is generated randomly at provisioning time — it is
never hard-coded in this repo. Retrieve it from inside the guest:
```powershell
Get-Content C:\ProvisionState\sql01-sa-password.txt
```
That file is ACL'd to `Administrators`/`SYSTEM` only. Rotate it after
first login if this instance isn't purely a disposable lab VM.

## Verifying

```powershell
Get-Service MSSQLSERVER, SQLSERVERAGENT
sqlcmd -S SQL01 -U sa -P '<password from sql01-sa-password.txt>' -Q "SELECT @@VERSION;"
```

## Security notes

- No SQL Server or Windows Administrator password is committed to this
  repo — `ConfigurationFile.ini` never contains `SAPWD`, and every
  password placeholder in `sql01-autounattend.xml` is a `CHANGE_ME_*`
  value you fill in locally (keep a populated copy out of git, or use
  Setup's base64-obfuscated `PlainText=false` form, which is obscurity
  rather than encryption).
- `BUILTIN\Administrators` is granted SQL sysadmin by default — fine for
  a lab, not for production; narrow `SQLSYSADMINACCOUNTS` before reuse.
- TCP 1433 is opened in the guest firewall automatically; tighten the
  scope (source IP restriction, or remove entirely and use SSH/RDP
  tunneling) if SQL01 is reachable from anything beyond the lab network.
