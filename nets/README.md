# nets — Libvirt Network Definitions

Libvirt virtual network definitions for the **fw01.ad.lab** KVM lab.
All networks are isolated segments routed through **fw01** (OPNsense 26).
No VM has direct internet access except through fw01's firewall rules.

---

## Network layout

```
Internet
    │
    │ (home router 192.168.18.1)
    │
 wlxd03745b49f87 (host Wi-Fi — 192.168.18.23)
    │  ← iptables MASQUERADE (host NAT)
    │
 virbr-wan  10.0.0.1/30          ← lab-wan
    │
 fw01  10.0.0.2/30  (vtnet0)
    ├── vtnet1  10.0.1.1/24   virbr-app       ← lab-app
    ├── vtnet2  10.0.2.1/24   virbr-dmzweb    ← lab-dmz-web
    ├── vtnet3  10.0.3.1/24   virbr-mgmt      ← lab-mgmt
    ├── vtnet4  10.0.4.1/24   virbr-clients   ← lab-clients
    ├── vtnet5  10.0.5.1/24   virbr-dmzvpn    ← lab-dmz-vpn
    ├── vtnet6  10.0.6.1/24   virbr-data      ← lab-data
    └── vtnet7  10.0.7.1/24   virbr-identity  ← lab-identity
```

---

## Networks

### lab-wan — `10.0.0.0/30`

Point-to-point link between fw01 and the host hypervisor bridge.
The host side (`10.0.0.1`) masquerades fw01's traffic out through the Wi-Fi interface.
This is the **only** network with `<forward mode='nat'>` — all others are isolated.

| | |
|---|---|
| Bridge | `virbr-wan` |
| Host IP | `10.0.0.1` |
| fw01 WAN IP | `10.0.0.2` |
| Mode | NAT (forward to host Wi-Fi) |

---

### lab-app — `10.0.1.0/24`

Application tier. Holds the API gateways, app servers, shared services (DHCP, file, CA).
fw01 is the gateway at `10.0.1.1`. DHCP scope `.50–.200` served by dhcp01 (`10.0.1.30`).

| | |
|---|---|
| Bridge | `virbr-app` |
| Host bridge IP | `10.0.1.254` |
| fw01 APP IP | `10.0.1.1` |
| Mode | Isolated (no NAT) |
| DHCP | Served by `dhcp01` (10.0.1.30) |

Static assignments:

| IP | Host | Role |
|---|---|---|
| 10.0.1.1 | fw01 | Gateway |
| 10.0.1.10 | ad01.ad.lab | Primary DC / DNS1 (APP NIC) |
| 10.0.1.11 | ad02.ad.lab | Replica DC (APP NIC) |
| 10.0.1.20 | ca01.ad.lab | Offline Root CA |
| 10.0.1.21 | ca02.ad.lab | Issuing CA / ADCS |
| 10.0.1.30 | dhcp01.ad.lab | DHCP server |
| 10.0.1.31 | fs01.ad.lab | File server |
| 10.0.1.32 | fs02.ad.lab | File server replica |
| 10.0.1.40 | app01.ad.lab | IIS app server |
| 10.0.1.41 | api_gw01.ad.lab | API gateway |
| 10.0.1.43 | api_gw02.ad.lab | API gateway (HA) |
| 10.0.1.50–200 | — | DHCP pool |

---

### lab-dmz-web — `10.0.2.0/24`

Public-facing web tier. Receives inbound HTTPS from the internet via fw01 DNAT to waf01.
No DHCP — all static. Can reach api_gw and ca02 (CDP/OCSP) only; blocked from all other internal segments.

| | |
|---|---|
| Bridge | `virbr-dmzweb` |
| Host bridge IP | `10.0.2.254` |
| fw01 DMZ_WEB IP | `10.0.2.1` |
| Mode | Isolated (no NAT) |
| DHCP | None — static only |

Static assignments:

| IP | Host | Role |
|---|---|---|
| 10.0.2.1 | fw01 | Gateway |
| 10.0.2.10 | lb01.ad.lab | Load balancer |
| 10.0.2.11 | web01.ad.lab | IIS web server |
| 10.0.2.12 | waf01.ad.lab | Reverse proxy / WAF (internet-facing) |
| 10.0.2.15 | rodc01-web.ad.lab | RODC — Kerberos/LDAP for web tier |

---

### lab-mgmt — `10.0.3.0/24`

Out-of-band management plane. Only jump01 has access to other segments via fw01 rules.
No DHCP — all static. SIEM collects syslog here.

| | |
|---|---|
| Bridge | `virbr-mgmt` |
| Host bridge IP | `10.0.3.254` |
| fw01 MGMT IP | `10.0.3.1` |
| Mode | Isolated (no NAT) |
| DHCP | None — static only |

Static assignments:

| IP | Host | Role |
|---|---|---|
| 10.0.3.1 | fw01 | Gateway |
| 10.0.3.10 | jump01.ad.lab | Bastion / admin workstation |
| 10.0.3.20 | siem01.ad.lab | SIEM / log collector |
| 10.0.3.30 | sccm01.ad.lab | SCCM / patch management |
| 10.0.3.40 | backup01.ad.lab | Backup server |
| 10.0.3.254 | — | virbr-mgmt host bridge |

---

### lab-clients — `10.0.4.0/24`

Domain-joined workstations. DHCP relayed by fw01 to dhcp01 (`10.0.1.30`).
Clients can reach APP (HTTPS/8443) and browse the internet; blocked from DATA, IDENTITY, and MGMT.

| | |
|---|---|
| Bridge | `virbr-clients` |
| Host bridge IP | `10.0.4.254` |
| fw01 CLIENTS IP | `10.0.4.1` |
| Mode | Isolated (no NAT) |
| DHCP | Relayed by fw01 → dhcp01 (10.0.1.30), pool .50–.200 |

---

### lab-dmz-vpn — `10.0.5.0/24`

Remote access tier. vpn01 is **single-armed** — it has only one NIC on this segment.
fw01 receives IKEv2/SSL-VPN from the internet (via DNAT), decrypts, and routes traffic into APP or CLIENTS.
DMZ_VPN cannot reach DMZ_WEB.

| | |
|---|---|
| Bridge | `virbr-dmzvpn` |
| Host bridge IP | `10.0.5.254` |
| fw01 DMZ_VPN IP | `10.0.5.1` |
| Mode | Isolated (no NAT) |
| DHCP | None — static only |

Static assignments:

| IP | Host | Role |
|---|---|---|
| 10.0.5.1 | fw01 | Gateway |
| 10.0.5.10 | vpn01.ad.lab | VPN gateway (RRAS / IKEv2, single-armed) |
| 10.0.5.15 | rodc01-vpn.ad.lab | RODC — auth for VPN clients |

---

### lab-data — `10.0.6.0/24`

Data tier. No internet access. No outbound connections initiated from this segment.
All traffic is inbound from APP (SQL/SMB) or MGMT (admin/backup).

| | |
|---|---|
| Bridge | `virbr-data` |
| Host bridge IP | `10.0.6.254` |
| fw01 DATA IP | `10.0.6.1` |
| Mode | Isolated (no NAT) |
| DHCP | None — static only |

Static assignments:

| IP | Host | Role |
|---|---|---|
| 10.0.6.1 | fw01 | Gateway |
| 10.0.6.31 | fs01.ad.lab | File server (data NIC) |
| 10.0.6.32 | fs02.ad.lab | File server replica |
| 10.0.6.70 | sql01.ad.lab | SQL Server |
| 10.0.6.80 | ora01.ad.lab | Oracle DB |

---

### lab-identity — `10.0.7.0/24`

Identity and PKI tier. No internet access. No outbound connections from this segment.
Hosts the writable DCs and the two-tier PKI. ca01's NIC should be disconnected during normal operations.

| | |
|---|---|
| Bridge | `virbr-identity` |
| Host bridge IP | `10.0.7.254` |
| fw01 IDENTITY IP | `10.0.7.1` |
| Mode | Isolated (no NAT) |
| DHCP | None — static only |

Static assignments:

| IP | Host | Role |
|---|---|---|
| 10.0.7.1 | fw01 | Gateway |
| 10.0.7.10 | ad01.ad.lab | Primary DC / DNS1 |
| 10.0.7.11 | ad02.ad.lab | Replica DC / DNS2 |
| 10.0.7.20 | ca01.ad.lab | Offline Root CA (NIC disconnected at rest) |
| 10.0.7.21 | ca02.ad.lab | Issuing CA / ADCS Web Enrollment |

---

## Usage

### Create all networks (fresh install)

```bash
make create-networks
```

Defines, starts, and autostarts all 8 networks. Prints a status table on completion.

### Verify everything is up and on the correct IPs

```bash
make verify
```

### Tear everything down

```bash
make delete-networks
```

### Other targets

```bash
make start-networks    # start without redefining
make stop-networks     # stop without undefining
make restart-networks  # stop then start
make status            # bridge IPs from libvirt and host
make clean             # remove any inactive/leftover definitions
```

---

## Host NAT requirements

`lab-wan` provides the bridge, but the host still needs iptables rules to masquerade
fw01's traffic out through the Wi-Fi interface. These must survive reboots:

```bash
# Masquerade fw01 ICMP (libvirt's NAT rule only covers TCP/UDP ports)
sudo iptables -t nat -I POSTROUTING 1 \
  -s 10.0.0.0/30 -o wlxd03745b49f87 -p icmp -j MASQUERADE

# Allow forwarding between virbr-wan and Wi-Fi
sudo iptables -I FORWARD 1 -i virbr-wan -o wlxd03745b49f87 -j ACCEPT
sudo iptables -I FORWARD 2 -i wlxd03745b49f87 -o virbr-wan \
  -m state --state RELATED,ESTABLISHED -j ACCEPT

# Persist across reboots
sudo apt install iptables-persistent
sudo netfilter-persistent save
```

> The interface name `wlxd03745b49f87` is specific to this host. Verify with `ip link show`.

---

## Files

| File | Network | Subnet |
|---|---|---|
| `lab-wan.xml` | lab-wan | 10.0.0.0/30 |
| `lab-app.xml` | lab-app | 10.0.1.0/24 |
| `lab-dmz-web.xml` | lab-dmz-web | 10.0.2.0/24 |
| `lab-mgmt.xml` | lab-mgmt | 10.0.3.0/24 |
| `lab-clients.xml` | lab-clients | 10.0.4.0/24 |
| `lab-dmz-vpn.xml` | lab-dmz-vpn | 10.0.5.0/24 |
| `lab-data.xml` | lab-data | 10.0.6.0/24 |
| `lab-identity.xml` | lab-identity | 10.0.7.0/24 |
| `Makefile` | — | all targets |

---

*ad.lab nets — August 2026*
