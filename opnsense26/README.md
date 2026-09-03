# fw01 — OPNsense 26 Firewall

**fw01.ad.lab** is the perimeter and inter-segment firewall for the ad.lab KVM lab.
It runs OPNsense 26.1 on FreeBSD, managed as a libvirt VM (`qemu:///system`).

---

## Files in this folder

| File | Purpose |
|---|---|
| `create-opnsense26.sh` | Creates and launches the fw01 VM with a pre-loaded config disk |
| `config.xml` | Active OPNsense configuration (interfaces + firewall rules) |
| `config-default.xml` | Vanilla OPNsense defaults — baseline reference |
| `config-fw01.ad.lab-20260422155246.xml` | Snapshot backup taken 2026-04-22 |
| `opnsense_config.ini` | Human-readable network layout reference (not imported by OPNsense) |

---

## Network interfaces

fw01 has 8 NICs mapped to 8 libvirt networks. Interface order matches `virt-install` NIC order.

| OPNsense iface | vtnet | libvirt network | Bridge | IP | Subnet | Role |
|---|---|---|---|---|---|---|
| WAN | vtnet0 | lab-wan | virbr-wan | 10.0.0.2 | /30 | Point-to-point to host NAT |
| LAN (APP) | vtnet1 | lab-app | virbr-app | 10.0.1.1 | /24 | App tier — api_gw, dhcp01, app VMs |
| OPT1 (DMZ_WEB) | vtnet2 | lab-dmz-web | virbr-dmzweb | 10.0.2.1 | /24 | Public web — waf01, web01, lb01 |
| OPT2 (MGMT) | vtnet3 | lab-mgmt | virbr-mgmt | 10.0.3.1 | /24 | Control plane — jump01, SIEM |
| OPT3 (CLIENTS) | vtnet4 | lab-clients | virbr-clients | 10.0.4.1 | /24 | Workstations — DHCP relayed from dhcp01 |
| OPT4 (DMZ_VPN) | vtnet5 | lab-dmz-vpn | virbr-dmzvpn | 10.0.5.1 | /24 | Remote access — vpn01, rodc01 (VPN leg) |
| OPT5 (DATA) | vtnet6 | lab-data | virbr-data | 10.0.6.1 | /24 | Data tier — sql01, ora01, fs01, fs02 |
| OPT6 (IDENTITY) | vtnet7 | lab-identity | virbr-identity | 10.0.7.1 | /24 | Identity — ad01, ad02, ca01, ca02 |

The WAN gateway is `10.0.0.1` (host's `virbr-wan` bridge). The host masquerades fw01's traffic out to the home router via iptables NAT on the Wi-Fi interface.

---

## Firewall rules summary

All segments use **default-deny at the bottom** with explicit pass rules above. MGMT is the only fully permissive segment (admin plane).

### WAN (inbound from internet)

| Action | Proto | Destination | Port | Notes |
|---|---|---|---|---|
| pass | TCP | 10.0.2.12 (waf01) | 443 | HTTPS ingress |
| pass | TCP | 10.0.5.10 (vpn01) | 443 | SSL-VPN |
| pass | UDP | 10.0.5.10 (vpn01) | 500 | IKEv2 |
| pass | UDP | 10.0.5.10 (vpn01) | 4500 | IKEv2 NAT-T |
| **block** | any | any | — | default deny (logged) |

### DMZ_WEB → other segments

| Action | Proto | Destination | Port | Notes |
|---|---|---|---|---|
| pass | TCP | 10.0.1.41 (api_gw01) | 443, 8443 | Web tier → API gateway |
| pass | TCP | 10.0.1.43 (api_gw02) | 443, 8443 | Web tier → API gateway HA |
| pass | TCP | 10.0.7.21 (ca02) | 80 | CDP / OCSP for TLS cert validation |
| **block** | any | any | — | default deny (logged) |

### DMZ_VPN → other segments

| Action | Proto | Destination | Notes |
|---|---|---|---|
| pass | any | 10.0.4.0/24 (CLIENTS) | Post-auth VPN client traffic |
| pass | any | 10.0.1.0/24 (APP) | Post-auth VPN client traffic |
| **block** | any | any | default deny (logged) |

> vpn01 is single-armed (DMZ_VPN NIC only). fw01 routes decrypted VPN client traffic into the appropriate segment. DMZ_VPN cannot reach DMZ_WEB.

### APP → other segments

| Action | Proto | Destination | Port | Notes |
|---|---|---|---|---|
| pass | TCP | 10.0.6.70 (sql01) | 1433 | SQL Server |
| pass | TCP | 10.0.6.80 (ora01) | 1521 | Oracle SQL*Net |
| pass | TCP | 10.0.6.31 (fs01) | 445 | SMB |
| pass | TCP | 10.0.6.32 (fs02) | 445 | SMB |
| pass | TCP/UDP | 10.0.7.0/24 (IDENTITY) | 88 | Kerberos |
| pass | TCP | 10.0.7.0/24 (IDENTITY) | 389 | LDAP |
| pass | TCP | 10.0.7.0/24 (IDENTITY) | 445 | SMB / Netlogon |
| pass | TCP | 10.0.7.0/24 (IDENTITY) | 636 | LDAPS |
| pass | TCP | 10.0.7.0/24 (IDENTITY) | 3268–3269 | Global Catalog |
| pass | UDP | 10.0.1.30 (dhcp01) | 67–68 | DHCP |
| **block** | any | any | — | default deny (logged) |

### CLIENTS → other segments

| Action | Proto | Destination | Port | Notes |
|---|---|---|---|---|
| pass | TCP | 10.0.1.0/24 (APP) | 443, 8443 | Client → app/api |
| pass | UDP | 10.0.1.30 (dhcp01) | 67–68 | DHCP relay |
| **block** | any | any | — | default deny (logged) |

### DATA, IDENTITY

Both segments are **default deny with no outbound pass rules** — all connections are initiated inbound from APP or MGMT. Servers in these segments do not open outbound connections to other segments.

### MGMT

Full pass to any destination — jump01 and management tools need unrestricted access for administration.

---

## Creating fw01 from scratch

### Prerequisites

```bash
sudo apt install virtinst qemu-utils mtools dosfstools
```

All libvirt networks must exist and be active before running the script:

```bash
cd ../nets
make create-networks   # creates all 8 networks
make verify            # confirms IPs are correct
```

### Run the installer

```bash
cd opnsense26
./create-opnsense26.sh
```

The script:
1. Destroys any existing `fw01` VM and disk
2. Creates a fresh 20 GB qcow2 disk at `/vms/fw01.qcow2`
3. Builds a 64 MB FAT32 raw image at `/vms/fw01-config.img` containing `conf/config.xml`
4. Launches fw01 with the OPNsense ISO as boot device and the config disk as USB

### Config importer prompt

Watch the console immediately after boot:

```bash
virt-viewer fw01
# or
virsh console fw01
```

When you see:

```
Press any key to start the configuration importer
```

Press any key and enter the config disk device — usually `da0` or `da1`. A successful import shows:

```
Configuration loaded
```

OPNsense then boots into the live environment with interfaces already assigned. Log in as `installer / opnsense` and complete the disk installation normally.

### Adding new NICs after initial install

If you add new libvirt networks (e.g. expanding from 4 to 8 segments):

```bash
# Shut down fw01
sudo virsh shutdown fw01

# Attach new NICs in order
sudo virsh attach-interface fw01 network lab-clients  --model virtio --config
sudo virsh attach-interface fw01 network lab-dmz-vpn  --model virtio --config
sudo virsh attach-interface fw01 network lab-data     --model virtio --config
sudo virsh attach-interface fw01 network lab-identity --model virtio --config

sudo virsh start fw01
```

Then in OPNsense: **Interfaces → Assignments** to map the new `vtnetX` devices, and **Interfaces → [name] → Edit** to set the IPs from the table above.

---

## Restoring config.xml

To apply a new or updated `config.xml` without reinstalling:

**Method 1 — WebGUI** (preferred)

```
System → Configuration → Backups → Restore
```

Upload `config.xml` and reboot.

**Method 2 — Console shell**

```bash
virsh console fw01
# Option 8 → Shell
cp /mnt/conf/config.xml /conf/config.xml    # if config disk still attached
# or scp from host:
scp config.xml root@10.0.3.1:/conf/config.xml
/usr/local/etc/rc.reload_all
```

---

## Static IP assignments

### APP (10.0.1.0/24)

| IP | Hostname | Role |
|---|---|---|
| 10.0.1.1 | fw01 | Firewall gateway |
| 10.0.1.10 | ad01.ad.lab | Primary DC / DNS1 |
| 10.0.1.11 | ad02.ad.lab | Replica DC |
| 10.0.1.20 | ca01.ad.lab | Offline Root CA |
| 10.0.1.21 | ca02.ad.lab | Issuing CA (ADCS) |
| 10.0.1.30 | dhcp01.ad.lab | DHCP server |
| 10.0.1.31 | fs01.ad.lab | File server / DNS2 |
| 10.0.1.40 | app01.ad.lab | IIS app server |
| 10.0.1.41 | api_gw01.ad.lab | API gateway |
| 10.0.1.43 | api_gw02.ad.lab | API gateway (HA) |
| 10.0.1.50–200 | — | DHCP pool |

### DMZ_WEB (10.0.2.0/24)

| IP | Hostname | Role |
|---|---|---|
| 10.0.2.1 | fw01 | Firewall gateway |
| 10.0.2.10 | lb01.ad.lab | Load balancer |
| 10.0.2.11 | web01.ad.lab | IIS web server |
| 10.0.2.12 | waf01.ad.lab | Reverse proxy / WAF (ARR) |
| 10.0.2.15 | rodc01-dmzweb.ad.lab | RODC (DMZ-Web leg) |

### MGMT (10.0.3.0/24)

| IP | Hostname | Role |
|---|---|---|
| 10.0.3.1 | fw01 | Firewall gateway |
| 10.0.3.10 | jump01 (MGMT NIC) | Bastion host |
| 10.0.3.20 | siem01.ad.lab | SIEM / log collector |
| 10.0.3.30 | sccm01.ad.lab | SCCM / patch management |
| 10.0.3.40 | backup01.ad.lab | Backup server |
| 10.0.3.254 | — | virbr-mgmt host bridge |

### CLIENTS (10.0.4.0/24)

| IP | Hostname | Role |
|---|---|---|
| 10.0.4.1 | fw01 | Firewall gateway / DHCP relay |
| 10.0.4.50–200 | — | DHCP pool (served by dhcp01 via relay) |

### DMZ_VPN (10.0.5.0/24)

| IP | Hostname | Role |
|---|---|---|
| 10.0.5.1 | fw01 | Firewall gateway |
| 10.0.5.10 | vpn01.ad.lab | VPN gateway (RRAS / IKEv2) |
| 10.0.5.15 | rodc01-dmzvpn.ad.lab | RODC (DMZ-VPN leg) |

### DATA (10.0.6.0/24)

| IP | Hostname | Role |
|---|---|---|
| 10.0.6.1 | fw01 | Firewall gateway |
| 10.0.6.31 | fs01.ad.lab | File server (data NIC) |
| 10.0.6.32 | fs02.ad.lab | File server replica |
| 10.0.6.70 | sql01.ad.lab | SQL Server |
| 10.0.6.80 | ora01.ad.lab | Oracle DB |

### IDENTITY (10.0.7.0/24)

| IP | Hostname | Role |
|---|---|---|
| 10.0.7.1 | fw01 | Firewall gateway |
| 10.0.7.10 | ad01 (IDENTITY NIC) | Primary DC |
| 10.0.7.11 | ad02 (IDENTITY NIC) | Replica DC |
| 10.0.7.20 | ca01.ad.lab | Offline Root CA |
| 10.0.7.21 | ca02.ad.lab | Issuing CA |

---

## Common operations

### Check fw01 status

```bash
sudo virsh dominfo fw01
sudo virsh domiflist fw01
```

### Console access

```bash
sudo virsh console fw01
# Escape: Ctrl+]
```

### Reboot fw01

```bash
# From OPNsense console → option 6
# Or from host:
sudo virsh reboot fw01
```

### Verify internet from fw01

```bash
# From fw01 shell (console option 8):
fetch -o - http://example.com
# or
ping -c 3 8.8.8.8
```

If ping fails but fetch works, the home router is blocking forwarded ICMP — internet connectivity is still functional.

### Backup running config

```bash
# From host — pull via scp over MGMT interface
scp root@10.0.3.1:/conf/config.xml \
    config-fw01.ad.lab-$(date +%Y%m%d%H%M%S).xml
```

---

## Host NAT setup (required for internet)

fw01's WAN traffic exits via the host's Wi-Fi interface. These iptables rules must survive reboots (saved by `iptables-persistent`):

```bash
# Masquerade fw01 WAN traffic out through Wi-Fi
sudo iptables -t nat -I POSTROUTING 1 \
  -s 10.0.0.0/30 -o wlxd03745b49f87 -p icmp -j MASQUERADE

# Forward rules before libvirt chains
sudo iptables -I FORWARD 1 -i virbr-wan -o wlxd03745b49f87 -j ACCEPT
sudo iptables -I FORWARD 2 -i wlxd03745b49f87 -o virbr-wan \
  -m state --state RELATED,ESTABLISHED -j ACCEPT

# Persist
sudo netfilter-persistent save
```

> The Wi-Fi interface name `wlxd03745b49f87` is specific to this host. Verify with `ip link show`.

---

*ad.lab fw01 Reference — OPNsense 26 — August 2026*
