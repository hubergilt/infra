# phase6-vpn01-final.ps1
# Run on vpn01 - Windows Server 2025 Core
# VPN gateway - RRAS IKEv2
# DMZ IP: 10.0.2.10/24  GW: 10.0.2.1
# LAN IP: 10.0.1.60/24  DNS: ad01/ad02
#
# FIXES APPLIED:
#   - Feature name: RemoteAccess + DirectAccess-VPN + Routing (not 'RRAS')
#   - Install-RemoteAccess timeout: use netsh instead
#   - NPS not available on Server 2025 Core: skip, cosmetic warning only
#   - NICs identified by MAC address (not interface index order)
#   - Add VPN01$ to 'RAS and IAS Servers' group on ad01 before running

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# MAC addresses - confirmed from virsh domiflist
$dmzMac = '52-54-00-68-D7-B3'
$lanMac  = '52-54-00-AC-7A-37'

# Step 1 - Rename
Write-Host "[1/6] Renaming to VPN01..." -ForegroundColor Cyan
if ($env:COMPUTERNAME -ne 'VPN01') {
    Rename-Computer -NewName 'VPN01' -Force
    Write-Host "     Renamed. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already VPN01." -ForegroundColor Green

# Step 2 - Configure NICs by MAC
Write-Host "[2/6] Configuring NICs by MAC address..." -ForegroundColor Cyan
$dmzIf = (Get-NetAdapter | Where-Object { $_.MacAddress -eq $dmzMac }).InterfaceIndex
$lanIf = (Get-NetAdapter | Where-Object { $_.MacAddress -eq $lanMac }).InterfaceIndex

if (-not $dmzIf -or -not $lanIf) {
    Write-Host "ERROR: Could not find NICs by MAC. Check MAC addresses." -ForegroundColor Red
    Get-NetAdapter | Select-Object Name, MacAddress, InterfaceIndex
    exit 1
}

Write-Host "     DMZ NIC index: $dmzIf" -ForegroundColor Gray
Write-Host "     LAN NIC index: $lanIf" -ForegroundColor Gray

# DMZ NIC - default gateway (internet-facing)
Remove-NetIPAddress -InterfaceIndex $dmzIf -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute     -InterfaceIndex $dmzIf -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress    -InterfaceIndex $dmzIf -IPAddress '10.0.2.10' -PrefixLength 24 -DefaultGateway '10.0.2.1'
Set-DnsClientServerAddress -InterfaceIndex $dmzIf -ServerAddresses ''

# LAN NIC - no gateway, DNS only
Remove-NetIPAddress -InterfaceIndex $lanIf -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute     -InterfaceIndex $lanIf -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress    -InterfaceIndex $lanIf -IPAddress '10.0.1.60' -PrefixLength 24
Set-DnsClientServerAddress -InterfaceIndex $lanIf -ServerAddresses '10.0.1.10','10.0.1.11'

# Rename adapters
$dmzName = (Get-NetAdapter | Where-Object { $_.InterfaceIndex -eq $dmzIf }).Name
$lanName = (Get-NetAdapter | Where-Object { $_.InterfaceIndex -eq $lanIf }).Name
Rename-NetAdapter -Name $dmzName -NewName 'DMZ' -ErrorAction SilentlyContinue
Rename-NetAdapter -Name $lanName -NewName 'LAN' -ErrorAction SilentlyContinue

Write-Host "     DMZ: 10.0.2.10/24  GW: 10.0.2.1" -ForegroundColor Green
Write-Host "     LAN: 10.0.1.60/24  (no GW, DNS only)" -ForegroundColor Green

# Step 3 - Join domain via LAN NIC
Write-Host "[3/6] Joining domain ad.lab..." -ForegroundColor Cyan
Start-Sleep -Seconds 8
if ((Get-WmiObject Win32_ComputerSystem).Domain -ne 'ad.lab') {
    $cred = Get-Credential -Message "Enter ADLAB\Administrator" -UserName 'ADLAB\Administrator'
    Add-Computer -DomainName 'ad.lab' -Credential $cred -Force
    Write-Host "     Domain joined. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already domain member." -ForegroundColor Green

# Step 4 - Install RRAS features (correct names for Server 2025)
Write-Host "[4/6] Installing RRAS features..." -ForegroundColor Cyan
$result = Install-WindowsFeature -Name RemoteAccess, DirectAccess-VPN, Routing `
    -IncludeManagementTools

if ($result.RestartNeeded -eq 'Yes') {
    Write-Host "     Reboot required. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     RRAS features installed." -ForegroundColor Green

# Step 5 - Configure RRAS via netsh (Install-RemoteAccess times out on Core)
Write-Host "[5/6] Configuring RRAS for IKEv2 VPN..." -ForegroundColor Cyan

# Enable RRAS configuration
netsh ras set conf confstate = enabled | Out-Null

# Set authentication mode
netsh ras set authmode mode = standard | Out-Null

# Enable and start RRAS service
Set-Service RemoteAccess -StartupType Automatic
Start-Service RemoteAccess -ErrorAction SilentlyContinue
Start-Sleep -Seconds 15

# Verify RRAS started
$svc = Get-Service RemoteAccess
if ($svc.Status -ne 'Running') {
    Write-Host "     WARNING: RRAS did not start. Try: Start-Service RemoteAccess" -ForegroundColor Yellow
} else {
    Write-Host "     RRAS service: Running" -ForegroundColor Green
}

# Trigger certificate autoenrollment
certutil -pulse | Out-Null
Start-Sleep -Seconds 15

# Verify machine cert
$cert = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Issuer -like '*ADLAB*' } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

if ($cert) {
    Write-Host "     Machine cert: $($cert.Thumbprint)" -ForegroundColor Green
} else {
    Write-Host "     WARNING: No machine cert. Run: certutil -pulse" -ForegroundColor Yellow
}

# Step 6 - Firewall rules
Write-Host "[6/6] Configuring firewall rules..." -ForegroundColor Cyan
New-NetFirewallRule -DisplayName 'IKEv2 UDP 500' `
    -Direction Inbound -Protocol UDP -LocalPort 500 `
    -Action Allow -Profile Any -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'IKEv2 NAT-T 4500' `
    -Direction Inbound -Protocol UDP -LocalPort 4500 `
    -Action Allow -Profile Any -ErrorAction SilentlyContinue
Write-Host "     Firewall rules added." -ForegroundColor Green

# Final status
Write-Host ""
Write-Host "VPN01 configuration complete." -ForegroundColor Green
Write-Host ""
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -like '10.0.*' } |
    Select-Object InterfaceAlias, IPAddress, PrefixLength
Write-Host ""
Get-Service RemoteAccess | Select-Object Name, Status, StartType
Write-Host ""
netstat -ano | findstr ':500 '
netstat -ano | findstr ':4500'
Write-Host ""
Write-Host "NOTE: Run on ad01 to register vpn01 in AD:" -ForegroundColor Yellow
Write-Host "  Add-ADGroupMember -Identity 'RAS and IAS Servers' -Members 'VPN01$'" -ForegroundColor White
Write-Host ""
Write-Host "NOTE: NPS CRP warning is cosmetic — IKEv2 cert auth works without NPS." -ForegroundColor Yellow
