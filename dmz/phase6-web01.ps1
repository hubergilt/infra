# phase6-web01-final.ps1
# Run on web01 - Windows Server 2025 Core
# IIS web server - HTTPS + Windows Authentication
# DMZ IP: 10.0.2.11/24  GW: 10.0.2.1
# LAN IP: 10.0.1.61/24  DNS: ad01/ad02
#
# FIXES APPLIED:
#   - NICs identified by MAC address (not interface index order)
#   - Duplicate HTTPS binding handled with ErrorAction SilentlyContinue
#   - SkipCertificateCheck not available on PS 5.1 - use ServicePointManager

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$dmzMac = '52-54-00-84-AB-3F'
$lanMac  = '52-54-00-B3-F6-95'

# Step 1 - Rename
Write-Host "[1/7] Renaming to WEB01..." -ForegroundColor Cyan
if ($env:COMPUTERNAME -ne 'WEB01') {
    Rename-Computer -NewName 'WEB01' -Force
    Write-Host "     Renamed. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already WEB01." -ForegroundColor Green

# Step 2 - Configure NICs by MAC
Write-Host "[2/7] Configuring NICs by MAC address..." -ForegroundColor Cyan
$dmzIf = (Get-NetAdapter | Where-Object { $_.MacAddress -eq $dmzMac }).InterfaceIndex
$lanIf = (Get-NetAdapter | Where-Object { $_.MacAddress -eq $lanMac }).InterfaceIndex

Remove-NetIPAddress -InterfaceIndex $dmzIf -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute     -InterfaceIndex $dmzIf -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress    -InterfaceIndex $dmzIf -IPAddress '10.0.2.11' -PrefixLength 24 -DefaultGateway '10.0.2.1'
Set-DnsClientServerAddress -InterfaceIndex $dmzIf -ServerAddresses ''

Remove-NetIPAddress -InterfaceIndex $lanIf -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute     -InterfaceIndex $lanIf -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress    -InterfaceIndex $lanIf -IPAddress '10.0.1.61' -PrefixLength 24
Set-DnsClientServerAddress -InterfaceIndex $lanIf -ServerAddresses '10.0.1.10','10.0.1.11'

$dmzName = (Get-NetAdapter | Where-Object { $_.InterfaceIndex -eq $dmzIf }).Name
$lanName = (Get-NetAdapter | Where-Object { $_.InterfaceIndex -eq $lanIf }).Name
Rename-NetAdapter -Name $dmzName -NewName 'DMZ' -ErrorAction SilentlyContinue
Rename-NetAdapter -Name $lanName -NewName 'LAN' -ErrorAction SilentlyContinue

Write-Host "     DMZ: 10.0.2.11/24  GW: 10.0.2.1" -ForegroundColor Green
Write-Host "     LAN: 10.0.1.61/24  (no GW, DNS only)" -ForegroundColor Green

# Step 3 - Join domain
Write-Host "[3/7] Joining domain ad.lab..." -ForegroundColor Cyan
Start-Sleep -Seconds 8
if ((Get-WmiObject Win32_ComputerSystem).Domain -ne 'ad.lab') {
    $cred = Get-Credential -Message "Enter ADLAB\Administrator" -UserName 'ADLAB\Administrator'
    Add-Computer -DomainName 'ad.lab' -Credential $cred -Force
    Write-Host "     Domain joined. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already domain member." -ForegroundColor Green

# Step 4 - Install IIS + ASP.NET
Write-Host "[4/7] Installing IIS..." -ForegroundColor Cyan
Install-WindowsFeature -Name `
    Web-Server, Web-Default-Doc, Web-Static-Content, `
    Web-Http-Logging, Web-Stat-Compression, Web-Filtering, `
    Web-Windows-Auth, Web-Net-Ext45, Web-Asp-Net45, `
    Web-ISAPI-Ext, Web-ISAPI-Filter, `
    NET-Framework-45-Core, NET-Framework-45-ASPNET `
    -IncludeManagementTools
Write-Host "     IIS installed." -ForegroundColor Green

# Step 5 - Request HTTPS certificate
Write-Host "[5/7] Requesting HTTPS certificate..." -ForegroundColor Cyan
certutil -pulse | Out-Null
Start-Sleep -Seconds 15
try {
    Get-Certificate -Template WebServer `
        -SubjectName 'CN=web01.ad.lab' `
        -DnsName 'web01.ad.lab','web01' `
        -CertStoreLocation 'Cert:\LocalMachine\My' | Out-Null
    Write-Host "     Certificate issued." -ForegroundColor Green
} catch {
    Write-Host "     WARNING: Cert request failed. Run certutil -pulse manually." -ForegroundColor Yellow
}

# Step 6 - Configure IIS HTTPS + Windows Auth
Write-Host "[6/7] Configuring IIS..." -ForegroundColor Cyan
Import-Module WebAdministration

# Remove HTTP, add HTTPS (handle duplicate gracefully)
Remove-WebBinding -Name 'Default Web Site' -Protocol http -ErrorAction SilentlyContinue
$existingHttps = Get-WebBinding -Name 'Default Web Site' -Protocol https -ErrorAction SilentlyContinue
if (-not $existingHttps) {
    New-WebBinding -Name 'Default Web Site' -Protocol https -Port 443 -SslFlags 0
}

# Bind SSL cert
$thumb = (Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -like '*web01*' -and $_.Issuer -like '*ADLAB*' } |
    Sort-Object NotAfter -Descending | Select-Object -First 1).Thumbprint

if ($thumb) {
    try {
        (Get-WebBinding -Name 'Default Web Site' -Protocol https).AddSslCertificate($thumb,'My')
        Write-Host "     SSL cert bound: $thumb" -ForegroundColor Green
    } catch {
        Write-Host "     SSL cert may already be bound." -ForegroundColor Yellow
    }
} else {
    Write-Host "     WARNING: No cert found. Bind manually after cert enrollment." -ForegroundColor Yellow
}

# Windows Auth
Set-WebConfigurationProperty `
    -Filter 'system.webServer/security/authentication/windowsAuthentication' `
    -Name enabled -Value $true -PSPath 'IIS:\Sites\Default Web Site'
Set-WebConfigurationProperty `
    -Filter 'system.webServer/security/authentication/anonymousAuthentication' `
    -Name enabled -Value $false -PSPath 'IIS:\Sites\Default Web Site'

# Step 7 - Firewall
Write-Host "[7/7] Configuring firewall..." -ForegroundColor Cyan
New-NetFirewallRule -DisplayName 'HTTPS Inbound WEB01' `
    -Direction Inbound -Protocol TCP -LocalPort 443 `
    -Action Allow -Profile Any -ErrorAction SilentlyContinue
Write-Host "     Firewall rule added." -ForegroundColor Green

Write-Host ""
Write-Host "WEB01 configuration complete." -ForegroundColor Green
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -like '10.0.*' } |
    Select-Object InterfaceAlias, IPAddress, PrefixLength
Get-Website | Select-Object Name, State
