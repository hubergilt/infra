# ad.lab DMZ Tier — Phase 6 Reference Guide
## DMZ Tier Implementation

---

## 1. Overview

Phase 6 deploys three dual-homed VMs in the DMZ (10.0.2.0/24). Each VM
has one NIC on lab-dmz and one NIC on lab-lan for domain membership and
AD authentication.

| VM | Hostname | DMZ IP | LAN IP | Role | OS |
|---|---|---|---|---|---|
| vpn01 | vpn01.ad.lab | 10.0.2.10 | 10.0.1.60 | VPN gateway (RRAS/IKEv2) | Win Server 2025 Core |
| web01 | web01.ad.lab | 10.0.2.11 | 10.0.1.61 | Web server (IIS) | Win Server 2025 Core |
| waf01 | waf01.ad.lab | 10.0.2.12 | 10.0.1.62 | Reverse proxy (ARR) | Win Server 2025 Core |

---

## 2. Traffic flow

```
Internet
   ↓
fw01 (OPNsense)
   ├── TCP 443  → waf01 DMZ NIC (10.0.2.12)  port forward
   └── UDP 500/4500 → vpn01 DMZ NIC (10.0.2.10) port forward

waf01 → web01 (10.0.2.11) reverse proxy
web01 → app01 (10.0.1.40) LAN backend

vpn01 LAN NIC → ad01/ad02 for Kerberos auth
waf01 LAN NIC → ad01/ad02 for Kerberos auth
web01 LAN NIC → ad01/ad02 for Kerberos auth
```

---

## 3. libvirt VM creation

Each DMZ VM needs two NICs — lab-dmz first, lab-lan second.

```bash
# create-vpn01.sh
virt-install \
  --name           vpn01 \
  --ram            4096 \
  --vcpus          2 \
  --os-variant     win2k22 \
  --machine        q35 \
  --boot           cdrom,hd \
  --disk           path=/vms/vpn01.qcow2,format=qcow2,bus=virtio,size=60 \
  --cdrom          /home/huber/Downloads/WinServer2025.iso \
  --network        network=lab-dmz,model=virtio \
  --network        network=lab-lan,model=virtio \
  --graphics       spice \
  --video          virtio \
  --noautoconsole

# Same pattern for web01 and waf01
# (change name, disk path, same dual NIC order: lab-dmz first, lab-lan second)
```

---

## 4. Common base config (all 3 VMs)

Run on each VM after Windows installation. Adjust hostname and IPs per VM.

```powershell
# Set hostname
Rename-Computer -NewName 'VPN01' -Force   # or WEB01 / WAF01
Restart-Computer -Force

# After reboot — set IPs
# DMZ NIC (first adapter — lower interface index)
$adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Sort-Object InterfaceIndex
$dmzIf = $adapters[0].InterfaceIndex
$lanIf = $adapters[1].InterfaceIndex

# DMZ NIC — no DNS (resolves via LAN NIC)
New-NetIPAddress -InterfaceIndex $dmzIf -IPAddress '10.0.2.10' -PrefixLength 24 -DefaultGateway '10.0.2.1'

# LAN NIC — DNS points to DCs, no gateway (default route via DMZ)
New-NetIPAddress -InterfaceIndex $lanIf -IPAddress '10.0.1.60' -PrefixLength 24
Set-DnsClientServerAddress -InterfaceIndex $lanIf -ServerAddresses '10.0.1.10','10.0.1.11'

# Join domain via LAN NIC
Add-Computer -DomainName 'ad.lab' -Credential (Get-Credential ADLAB\Administrator) -Force
Restart-Computer -Force
```

---

## 5. vpn01 — RRAS IKEv2 VPN

```powershell
# Install RRAS
Install-WindowsFeature -Name RemoteAccess,RRAS,RSAT-RemoteAccess -IncludeManagementTools

# Configure VPN
Install-RemoteAccess -VpnType VpnS2S
Set-RemoteAccess -PassThru

# Configure IKEv2 with machine certificate
$cert = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -like '*vpn01*' -and $_.Issuer -like '*ADLAB*' } |
    Select-Object -First 1

Set-VpnAuthProtocol `
    -UserAuthProtocolAccepted     Certificate,EAP `
    -TunnelAuthProtocolsAdvertised Certificate `
    -RootCertificateNameToAccept  $cert

# NAT for VPN clients
Import-Module RemoteAccess
Add-VpnS2SInterface -Name 'VPNClients' -Protocol IKEv2 -PassThru

# Firewall
New-NetFirewallRule -DisplayName 'IKEv2 Inbound' `
    -Direction Inbound -Protocol UDP -LocalPort 500,4500 -Action Allow
```

---

## 6. web01 — IIS web server

```powershell
# Install IIS
Install-WindowsFeature -Name Web-Server,Web-Windows-Auth,Web-Asp-Net45,
    Web-Net-Ext45,NET-Framework-45-Core -IncludeManagementTools

# Request cert from ADLAB-ISSUING-CA
Get-Certificate -Template WebServer `
    -SubjectName 'CN=web01.ad.lab' `
    -DnsName 'web01.ad.lab','web01' `
    -CertStoreLocation 'Cert:\LocalMachine\My'

# Configure HTTPS only + Windows Auth
Import-Module WebAdministration
Remove-WebBinding -Name 'Default Web Site' -Protocol http -ErrorAction SilentlyContinue
New-WebBinding -Name 'Default Web Site' -Protocol https -Port 443

# Bind cert
$thumb = (Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -like '*web01*' } | Select-Object -First 1).Thumbprint
(Get-WebBinding -Name 'Default Web Site' -Protocol https).AddSslCertificate($thumb,'My')

# Windows Auth
Set-WebConfigurationProperty -Filter '*/windowsAuthentication' -Name enabled -Value $true `
    -PSPath 'IIS:\Sites\Default Web Site'
Set-WebConfigurationProperty -Filter '*/anonymousAuthentication' -Name enabled -Value $false `
    -PSPath 'IIS:\Sites\Default Web Site'
```

---

## 7. waf01 — IIS Application Request Routing (reverse proxy)

```powershell
# Install IIS + ARR + URL Rewrite
Install-WindowsFeature -Name Web-Server,Web-Windows-Auth -IncludeManagementTools

# Download ARR and URL Rewrite via WebPI or manually
# ARR: https://www.iis.net/downloads/microsoft/application-request-routing
# URL Rewrite: https://www.iis.net/downloads/microsoft/url-rewrite

# After ARR install — enable proxy
Import-Module WebAdministration
Set-WebConfigurationProperty -Filter 'system.webServer/proxy' `
    -Name enabled -Value $true -PSPath 'IIS:\'

# Create reverse proxy rule to web01
Add-WebConfigurationProperty `
    -Filter 'system.webServer/rewrite/rules' `
    -Name '.' `
    -Value @{
        name           = 'ReverseProxy-web01'
        stopProcessing = 'true'
    } `
    -PSPath 'IIS:\Sites\Default Web Site'

Set-WebConfigurationProperty `
    -Filter "system.webServer/rewrite/rules/rule[@name='ReverseProxy-web01']/match" `
    -Name url -Value '(.*)' `
    -PSPath 'IIS:\Sites\Default Web Site'

Set-WebConfigurationProperty `
    -Filter "system.webServer/rewrite/rules/rule[@name='ReverseProxy-web01']/action" `
    -Name @{type='Rewrite'; url='https://web01.ad.lab/{R:1}'} `
    -PSPath 'IIS:\Sites\Default Web Site'
```

---

## 8. OPNsense firewall rules to add for Phase 6

These rules go on top of the existing ones configured in Phase 2.

### WAN → DMZ port forwards (already configured in Phase 2)
```
TCP 443  → waf01 10.0.2.12   HTTPS
UDP 500  → vpn01 10.0.2.10   IKEv2
UDP 4500 → vpn01 10.0.2.10   IKEv2 NAT-T
```

### DMZ rules — allow DMZ VMs to reach LAN DCs for auth
```
Pass  DMZ net → DomainControllers (10.0.1.10, 10.0.1.11)  TCP/UDP 53,88,389,636
Pass  DMZ net → IssuingCA (10.0.1.21)                      TCP 80,443
Pass  DMZ net → app01 (10.0.1.40)                          TCP 443
Pass  DMZ net → any                                         TCP 80,443 (internet)
Block DMZ net → LAN net (catch-all)
```

---

## 9. Verification checklist

```powershell
# From jump01 — test all DMZ VMs
$dmzVms = @('vpn01','web01','waf01')

# WinRM via LAN NIC
foreach ($vm in $dmzVms) {
    $ok = Test-WSMan -ComputerName "$vm.ad.lab" -ErrorAction SilentlyContinue
    Write-Host "$vm WinRM: $(if($ok){'OK'}else{'FAIL'})"
}

# HTTPS reachability
foreach ($vm in @('web01','waf01')) {
    try {
        $r = Invoke-WebRequest "https://$vm.ad.lab" -SkipCertificateCheck -UseDefaultCredentials
        Write-Host "$vm HTTPS: $($r.StatusCode)"
    } catch { Write-Host "$vm HTTPS: FAIL" }
}
```

---

*ad.lab Phase 6 Reference Guide — May 2026*
