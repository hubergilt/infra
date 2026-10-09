# fs01 / fs02 — Unattended Windows Server 2025 File Servers (Data Tier)

## Active/Standby File Server, Fully Unattended

---

## 1. Overview

This builds the two file server VMs called out in the Data tier of
`general-nw.puml` — fs01 (active) and fs02 (standby) — and configures
the actual file-server *service* on top: domain join, the File Server +
DFS roles, SMB shares, and a DFS Namespace + DFS Replication pair so
clients always resolve `\\ad.lab\Files` regardless of which node is up.

Same overall pattern as `../dcs/` (ad01/ad02) and `../msql25/` (sql01):
one command per VM builds a custom install ISO, boots a KVM/libvirt VM
from it, and the guest finishes the entire job itself — Windows Server
install, hostname/static IP, domain join, role install, shares, and DFS
— with zero console interaction from start to finish.

| Component | Hostname     | IP Address  | Role                              | OS                          |
|-----------|--------------|-------------|-------------------------------------|------------------------------|
| fs01      | fs01.ad.lab  | 10.0.6.31   | Active file server, DFS-N/DFS-R primary   | Windows Server 2025 Core |
| fs02      | fs02.ad.lab  | 10.0.6.32   | Standby file server, DFS-N/DFS-R secondary | Windows Server 2025 Core |

| Setting       | Value                        |
|---------------|------------------------------|
| Domain (FQDN) | ad.lab                       |
| NetBIOS name  | ADLAB                        |
| Network       | lab-data (10.0.6.0/24)       |
| Gateway       | 10.0.6.1 (fw01, Data leg)    |
| DNS           | 10.0.7.10, 10.0.7.11 (ad01/ad02) |
| DFS Namespace | `\\ad.lab\Files` -> `\\FS01\Data` (active) + `\\FS02\Data` (standby) |
| DFS-R group   | `FS01-FS02-Data`, fs01 = primary member |

```
fs/
├── README.md                        (this file)
├── create-fs01-vm.sh                 # builds fs01's ISO and launches the VM
├── create-fs02-vm.sh                 # builds fs02's ISO and launches the VM
├── fs01-autounattend.xml             # Windows Setup answer file (host: FS01)
├── fs02-autounattend.xml             # Windows Setup answer file (host: FS02)
├── phase3-fs01-unattended.ps1        # guest-side: join domain, FS role, shares, DFS-N (active)
└── phase3-fs02-unattended.ps1        # guest-side: join domain, FS role, shares, DFS-N (standby) + DFS-R
```

This folder is self-contained the same way `dcs/` and `msql25/` are —
the answer files are local copies (not references to `../win25/`),
with hostname and static IP baked directly in. Only the NetKVM driver
folder is still pulled from `../win25/NetKVM`.

### 1.1 Quickstart

```
On the libvirt host, from inside fs/:

  1. One-time check (Section 4):
     - Windows Server 2025 ISO present at the path hardcoded in each
       create-fs0X-vm.sh
     - ../win25/NetKVM/ contains the VirtIO drivers
     - lab-data libvirt network already defined
     - Phase 3 (dcs/) complete — ad01 and ad02 promoted and replicating
     - apt install p7zip-full genisoimage qemu-utils virtinst ovmf

  2. ./create-fs01-vm.sh
     Builds the ISO and launches fs01. Blocks for up to 60 minutes
     (--wait 60) while virt-install babysits Windows Setup's own
     install-time reboots (see dcs/README.md section 2.4 for why).
     Once it returns, fs01 is past OS install and running its
     provisioning chain unattended in the background: format data
     disk -> join ad.lab (reboot) -> File Server/DFS roles -> shares
     -> publish \\ad.lab\Files as the active target.

     Watch it with:  virt-viewer fs01
     Or tail it with: Get-Content C:\ProvisionState\fs01-unattended.log -Wait

     Wait for:  Get-Content C:\ProvisionState\fs01.stage  ->  3

  3. ./create-fs02-vm.sh
     Can be run immediately after Step 2 — fs02 just retries every
     2 minutes until fs01's DFS-N root is reachable, no need to wait
     for Step 2 to finish first. Once both are up, fs02 adds itself as
     the standby DFS-N target and creates the fs01<->fs02 DFS
     Replication group for the Data share.

     Wait for:  Get-Content C:\ProvisionState\fs02.stage  ->  3

  4. Verify (Section 8), e.g. from either node or a domain-joined client:
       Get-DfsnRootTarget -Path '\\ad.lab\Files'
       dfsrdiag replicationstate /member:FS02
       Test-Path '\\ad.lab\Files\'
```

---

## 2. VM Creation

| Script               | Answer file (local)     | Base ISO             | VM name | os-variant | OS disk | Data disk | RAM    | vCPUs |
|----------------------|--------------------------|------------------------|---------|------------|---------|-----------|--------|-------|
| `create-fs01-vm.sh`  | `fs01-autounattend.xml`  | Windows Server 2025    | fs01    | win2k22    | 50 GB   | 100 GB    | 4096 MB | 2     |
| `create-fs02-vm.sh`  | `fs02-autounattend.xml`  | Windows Server 2025    | fs02    | win2k22    | 50 GB   | 100 GB    | 4096 MB | 2     |

`os-variant win2k22` is intentional — matches the convention already
used in `msql25/create-sql01-vm.sh` and `win25/create-win25-unnatend.sh`
for Server 2025 builds, since a dedicated `win2k25` libosinfo entry
isn't assumed to be present on the libvirt host.

Requirements: `p7zip-full`, `genisoimage`, `qemu-utils`, `virtinst`, `ovmf`.

```bash
apt install p7zip-full genisoimage qemu-utils virtinst ovmf
```

### 2.1 What the answer files bake in

`fs01-autounattend.xml` / `fs02-autounattend.xml` are forks of
`../msql25/sql01-autounattend.xml` with these differences:

1. `ComputerName` is `FS01` / `FS02` directly — no `Rename-Computer` +
   reboot needed afterward.
2. The static IP is `10.0.6.31/24` / `10.0.6.32/24` on `lab-data`,
   gateway `10.0.6.1` (fw01's Data leg, per `general-nw.puml`). DNS
   search order is `10.0.7.10`, `10.0.7.11` (ad01/ad02) on both — fs01
   is **not** a DNS server in this topology (unlike an older lab-lan
   design some of this repo's `services/` docs still describe); it
   only needs to resolve `ad.lab` to join the domain.
3. `DiskConfiguration` only touches `DiskID 0` (the OS disk). The
   second virtio disk that `create-fs0X-vm.sh` attaches for share data
   is deliberately left alone here — `phase3-fs0X-unattended.ps1`
   initializes and formats it as `D:` on first run (Stage 0).
4. `FirstLogonCommands` gains the same two extra steps used by `dcs/`
   and `msql25/`: copy `D:\Provision\phase3-fs0X-unattended.ps1` (or,
   here, the `$OEM$`-staged copy — see 2.2) to `C:\Provision\`, then
   launch it once with `powershell.exe -File`. That single launch is
   enough — the script re-arms itself via a scheduled task across the
   domain-join reboot.

### 2.2 create-fs01-vm.sh / create-fs02-vm.sh

Same shape as `msql25/create-sql01-vm.sh`: extract ISO, inject the
answer file as `autounattend.xml`, copy the NetKVM driver in, then
stage the phase 3 script into `sources\$OEM$\$1\Provision\` (Windows
Setup copies `$OEM$` content straight to `C:\Provision`, so no CD-ROM
lookup is needed for it — unlike `msql25`, there's no second product
ISO to attach here). Two virtio disks are created per VM: the 50 GB OS
disk and a 100 GB data disk that becomes `D:\Shares\...`. See each
script for the full `virt-install` invocation, including the
`--wait 60` rationale (documented in `dcs/README.md` section 2.4).

### 2.3 Run order

`create-fs02-vm.sh` does not have to wait for `create-fs01-vm.sh` to
finish — `phase3-fs02-unattended.ps1` polls for fs01's DFS-N root every
2 minutes and only proceeds once it exists (same non-blocking-run-order
pattern as `create-ad02-vm.sh` waiting on ad01). It's still cleanest to
run `create-fs01-vm.sh` first and let it reach `fs01.stage 3` before
kicking off `fs02`, since fs02's Stage 2 depends on fs01 having already
published `\\ad.lab\Files`.

---

## 3. Guest-Side Provisioning (`phase3-fs0X-unattended.ps1`)

Both scripts use the same reboot-persistent, staged pattern as
`dcs/phase3-ad02-unattended.ps1`: a state file
(`C:\ProvisionState\fs0X.stage`) tracks progress, and a scheduled task
(`Phase3-FS0X-Continue`) re-launches the script at every startup and on
a 2-minute repeating timer until it's done — no manual reboot or rerun
required. The task deletes itself once verification succeeds.

| Stage | fs01 (active)                                                      | fs02 (standby)                                                                          |
|-------|---------------------------------------------------------------------|-------------------------------------------------------------------------------------------|
| 0     | Format data disk as `D:`, wait for ad01, join `ad.lab`, reboot.     | Same.                                                                                      |
| 1     | Install `FS-FileServer`, `FS-DFS-Namespace`, `FS-DFS-Replication`, `FS-Resource-Manager`; create `D:\Shares\{Data,Profiles,Software}`; NTFS + SMB permissions (`ADLAB\Domain Admins` = Full, `ADLAB\Domain Users` = Modify, ABE enabled). | Same. |
| 2     | Create `\\ad.lab\Files` DFS-N root -> `\\FS01\Data`; set fs01's own target to `GlobalHigh` referral priority (active). | Wait for fs01's DFS-N root to exist; add `\\FS02\Data` as a `GlobalLow`-priority target (standby); create the `FS01-FS02-Data` DFS Replication group (fs01 = primary member) covering the `Data` share. |
| 3     | Verify shares + DFS-N root; unregister the continue task.           | Verify shares, DFS-N target, and replication group state; unregister the continue task.    |

### 3.1 Why fs01 sets priority in Stage 2 but fs02 does the DFS-R setup

Referral priority only needs to be set once per target and each node
only ever touches its own target, so there's no ordering conflict
there. DFS Replication group creation (`New-DfsReplicationGroup`,
`Add-DfsrMember`, `Set-DfsrMembership`, `Add-DfsrConnection`), though,
only needs to run once for the pair — it's done from fs02's script
specifically because fs02 already has to wait for fs01 to exist and be
domain-joined before it can reference `FS01` as a replication member,
so that's the natural place to also stand up the replication group
between them.

### 3.2 Active/standby behavior

- **Namespace referrals**: clients resolving `\\ad.lab\Files` get
  referred to `\\FS01\Data` first (`GlobalHigh`); `\\FS02\Data`
  (`GlobalLow`) is only offered if fs01's target is unreachable/offline.
- **Content replication**: DFS Replication keeps `D:\Shares\Data` in
  sync between the two nodes so fs02 has current content if a failover
  happens. Initial replication can take a few minutes to converge after
  the group is created (AD polling interval) — check with
  `dfsrdiag replicationstate /member:FS02`.
- **Failover is not automatic service failover** — this is
  namespace-level redirection plus content replication, not a
  clustered file server. If fs01 goes down, new client connections
  through the namespace path fail over to fs02; anything already
  connected via a direct UNC path to `\\FS01\...` does not.
- **Profiles/Software shares are not replicated** — only `Data` is in
  the DFS Replication group in this setup. Add `Profiles`/`Software`
  as additional replicated folders in the same group if you want them
  covered too (`New-DfsReplicatedFolder -GroupName FS01-FS02-Data
  -FolderName Profiles ...`).

### 3.3 Credential handling

Both scripts hardcode the `ADLAB\Administrator` password for
`Add-Computer`, matching this repo's existing lab-only convention (see
`dcs/phase3-ad02-unattended.ps1`). For anything beyond an isolated lab,
swap `Get-DomainCredential` for an `Import-Clixml` credential exported
once via `Export-Clixml` under the same account/host — the function is
already structured with that alternative commented in.

---

## 4. Prerequisites

- Phase 3 complete — ad01 and ad02 (`../dcs/`) promoted and replicating.
- Windows Server 2025 install ISO at the path hardcoded in each
  `create-fs0X-vm.sh` (same media as `../msql25/create-sql01-vm.sh`).
- NetKVM VirtIO drivers already present at `../win25/NetKVM/`.
- A libvirt network named `lab-data` (10.0.6.0/24, gateway 10.0.6.1 per
  `general-nw.puml`; matches `../nets/lab-data.xml`).
- `apt install p7zip-full genisoimage qemu-utils virtinst ovmf`

---

## 5. Before Running

- Confirm the `ORIG_ISO` path in both `create-fs0X-vm.sh` matches your
  downloaded Windows Server 2025 media.
- Confirm `../win25/NetKVM/` is populated (VirtIO NetKVM driver for
  Server 2022/2025, since libosinfo has no dedicated 2025 entry yet).
- If your lab's `ADLAB\Administrator` password differs from
  `Server2012!` (the value already baked into `../dcs/` and
  `../msql25/`), update it in both `fs0X-autounattend.xml`
  (`AutoLogon`/`AdministratorPassword`) and both
  `phase3-fs0X-unattended.ps1` (`Get-DomainCredential`).

---

## 6. Running It

```bash
cd fs/
./create-fs01-vm.sh
# wait for fs01.stage -> 3, or just kick off fs02 right away —
# it retries until fs01 is ready:
./create-fs02-vm.sh
```

Watch either VM:
```bash
virt-viewer fs01
virsh domstate fs01
```

Track guest-side progress:
```powershell
Get-Content C:\ProvisionState\fs01-unattended.log -Wait
Get-Content C:\ProvisionState\fs01.stage
# 0=join domain, 1=FS role+shares, 2=DFS-N/DFS-R, 3=verified
```

---

## 7. SMB Shares (both nodes)

```
\\FS01\Data      D:\Shares\Data      General data — DFS-R replicated with fs02
\\FS01\Profiles  D:\Shares\Profiles  Roaming profiles
\\FS01\Software  D:\Shares\Software  Software distribution

\\FS02\Data      D:\Shares\Data      General data — DFS-R replicated with fs01
\\FS02\Profiles  D:\Shares\Profiles  Roaming profiles
\\FS02\Software  D:\Shares\Software  Software distribution
```

Permissions: `ADLAB\Domain Admins` = Full, `ADLAB\Domain Users` =
Modify, Access-Based Enumeration enabled.

Clients should use the namespace path, not either node directly:
```
\\ad.lab\Files
```

---

## 8. Verification

| Test                                    | Command                                                    |
|-------------------------------------------|-------------------------------------------------------------|
| fs01/fs02 domain-joined                   | `Get-ADComputer FS01`, `Get-ADComputer FS02` (from ad01)     |
| File Server role installed                | `Get-WindowsFeature FS-FileServer` (on each node)            |
| Shares present                            | `Get-SmbShare` (on each node)                                |
| DFS-N root exists                         | `Get-DfsnRoot -Path '\\ad.lab\Files'`                        |
| Both targets registered, priority correct | `Get-DfsnFolderTarget -Path '\\ad.lab\Files'`                |
| DFS-R group healthy                       | `Get-DfsReplicationGroup -GroupName FS01-FS02-Data`          |
| Replication converged                     | `dfsrdiag replicationstate /member:FS02`                     |
| Namespace reachable from a client         | `Test-Path '\\ad.lab\Files\'`                                |

---

## 9. Quick Reference

### Key commands

| Command                                                | Run on        | Purpose                              |
|----------------------------------------------------------|---------------|----------------------------------------|
| `Get-DfsnRootTarget -Path '\\ad.lab\Files'`               | fs01 or fs02  | List namespace targets + priority      |
| `Get-DfsReplicationGroup -GroupName FS01-FS02-Data`       | fs01 or fs02  | Replication group info                 |
| `dfsrdiag replicationstate /member:FS02`                  | fs02          | Check replication backlog/state        |
| `Get-DfsrState -ComputerName FS01,FS02`                   | either        | Current DFS-R connection state         |
| `Get-Content C:\ProvisionState\fs0*.stage`                | fs01/fs02     | Check unattended-flow progress         |
| `Get-Content C:\ProvisionState\fs0*-unattended.log -Wait` | fs01/fs02     | Tail the unattended-flow transcript    |
| `Get-ScheduledTask Phase3-FS0*-Continue`                  | fs01/fs02     | Check unattended-flow task status      |

### Important file locations

**On the libvirt host (this folder):**

| Path                              | Contents                                                        |
|-------------------------------------|--------------------------------------------------------------------|
| `fs01-autounattend.xml`             | Custom answer file for fs01 (hostname, IP baked in)                |
| `fs02-autounattend.xml`             | Custom answer file for fs02 (hostname, IP baked in)                |
| `phase3-fs01-unattended.ps1`        | Active-node provisioning script, staged onto fs01's install media  |
| `phase3-fs02-unattended.ps1`        | Standby-node provisioning script, staged onto fs02's install media |
| `create-fs01-vm.sh`                 | Builds fs01's unattended ISO and launches the VM                   |
| `create-fs02-vm.sh`                 | Builds fs02's unattended ISO and launches the VM                   |

**On each guest:**

| Path                                     | VM         | Contents                                          |
|---------------------------------------------|------------|------------------------------------------------------|
| `C:\Provision\phase3-fs0X-unattended.ps1`   | fs01, fs02 | Copy of the provisioning script staged from install media |
| `D:\Shares\{Data,Profiles,Software}`        | fs01, fs02 | Share content (Data replicated via DFS-R)          |
| `C:\ProvisionState\fs0*.stage`              | fs01, fs02 | Unattended-flow progress marker                     |
| `C:\ProvisionState\fs0*-unattended.log`     | fs01, fs02 | Transcript of the unattended run                    |
| `C:\ProvisionState\fs0X-cred.xml` (optional)| fs01, fs02 | DPAPI-encrypted domain credential (3.3, option B)   |

---

_fs01/fs02 Data-Tier File Server Reference Guide — September 2026_
