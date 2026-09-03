# Unattended Windows Server 2025 + SQL Server 2025 Deployment
### For the `data` tier (sql01 / sql02) of the libvirt lab in `general-nw.puml`

This pipeline builds two domain-joined, unattended Windows Server 2025 VMs
(`sql01`, `sql02`) on the **Data** network (`10.0.6.0/24`), then silently
installs SQL Server 2025 on each. It's designed to sit in the same repo
layout as `hubergilt/infra` (`nets/`, `win25/`, `scripts/`).

> **Note on `hubergilt/infra`:** GitHub blocks automated crawling of that
> repo's file tree from here, so I could not read the actual scripts inside
> `win25/`, `dcs/`, `nets/`, etc. — only the top-level README (generic
> libvirt/virt-install guide). Everything below is built directly from your
> `general-nw.puml` topology and standard `virt-install` / Sysprep /
> SQL Server silent-install practice. If your existing `nets/*.xml` or
> `win25/*` files use different naming, adjust the variables at the top of
> each script — nothing here is hardcoded beyond those variable blocks.

## Topology assumptions taken from the diagram

| Item | Value | Source |
|---|---|---|
| Network | `data`, `10.0.6.0/24`, gateway `10.0.6.1` (fw01) | nwdiag `network data` |
| sql01 | `10.0.6.70` — SQL primary (R/W) | nwdiag |
| sql02 | `10.0.6.71` — SQL replica (standby) | nwdiag |
| DNS / Domain | `ad01` = `10.0.7.10`, domain `ad.lab` | nwdiag legend + identity network |
| Gateway | fw01 routes `App->Data:1433/445` only | nwdiag ACL matrix |

Because `data` is a firewall-routed segment (not NAT'd by libvirt) and hosts
get **static IPs**, the libvirt network is defined as an isolated bridge —
fw01's own VM is expected to already have a leg on this same bridge from
your existing OPNsense build (`opnsense26/` in the reference repo).

## Prerequisites (you supply these — not included here)

1. A Windows Server 2025 evaluation ISO (Microsoft eval center).
2. The VirtIO Windows driver ISO (`virtio-win.iso`) — needed so Windows
   setup can see the virtio disk/NIC during install.
3. Your SQL Server 2025 ISO — you already have it:
   `~/Downloads/SQLServer2025-x64-ENU-EntDev.iso`
4. A domain-join account for `ad.lab` with rights to join computers to the
   `Data` OU (or wherever you want these landing).
5. `libvirt`, `virt-install`, `genisoimage` (or `mkisofs`) on the KVM host.

## Pipeline

```
nets/data-network.xml         libvirt network def for 10.0.6.0/24 (isolated bridge)
nets/setup-networks.sh        idempotently defines + starts it

win25/vars/sql01.env          per-VM variables (name, IP, RAM, vcpus, disks...)
win25/vars/sql02.env
win25/autounattend.xml.tmpl   single templated answer file for both VMs
win25/generate-autounattend.sh   renders the template with envsubst -> per-VM XML

scripts/make-answer-iso.sh    packs the rendered autounattend.xml + postinstall/
                               scripts into a small ISO (attached as a 2nd CDROM)
scripts/deploy-vm.sh          virt-install wrapper: OS ISO + virtio ISO +
                               answer ISO + SQL ISO, all unattended, no console
scripts/postinstall/*.ps1     run automatically at first logon (SetupComplete.cmd):
                               static IP -> domain join -> SQL Server silent
                               install -> firewall + config
scripts/sql/ConfigurationFile.ini   silent SQL Server 2025 setup config
scripts/ag/Setup-AlwaysOn.ps1 optional: wires sql01/sql02 as an Always On AG
                               (matches "replica standby" in the diagram)

deploy-all.sh                 orchestrates everything for both VMs
```

## Usage

```bash
export WIN_ISO=/path/to/WinServer2025_EVAL.iso
export VIRTIO_ISO=/path/to/virtio-win.iso
export SQL_ISO=~/Downloads/SQLServer2025-x64-ENU-EntDev.iso
export DOMAIN_JOIN_USER='AD\svc-join'
export DOMAIN_JOIN_PASS='ChangeMe!'   # see security note below
export SA_PASSWORD='ChangeMe!Str0ng'
export LOCAL_ADMIN_PASSWORD='ChangeMe!Str0ng'

cd infra-deploy
./deploy-all.sh
```

This will:
1. Define/start the `data` libvirt network (safe to re-run).
2. Render `autounattend.xml` for sql01 and sql02 from the template.
3. Build a small answer-file ISO for each.
4. `virt-install` each VM fully unattended (no VNC console needed, but one
   is opened for you to watch if you want).
5. Windows installs silently, sets the static IP, joins `ad.lab`, then
   `SetupComplete.cmd` triggers the SQL Server 2025 silent install and
   firewall rule for TCP 1433.
6. (Optional) run `scripts/ag/Setup-AlwaysOn.ps1` from a management host
   once both nodes are up, to configure sql01 as primary / sql02 as
   secondary replica.

## Security notes

- `autounattend.xml` contains the local admin and domain-join passwords in
  plaintext, which is normal for Sysprep/WDS-style deployments but **not**
  safe to leave lying around. `make-answer-iso.sh` builds the ISO into a
  throwaway temp dir and the top-level `deploy-all.sh` shreds it after the
  install ISO is attached. For anything beyond a lab, switch to
  `PlainText=false` + Sysprep-encoded passwords, or drop the password out
  of the answer file entirely and inject it via libvirt's QEMU guest agent
  / cloud-init-like `oem-drivers` channel instead.
- `SA_PASSWORD` / `DOMAIN_JOIN_PASS` are read from environment variables
  only — nothing is committed to the rendered XML or ini files as a
  hardcoded default.
