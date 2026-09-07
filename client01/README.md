# client01 — Unattended Windows 11 Pro Domain-Joined Workstation

Same pattern as `dcs/create-ad01-vm.sh` and `dhcp/create-dhcp01-vm.sh`: one
command builds a custom install ISO, boots a KVM/libvirt VM from it, and
the guest finishes the entire job itself — Windows 11 install, hostname/
static IP, and a fully unattended domain join to `ad.lab` — with zero
console interaction from start to finish.

```
clients/
├── README.md                              (this file)
├── create-client01-vm.sh                  # builds the ISO and launches the VM
├── client01-autounattend.xml              # Windows Setup answer file (host: CLIENT01)
└── phase3-client01-unattended.ps1         # guest-side: join domain, verify
```

This lives alongside `dcs/`, `dhcp/`, `msql25/` (the other Phase 3/5 host
folders) and `win11/` (the golden Windows 11 media + NetKVM drivers +
standalone workgroup template this was forked from) at the repo root —
`create-client01-vm.sh` reaches into `../win11/NetKVM` the same way
`dhcp/create-dhcp01-vm.sh` reaches into `../win25/NetKVM`.

## Topology (per `general-nw.puml` — Clients tier)

| Component | Hostname       | IP Address | Network                  | Role                          | OS              |
| --------- | -------------- | ---------- | ------------------------- | ------------------------------ | --------------- |
| client01  | client01.ad.lab | 10.0.4.10 | lab-clients (10.0.4.0/24) | Domain-joined workstation      | Windows 11 Pro  |

client01 is the one statically-addressed, named workstation on
lab-clients — the diagram gives it a fixed address like every other host
in the topology, and `.10` falls neatly inside the static-reserved band
(`10.0.4.1`–`10.0.4.49`) already carved out of dhcp01's own scope for
this purpose (see `dhcp/README.md`). Everything else that shows up on
lab-clients is expected to pull a dynamic lease from dhcp01 via fw01's
relay instead.

| Setting          | Value                              |
| ----------------- | ----------------------------------- |
| Domain (FQDN)     | ad.lab                              |
| NetBIOS name      | ADLAB                               |
| client01 network  | lab-clients — 10.0.4.10/24, gateway 10.0.4.1 |
| DNS servers       | 10.0.7.10 (ad01), 10.0.7.11 (ad02)  |

**This folder is fully self-contained and fully unattended.** Running
`create-client01-vm.sh` takes a blank VM all the way to a verified,
domain-joined workstation with zero console interaction. Nobody needs to
log into the guest at any point.

## Prerequisites

- **`dcs/` Phase 3 complete** — ad01 and ad02 promoted and replicating.
  client01 resolves and joins `ad.lab` directly against them.
- The `lab-clients` libvirt network already defined (see `../nets/`).
- On the libvirt host:
  ```bash
  apt install p7zip-full genisoimage qemu-utils virtinst ovmf
  ```
- Windows 11 install ISO — same media as `win11/create-win11-unnatend.sh`.
- NetKVM VirtIO drivers already present at `../win11/NetKVM/`.

### Before running

Edit `client01-autounattend.xml` if your lab differs from the defaults
baked in:
- Static IP block (`10.0.4.10/24`, gateway `10.0.4.1`) and DNS
  (`10.0.7.10`, `10.0.7.11`) if client01 doesn't belong on lab-clients in
  your environment, or if `.10` collides with something else statically
  addressed on that segment.
- The local `huber` admin account / password, and the `Administrator`
  autologon password — same repo-wide lab default as everywhere else
  (`Server2012!`); rotate before reusing outside a disposable lab.

Edit the "site-specific settings" block at the top of
`phase3-client01-unattended.ps1` if your domain differs (`$DomainName`,
`$DomainNbName`, `$AdDcIp`).

## How it works

1. **`create-client01-vm.sh`** extracts the Windows 11 install ISO, drops
   in `client01-autounattend.xml` as `autounattend.xml`, injects the
   NetKVM VirtIO network driver, and stages
   `phase3-client01-unattended.ps1` into a `Provision\` folder at the ISO
   root (same `D:\Provision` approach as `dcs/` and `dhcp/` — not the
   `$OEM$` approach in `msql25/`, which has a latent path inconsistency).
2. It rebuilds a bootable ISO with `genisoimage` and launches the VM with
   `virt-install --wait 60` on the `lab-clients` network, so the command
   itself babysits Windows Setup's install-time reboots (see
   `dcs/README.md` section 2.4).
3. Windows installs unattended: TPM/SecureBoot/RAM/CPU checks bypassed
   (`LabConfig` registry keys), disk partitioned, hostname `CLIENT01` and
   static IP `10.0.4.10/24` set, local `huber` admin account created, RDP
   and OpenSSH enabled — and at first logon, runs
   `phase3-client01-unattended.ps1` exactly once (`FirstLogonCommands`).
4. **Stage 0** checks connectivity to ad01, re-binds DNS defensively
   before attempting the join (belt-and-suspenders — see the script's own
   comments on why), joins `ad.lab` unattended (`Add-Computer -Credential`),
   and reboots. A scheduled task (`Phase3-Client01-Continue`) re-arms
   itself across that reboot — and retries every 2 minutes if ad01 isn't
   reachable yet — so no manual intervention or rerun is needed either way.
5. **Stage 1**, resumed automatically after the reboot, verifies domain
   membership and logs success. The scheduled task then deletes itself.

Unlike `dcs/` and `dhcp/`, this script never needs the CredSSP/double-hop
workaround those two required — `Add-Computer` takes a `-Credential`
parameter natively and authenticates directly with it, unlike
`Get/Add-DhcpServerInDC`, which have none and always run under whatever
token launched the script.

## Running it

```bash
cd clients/
./create-client01-vm.sh
```

Watch it go:
```bash
virt-viewer client01
virsh domstate client01
```

Track progress from inside the guest:
```powershell
Get-Content C:\ProvisionState\client01-unattended.log -Wait
Get-Content C:\ProvisionState\client01.stage   # 0=joining domain, 1=verifying, 2=verified
```

## Verifying

From client01 itself:
```powershell
Get-WmiObject Win32_ComputerSystem | Select-Object Name, Domain, PartOfDomain
```

From ad01 or ad02, confirm the computer object landed in AD:
```powershell
Get-ADComputer CLIENT01
```

## Security notes

- `Get-DomainCredential` in `phase3-client01-unattended.ps1` hardcodes the
  `ADLAB\Administrator` password for the unattended domain join — lab-only,
  matching this repo's existing convention (see
  `dcs/phase3-ad02-unattended.ps1`). Swap in the `Import-Clixml` option
  (commented in the same function) for anything beyond an isolated lab.
- The `Administrator`/`huber` account passwords in `client01-autounattend.xml`
  are the same repo-wide lab defaults used elsewhere — rotate them before
  reusing this outside a disposable lab.

---
_client01 — Clients tier, built from the dcs/, dhcp/, and win11/ unattended patterns — September 2026_
