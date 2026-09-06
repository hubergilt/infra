# dhcp01 — Unattended Windows Server 2025 + DHCP Server VM

Same pattern as `dcs/create-ad01-vm.sh` and `msql25/create-sql01-vm.sh`:
one command builds a custom install ISO, boots a KVM/libvirt VM from it,
and the guest finishes the entire job itself — Windows Server install,
hostname/static IP, domain join, and a fully unattended DHCP Server role
install + scope configuration — with zero console interaction from start
to finish.

```
dhcp01/
├── README.md                          (this file)
├── create-dhcp01-vm.sh                # builds the ISO and launches the VM
├── dhcp01-autounattend.xml            # Windows Setup answer file (host: DHCP01)
└── phase3-dhcp01-unattended.ps1       # guest-side: join domain, install DHCP, configure scope
```

This lives alongside `dcs/` (the `ad01`/`ad02` domain-controller scripts),
`msql25/` (the `sql01` SQL Server VM), and `win25/` (Windows Server 2025
media + NetKVM drivers) at the repo root — `create-dhcp01-vm.sh` reaches
into `../win25/NetKVM` the same way `msql25/create-sql01-vm.sh` does.

## Topology (per `general-nw.puml` — Identity/PKI tier)

| Component | Hostname      | IP Address | Network                  | Role                                             | OS                        |
| --------- | ------------- | ---------- | ------------------------- | ------------------------------------------------- | -------------------------- |
| dhcp01    | dhcp01.ad.lab | 10.0.7.30  | lab-identity (10.0.7.0/24) | DHCP server — serves lab-clients via fw01 relay   | Windows Server 2025 Core   |

dhcp01 sits on the same segment as ad01/ad02 (co-located per the diagram's
note *"dhcp01 moved App/GW->Identity, co-located w/ AD/DNS"*) — it is
**not** on the network it serves. Leases go out to the **lab-clients**
segment (10.0.4.0/24) via fw01's DHCP relay (ip-helper), matching the
consolidated/segmented design rather than the older flat-LAN layout.

| Setting        | Value                          |
| -------------- | ------------------------------- |
| Domain (FQDN)  | ad.lab                          |
| NetBIOS name   | ADLAB                           |
| dhcp01 network | lab-identity — 10.0.7.30/24, gateway 10.0.7.1 |
| Served network | lab-clients — 10.0.4.0/24, gateway (router option) 10.0.4.1 |
| DNS servers    | 10.0.7.10 (ad01), 10.0.7.11 (ad02) |

**This folder is fully self-contained and fully unattended.** Running
`create-dhcp01-vm.sh` takes a blank VM all the way to a verified,
domain-joined, AD-authorized DHCP server with zero console interaction.
Nobody needs to log into the guest at any point.

## Prerequisites

- **`dcs/` Phase 3 complete** — ad01 and ad02 promoted and replicating.
  dhcp01 resolves and joins `ad.lab` directly against them; there is no
  Cloudflare-only bootstrap step like ad01's, since a live DC is assumed
  from first boot.
- The `lab-identity` libvirt network already defined (see `../nets/`).
- On the libvirt host:
  ```bash
  apt install p7zip-full genisoimage qemu-utils virtinst ovmf
  ```
- Windows Server 2025 install ISO — same media as
  `win25/create-win25-unnatend.sh` / `msql25/create-sql01-vm.sh`.
- NetKVM VirtIO drivers already present at `../win25/NetKVM/`.
- On the OPNsense firewall (fw01) — **outside the scope of this folder**:
  a DHCP relay (ip-helper) on the lab-clients interface pointing at
  `10.0.7.30`, so client01 and other lab-clients workstations can reach
  dhcp01 across the segment boundary.

### Before running

Edit `dhcp01-autounattend.xml` if your lab differs from the defaults
baked in:
- Static IP block (`10.0.7.30/24`, gateway `10.0.7.1`) and DNS
  (`10.0.7.10`, `10.0.7.11`) if dhcp01 doesn't belong on lab-identity in
  your environment.
- `ProductKey` / edition string, if not using the Standard Core GVLK this
  repo defaults to.

Edit the "site-specific settings" block at the top of
`phase3-dhcp01-unattended.ps1` if your scope differs:
- `$ScopeId` / `$ScopeStart` / `$ScopeEnd` / `$ScopeMask` / `$ScopeRouter`
  — defaults to lab-clients (10.0.4.0/24), pool 10.0.4.50–200, router
  10.0.4.1.
- `$ExclStart` / `$ExclEnd` — defaults to 10.0.4.1–49, reserved for
  statics/infrastructure on that segment.
- `$LeaseTime` — defaults to 8 hours (shorter than the Windows default of
  8 days, convenient for a lab).

## How it works

1. **`create-dhcp01-vm.sh`** extracts the Windows Server 2025 install
   ISO, drops in `dhcp01-autounattend.xml` as `autounattend.xml`, injects
   the NetKVM VirtIO network driver, and stages
   `phase3-dhcp01-unattended.ps1` into a `Provision\` folder at the ISO
   root (same `D:\Provision` approach as `dcs/create-ad01-vm.sh`).
2. It rebuilds a bootable ISO with `genisoimage` and launches the VM with
   `virt-install` on the `lab-identity` network, with `--wait 60` so the
   command itself babysits Windows Setup's install-time reboots (see
   `dcs/README.md` section 2.4 for why this matters).
3. Windows installs unattended from the answer file: partitions the disk,
   sets the `DHCP01` hostname and static IP `10.0.7.30/24`, enables
   OpenSSH + ICMP + EMS/SAC, and — at first logon — runs
   `phase3-dhcp01-unattended.ps1` exactly once (`FirstLogonCommands`).
4. **Stage 0** of that script checks connectivity to ad01, joins `ad.lab`
   unattended (`Add-Computer`), and reboots. A scheduled task
   (`Phase3-DHCP01-Continue`) re-arms itself across that reboot — and
   retries every 2 minutes if ad01 isn't reachable yet — so no manual
   intervention or rerun is needed either way.
5. **Stage 1**, resumed automatically after the reboot, installs the
   `DHCP` Windows feature, polls until the DHCP Server service is
   actually queryable (same class of post-install race condition as the
   DNS role in `dcs/phase3-ad0X-unattended.ps1`), configures the
   lab-clients scope (range, router/DNS/domain options, lease duration,
   exclusion range, DNS dynamic updates), authorizes dhcp01 in AD via
   `Add-DhcpServerInDC`, binds the DHCP server to its NIC, and verifies.
   The scheduled task then deletes itself.

## Running it

```bash
cd dhcp01/
./create-dhcp01-vm.sh
```

Watch it go:
```bash
virt-viewer dhcp01
virsh domstate dhcp01
```

Track progress from inside the guest:
```powershell
Get-Content C:\ProvisionState\dhcp01-unattended.log -Wait
Get-Content C:\ProvisionState\dhcp01.stage   # 0=joining domain, 1=installing DHCP, 2=verified
```

## Verifying

From dhcp01 itself, or remotely with `-ComputerName dhcp01.ad.lab`:
```powershell
Get-DhcpServerv4Scope
Get-DhcpServerv4OptionValue -ScopeId 10.0.4.0
Get-DhcpServerInDC
```

From ad01, confirm authorization is visible domain-wide:
```powershell
Get-DhcpServerInDC
```

Once fw01's ip-helper relay is configured, bring up client01 (or any
lab-clients workstation) and confirm it leases an address in the
10.0.4.50–200 range with gateway 10.0.4.1 and DNS 10.0.7.10/10.0.7.11:
```powershell
ipconfig /release
ipconfig /renew
ipconfig /all
```

Check active leases from dhcp01:
```powershell
Get-DhcpServerv4Lease -ScopeId 10.0.4.0 |
    Select-Object IPAddress, HostName, ClientId, LeaseExpiryTime
```

## Security notes

- `Get-DomainCredential` in `phase3-dhcp01-unattended.ps1` hardcodes the
  `ADLAB\Administrator` password for the unattended domain join — lab-only,
  matching this repo's existing convention (see
  `dcs/phase3-ad02-unattended.ps1`). Swap in the `Import-Clixml` option
  (commented in the same function) for anything beyond an isolated lab.
- The `Administrator` autologon/plaintext password in
  `dhcp01-autounattend.xml` is the same repo-wide lab default
  (`Server2012!`) used by `dcs/` and `msql25/` — rotate it, or generate it
  per-host, before reusing this outside a disposable lab.
- DHCP relay traffic (UDP 67/68) must be permitted from fw01 to dhcp01
  across the lab-identity/lab-clients boundary; this folder only
  configures the Windows side.

---
_dhcp01 — Phase 5 (Services tier), built from the dcs/ and msql25/ unattended patterns — September 2026_
