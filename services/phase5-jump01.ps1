# phase5-jump01.ps1
# Run on win11 (jump01) as local Administrator
# Windows 11 Pro bastion host

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Step 1 - Rename
Write-Host "[1/6] Renaming to JUMP01..." -ForegroundColor Cyan
if ($env:COMPUTERNAME -ne 'JUMP01') {
    Rename-Computer -NewName 'JUMP01' -Force
    Write-Host "     Renamed. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already JUMP01." -ForegroundColor Green

# Step 2 - Configure dual NICs
Write-Host "[2/6] Configuring dual NICs..." -ForegroundColor Cyan
$adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } |
    Sort-Object InterfaceIndex

if ($adapters.Count -lt 2) {
    Write-Host "ERROR: Only $($adapters.Count) NIC(s) found." -ForegroundColor Red
    Write-Host "       Shut down, add MGMT NIC via virsh, then retry." -ForegroundColor Red
    exit 1
}

$lanIf  = $adapters[0].InterfaceIndex
$mgmtIf = $adapters[1].InterfaceIndex

# LAN NIC - domain traffic + internet via fw01
Remove-NetIPAddress -InterfaceIndex $lanIf -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute     -InterfaceIndex $lanIf -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress    -InterfaceIndex $lanIf `
    -IPAddress '10.0.1.41' -PrefixLength 24 -DefaultGateway '10.0.1.1'
Set-DnsClientServerAddress -InterfaceIndex $lanIf `
    -ServerAddresses '10.0.1.10','10.0.1.11'

# MGMT NIC - isolated management network, no gateway
Remove-NetIPAddress -InterfaceIndex $mgmtIf -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute     -InterfaceIndex $mgmtIf -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress    -InterfaceIndex $mgmtIf `
    -IPAddress '10.0.3.10' -PrefixLength 24
Set-DnsClientServerAddress -InterfaceIndex $mgmtIf -ServerAddresses ''

# Rename adapters for clarity
Rename-NetAdapter -InterfaceIndex $lanIf  -NewName 'LAN'  -ErrorAction SilentlyContinue
Rename-NetAdapter -InterfaceIndex $mgmtIf -NewName 'MGMT' -ErrorAction SilentlyContinue

Write-Host "     LAN:  10.0.1.41/24  GW: 10.0.1.1" -ForegroundColor Green
Write-Host "     MGMT: 10.0.3.10/24  (no gateway)" -ForegroundColor Green

# Step 3 - Join domain
Write-Host "[3/6] Joining domain ad.lab..." -ForegroundColor Cyan
Start-Sleep -Seconds 8
if ((Get-WmiObject Win32_ComputerSystem).Domain -ne 'ad.lab') {
    $cred = Get-Credential -Message "Enter ADLAB\Administrator" `
        -UserName 'ADLAB\Administrator'
    Add-Computer -DomainName 'ad.lab' -Credential $cred -Force
    Write-Host "     Domain joined. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already domain member." -ForegroundColor Green

# Step 4 - Install RSAT tools (all available on Win11 Pro)
Write-Host "[4/6] Installing RSAT tools..." -ForegroundColor Cyan
$rsatFeatures = @(
    'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0',
    'Rsat.Dns.Tools~~~~0.0.1.0',
    'Rsat.DHCP.Tools~~~~0.0.1.0',
    'Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0',
    'Rsat.FileServices.Tools~~~~0.0.1.0',
    'Rsat.RemoteDesktop.Services.Tools~~~~0.0.1.0',
    'Rsat.ServerManager.Tools~~~~0.0.1.0',
    'Rsat.CertificateServices.Tools~~~~0.0.1.0'
)
foreach ($f in $rsatFeatures) {
    Write-Host "     Installing: $f" -ForegroundColor Gray
    Add-WindowsCapability -Online -Name $f -ErrorAction SilentlyContinue
}
Write-Host "     RSAT tools installed." -ForegroundColor Green

# Step 5 - Install Windows Admin Center
Write-Host "[5/6] Downloading Windows Admin Center..." -ForegroundColor Cyan
$wacInstaller = "$env:TEMP\WindowsAdminCenter.msi"
try {
    Invoke-WebRequest `
        -Uri     'https://aka.ms/WACDownload' `
        -OutFile $wacInstaller `
        -UseBasicParsing
    Start-Process msiexec.exe -ArgumentList `
        "/i `"$wacInstaller`" /qn SME_PORT=6516 SSL_CERTIFICATE_OPTION=generate" `
        -Wait
    Write-Host "     Windows Admin Center installed on port 6516." -ForegroundColor Green
    Write-Host "     Access: https://jump01.ad.lab:6516" -ForegroundColor Green
} catch {
    Write-Host "     WAC download failed (no internet). Install manually later." -ForegroundColor Yellow
    Write-Host "     Download from: https://aka.ms/WACDownload" -ForegroundColor Yellow
}

# Step 6 - Firewall rules
Write-Host "[6/6] Configuring firewall rules..." -ForegroundColor Cyan

# RDP inbound on LAN
New-NetFirewallRule -DisplayName 'RDP Inbound LAN' `
    -Direction Inbound -Protocol TCP -LocalPort 3389 `
    -LocalAddress '10.0.1.41' `
    -Action Allow -Profile Domain `
    -ErrorAction SilentlyContinue

# SSH inbound on both NICs
New-NetFirewallRule -DisplayName 'SSH Inbound' `
    -Direction Inbound -Protocol TCP -LocalPort 22 `
    -Action Allow -Profile Any `
    -ErrorAction SilentlyContinue

# WAC inbound on LAN
New-NetFirewallRule -DisplayName 'Windows Admin Center' `
    -Direction Inbound -Protocol TCP -LocalPort 6516 `
    -LocalAddress '10.0.1.41' `
    -Action Allow -Profile Domain `
    -ErrorAction SilentlyContinue

# WinRM outbound to LAN
New-NetFirewallRule -DisplayName 'WinRM Outbound LAN' `
    -Direction Outbound -Protocol TCP -RemotePort 5985,5986 `
    -RemoteAddress '10.0.1.0/24' `
    -Action Allow -Profile Domain `
    -ErrorAction SilentlyContinue

Write-Host "     Firewall rules configured." -ForegroundColor Green

Write-Host ""
Write-Host "JUMP01 (Windows 11 Pro) configuration complete." -ForegroundColor Green
Write-Host ""
Write-Host "Available management tools:" -ForegroundColor Cyan
Write-Host "  Active Directory Users and Computers  → dsa.msc" -ForegroundColor White
Write-Host "  Group Policy Management               → gpmc.msc" -ForegroundColor White
Write-Host "  DNS Manager                           → dnsmgmt.msc" -ForegroundColor White
Write-Host "  DHCP Console                          → dhcpmgmt.msc" -ForegroundColor White
Write-Host "  Certificate Authority                 → certsrv.msc" -ForegroundColor White
Write-Host "  Server Manager (remote)               → servermanager.exe" -ForegroundColor White
Write-Host "  Windows Admin Center                  → https://localhost:6516" -ForegroundColor White
Write-Host ""
Write-Host "RDP access from laptop via SSH tunnel:" -ForegroundColor Cyan
Write-Host "  ssh -L 13389:10.0.1.41:3389 huber@192.168.18.12 -N" -ForegroundColor White
Write-Host "  Then open RDP to: localhost:13389" -ForegroundColor White
Write-Host "  Login as: ADLAB\Administrator" -ForegroundColor White
