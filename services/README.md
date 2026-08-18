# ad.lab Services Tier — Phase 5 Reference Guide
## Application & Services Tier Implementation

---

## 1. Overview

Phase 5 deploys four service VMs that complete the LAN tier. All VMs run
Windows Server 2025 Core except jump01 which runs Windows 11 Pro for full
GUI management capability.

| VM | Hostname | IP | Role | OS |
|---|---|---|---|---|
| dhcp01 | dhcp01.ad.lab | 10.0.1.30 | DHCP server | Win Server 2025 Core |
| fs01 | fs01.ad.lab | 10.0.1.31 | File server + DNS2 | Win Server 2025 Core |
| app01 | app01.ad.lab | 10.0.1.40 | IIS + ASP.NET | Win Server 2025 Core |
| jump01 | jump01.ad.lab | 10.0.1.41 / 10.0.3.10 | Bastion (Win11 Pro) | Windows 11 Pro |

---

## 2. Prerequisites

- Phase 3 complete — ad01 and ad02 promoted and replicating
- Phase 4 complete — ca02 issuing certs, autoenroll GPO active
- All 4 VMs attached to lab-lan (jump01 also attached to lab-mgmt)
- dhcp01 authorized in AD by running `Add-DhcpServerInDC` on ad01

---

## 3. VM Network Config

| VM | NIC1 | NIC2 | Gateway | DNS |
|---|---|---|---|---|
| dhcp01 | lab-lan 10.0.1.30 | — | 10.0.1.1 | 10.0.1.10, 10.0.1.11 |
| fs01 | lab-lan 10.0.1.31 | — | 10.0.1.1 | 10.0.1.10, 10.0.1.11 |
| app01 | lab-lan 10.0.1.40 | — | 10.0.1.1 | 10.0.1.10, 10.0.1.11 |
| jump01 | lab-lan 10.0.1.41 | lab-mgmt 10.0.3.10 | 10.0.1.1 (LAN only) | 10.0.1.10, 10.0.1.11 (LAN NIC only) |

---

## 4. MAC Address Inventory

| VM | MAC (lab-lan) | MAC (lab-mgmt) |
|---|---|---|
| ad01 | 52:54:00:49:37:cc | — |
| ad02 | 52:54:00:02:73:68 | — |
| ca01 | 52:54:00:29:b6:fc | — |
| ca02 | 52:54:00:d0:92:e0 | — |
| dhcp01 | 52:54:00:fe:d2:cb | — |
| fs01 | 52:54:00:32:08:19 | — |
| app01 | 52:54:00:a1:d3:37 | — |
| jump01 | 52:54:00:40:36:68 | 52:54:00:97:06:e7 |

---

## 5. DHCP Configuration (dhcp01)

### Scope
```
Scope ID:    10.0.1.0
Range:       10.0.1.50 - 10.0.1.200
Mask:        255.255.255.0
Lease:       8 hours
Router:      10.0.1.1
DNS:         10.0.1.10, 10.0.1.11
Domain:      ad.lab
```

### Static reservations
```
10.0.1.10  AD01    52:54:00:49:37:cc
10.0.1.11  AD02    52:54:00:02:73:68
10.0.1.20  CA01    52:54:00:29:b6:fc
10.0.1.21  CA02    52:54:00:d0:92:e0
10.0.1.30  DHCP01  52:54:00:fe:d2:cb
10.0.1.31  FS01    52:54:00:32:08:19
10.0.1.40  APP01   52:54:00:a1:d3:37
10.0.1.41  JUMP01  52:54:00:40:36:68
```

### Authorization
DHCP must be authorized in AD. If `Add-DhcpServerInDC` fails on dhcp01
run it from ad01 instead:
```powershell
# On ad01
Add-DhcpServerInDC -DnsName 'DHCP01.ad.lab' -IPAddress '10.0.1.30'
Get-DhcpServerInDC
```

### Key commands
```powershell
Get-DhcpServerv4Scope -ComputerName dhcp01.ad.lab
Get-DhcpServerv4Reservation -ScopeId '10.0.1.0' -ComputerName dhcp01.ad.lab
Get-DhcpServerv4Lease -ScopeId '10.0.1.0' -ComputerName dhcp01.ad.lab
```

---

## 6. File Server Configuration (fs01)

### SMB Shares
```
\\FS01\Data      C:\Shares\Data      General data
\\FS01\Profiles  C:\Shares\Profiles  Roaming profiles
\\FS01\Software  C:\Shares\Software  Software distribution
```

Permissions: Domain Admins = Full, Domain Users = Modify, ABE enabled.

### DFS Namespace
```
\\ad.lab\Files → \\FS01\Data
```

### DNS Secondary Zones
```
ad.lab              secondary  masters: 10.0.1.10, 10.0.1.11
1.0.10.in-addr.arpa secondary  masters: 10.0.1.10, 10.0.1.11
```

Allow zone transfers from ad01:
```powershell
# On ad01
Set-DnsServerPrimaryZone -Name 'ad.lab' `
    -SecondaryServers '10.0.1.31' `
    -SecureSecondaries TransferToSecureServers

Set-DnsServerPrimaryZone -Name '1.0.10.in-addr.arpa' `
    -SecondaryServers '10.0.1.31' `
    -SecureSecondaries TransferToSecureServers
```

Note: `1.0.10.in-addr.arpa` must be created on ad01 first if it does not exist:
```powershell
# On ad01 — create reverse zone if missing
Add-DnsServerPrimaryZone `
    -NetworkID        '10.0.1.0/24' `
    -ReplicationScope 'Forest' `
    -DynamicUpdate    Secure
```

Force zone transfer on fs01:
```powershell
# On fs01
Start-DnsServerZoneTransfer -Name 'ad.lab'
Start-DnsServerZoneTransfer -Name '1.0.10.in-addr.arpa'
```

---

## 7. Application Server Configuration (app01)

### IIS Configuration
```
Site:         Default Web Site
Protocol:     HTTPS only (port 443)
Auth:         Windows Authentication (Kerberos)
Anonymous:    Disabled
App pool:     AdLabAppPool
```

### Certificate
Machine cert issued by ADLAB-ISSUING-CA via autoenroll, bound to HTTPS binding.

```powershell
# Request cert manually if autoenroll missed it
Get-Certificate -Template 'WebServer' `
    -SubjectName 'CN=app01.ad.lab' `
    -DnsName 'app01.ad.lab','app01' `
    -CertStoreLocation 'Cert:\LocalMachine\My'

# Bind cert to IIS
$thumb = (Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -like '*app01*' } |
    Select-Object -First 1).Thumbprint
$binding = Get-WebBinding -Name 'Default Web Site' -Protocol https
$binding.AddSslCertificate($thumb, 'My')
```

### Fix duplicate binding error
```powershell
# If HTTPS binding already exists from previous run
Get-WebBinding -Name 'Default Web Site' -Protocol https |
    Remove-WebBinding -ErrorAction SilentlyContinue
New-WebBinding -Name 'Default Web Site' -Protocol https -Port 443 -SslFlags 0
```

### Test IIS
```powershell
# From jump01
Invoke-WebRequest -Uri 'https://app01.ad.lab' `
    -UseDefaultCredentials -SkipCertificateCheck
```

---

## 8. Bastion Host Configuration (jump01)

### Why Windows 11 Pro instead of Server Core
`RDS-Gateway` role requires Desktop Experience and is not available on
Server Core. Windows 11 Pro provides full GUI RSAT tools, Remote Desktop
client, Edge browser for OPNsense WebGUI, and Windows Admin Center.

### Issues encountered

**Broken secure channel after rename**
The computer account password goes out of sync when the machine is renamed
and rejoins under a new name. Fix:
```powershell
Test-ComputerSecureChannel -Repair `
    -Credential (Get-Credential -UserName 'ADLAB\Administrator' -Message 'Repair')
Test-ComputerSecureChannel -Verbose
```

**RDP disabled by default on Windows 11**
```powershell
Set-ItemProperty `
    -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
    -Name 'fDenyTSConnections' -Value 0
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
Set-Service TermService -StartupType Automatic
```

**Rename-NetAdapter does not accept -InterfaceIndex**
Use `-Name` (the current alias) instead:
```powershell
Rename-NetAdapter -Name 'Ethernet 2' -NewName 'LAN'
Rename-NetAdapter -Name 'Ethernet'   -NewName 'MGMT'
```

### RSAT tools installed
```
Rsat.ActiveDirectory.DS-LDS.Tools
Rsat.Dns.Tools
Rsat.DHCP.Tools
Rsat.GroupPolicy.Management.Tools
Rsat.FileServices.Tools
Rsat.RemoteDesktop.Services.Tools
Rsat.ServerManager.Tools
Rsat.CertificateServices.Tools
```

Note: `Rsat.AD-AdminCenter` and `Rsat.File-Services` GUI snap-ins are
Windows 11 Pro compatible. They are NOT available on Server Core.

### Windows Admin Center
Installed on port 6516. Access from jump01:
```
https://localhost:6516
```

### RDP access from laptop via SSH tunnel
```bash
# On laptop — start tunnel
ssh -L 13389:10.0.1.41:3389 huber@192.168.18.12 -N &

# Connect RDP
# Server:   localhost:13389
# Username: ADLAB\Administrator
# Domain:   ADLAB
```

### Management tools available on jump01
```
dsa.msc          Active Directory Users and Computers
gpmc.msc         Group Policy Management Console
dnsmgmt.msc      DNS Manager
dhcpmgmt.msc     DHCP Console
certsrv.msc      Certificate Authority
servermanager    Server Manager (remote management)
https://localhost:6516   Windows Admin Center
```

### Manage other VMs from jump01
```powershell
# RDP to any VM
mstsc /v:ad01.ad.lab

# PowerShell remoting to any VM
Enter-PSSession -ComputerName ad01.ad.lab

# Run command on multiple VMs at once
Invoke-Command -ComputerName ad01,ad02,ca02,dhcp01,fs01,app01 -ScriptBlock {
    hostname
    Get-Service | Where-Object { $_.Status -eq 'Stopped' }
}
```

---

## 9. Verification Results

| Test | Result |
|---|---|
| DHCP scope active | ✓ 10.0.1.50-200 |
| DHCP authorized in AD | ✓ dhcp01.ad.lab |
| DHCP reservations | ✓ 8 VMs |
| SMB shares accessible | ✓ Data, Profiles, Software |
| DFS namespace | ✓ \\ad.lab\Files |
| DNS secondary zones | ✓ ad.lab + reverse |
| IIS HTTPS cert | ✓ issued by ADLAB-ISSUING-CA |
| IIS Windows Auth | ✓ Kerberos |
| Secure channel (jump01) | ✓ repaired |
| RDP to jump01 | ✓ via SSH tunnel localhost:13389 |
| WinRM to all VMs | ✓ ad01 ad02 ca02 dhcp01 fs01 app01 |
| RSAT tools | ✓ AD, DNS, DHCP, GPO, Certs |
| Windows Admin Center | ✓ https://localhost:6516 |
| Autoenroll on all VMs | ✓ certs from ADLAB-ISSUING-CA |

---

## 10. Quick Reference Commands

### From jump01 — check all VMs at once
```powershell
# WinRM health check
$vms = @('ad01','ad02','ca02','dhcp01','fs01','app01')
foreach ($vm in $vms) {
    $ok = Test-WSMan -ComputerName "$vm.ad.lab" -ErrorAction SilentlyContinue
    Write-Host "$vm`: $(if($ok){'OK'}else{'FAIL'})" -ForegroundColor $(if($ok){'Green'}else{'Red'})
}

# Check certs on all VMs
foreach ($vm in $vms) {
    $count = (Invoke-Command -ComputerName "$vm.ad.lab" -ScriptBlock {
        (Get-ChildItem Cert:\LocalMachine\My |
            Where-Object { $_.Issuer -like '*ADLAB*' }).Count
    } -ErrorAction SilentlyContinue)
    Write-Host "$vm`: $count cert(s)" -ForegroundColor Green
}
```

### DHCP troubleshooting
```powershell
# Check active leases
Get-DhcpServerv4Lease -ScopeId '10.0.1.0' -ComputerName dhcp01 |
    Select-Object IPAddress, HostName, ClientId, LeaseExpiryTime

# Release and renew on a client
ipconfig /release
ipconfig /renew
```

### DNS troubleshooting
```powershell
# Force zone transfer on fs01
Start-DnsServerZoneTransfer -Name 'ad.lab' -ComputerName fs01
nslookup ad01.ad.lab 10.0.1.31   # test via fs01 DNS
```

### RDP tunnel aliases for laptop (~/.ssh/config)
```
Host lab-jump
    HostName      192.168.18.12
    User          huber
    LocalForward  13389 10.0.1.41:3389
    LocalForward  16516 10.0.1.41:6516

# Usage:
# ssh lab-jump -N &
# RDP to localhost:13389
# WAC to https://localhost:16516
```

---

*ad.lab Phase 5 Reference Guide — May 2026*
