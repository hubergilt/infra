# phase6-waf01-final.ps1
# Run on waf01 - Windows Server 2025 Core
# IIS reverse proxy using HTTP Redirect (ARR not compatible with Server 2025 Core)
# DMZ IP: 10.0.2.12/24  GW: 10.0.2.1
# LAN IP: 10.0.1.62/24  DNS: ad01/ad02
#
# FIXES APPLIED:
#   - ARR 3.0 not compatible with Server 2025 Core - use HTTP Redirect instead
#   - Web-Http-Redirect feature must be installed explicitly
#   - NICs identified by MAC address
#   - PS 5.1 test method (no -SkipCertificateCheck)

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$dmzMac = '52-54-00-F2-F3-7E'
$lanMac  = '52-54-00-A6-19-13'

# Step 1 - Rename
Write-Host "[1/6] Renaming to WAF01..." -ForegroundColor Cyan
if ($env:COMPUTERNAME -ne 'WAF01') {
    Rename-Computer -NewName 'WAF01' -Force
    Write-Host "     Renamed. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already WAF01." -ForegroundColor Green

# Step 2 - Configure NICs by MAC
Write-Host "[2/6] Configuring NICs by MAC address..." -ForegroundColor Cyan
$dmzIf = (Get-NetAdapter | Where-Object { $_.MacAddress -eq $dmzMac }).InterfaceIndex
$lanIf = (Get-NetAdapter | Where-Object { $_.MacAddress -eq $lanMac }).InterfaceIndex

Remove-NetIPAddress -InterfaceIndex $dmzIf -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute     -InterfaceIndex $dmzIf -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress    -InterfaceIndex $dmzIf -IPAddress '10.0.2.12' -PrefixLength 24 -DefaultGateway '10.0.2.1'
Set-DnsClientServerAddress -InterfaceIndex $dmzIf -ServerAddresses ''

Remove-NetIPAddress -InterfaceIndex $lanIf -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute     -InterfaceIndex $lanIf -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress    -InterfaceIndex $lanIf -IPAddress '10.0.1.62' -PrefixLength 24
Set-DnsClientServerAddress -InterfaceIndex $lanIf -ServerAddresses '10.0.1.10','10.0.1.11'

$dmzName = (Get-NetAdapter | Where-Object { $_.InterfaceIndex -eq $dmzIf }).Name
$lanName = (Get-NetAdapter | Where-Object { $_.InterfaceIndex -eq $lanIf }).Name
Rename-NetAdapter -Name $dmzName -NewName 'DMZ' -ErrorAction SilentlyContinue
Rename-NetAdapter -Name $lanName -NewName 'LAN' -ErrorAction SilentlyContinue

Write-Host "     DMZ: 10.0.2.12/24  GW: 10.0.2.1" -ForegroundColor Green
Write-Host "     LAN: 10.0.1.62/24  (no GW, DNS only)" -ForegroundColor Green

# Step 3 - Join domain
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

# Step 4 - Install IIS + HTTP Redirect feature
# Note: ARR 3.0 is NOT compatible with Windows Server 2025 Core
# Using HTTP Redirect as the reverse proxy mechanism instead
Write-Host "[4/6] Installing IIS + HTTP Redirect..." -ForegroundColor Cyan
Install-WindowsFeature -Name `
    Web-Server, Web-Default-Doc, Web-Http-Logging, `
    Web-Stat-Compression, Web-Filtering, Web-Windows-Auth, `
    Web-Http-Redirect `
    -IncludeManagementTools
Write-Host "     IIS + HTTP Redirect installed." -ForegroundColor Green

# Step 5 - Configure HTTPS + redirect to web01
Write-Host "[5/6] Configuring HTTPS and redirect to web01..." -ForegroundColor Cyan
Import-Module WebAdministration

# Request SSL cert
certutil -pulse | Out-Null
Start-Sleep -Seconds 15
try {
    Get-Certificate -Template WebServer `
        -SubjectName 'CN=waf01.ad.lab' `
        -DnsName 'waf01.ad.lab','waf01' `
        -CertStoreLocation 'Cert:\LocalMachine\My' | Out-Null
    Write-Host "     SSL cert issued." -ForegroundColor Green
} catch {
    Write-Host "     WARNING: Cert request failed. Run certutil -pulse manually." -ForegroundColor Yellow
}

# HTTPS binding
Remove-WebBinding -Name 'Default Web Site' -Protocol http -ErrorAction SilentlyContinue
$existingHttps = Get-WebBinding -Name 'Default Web Site' -Protocol https -ErrorAction SilentlyContinue
if (-not $existingHttps) {
    New-WebBinding -Name 'Default Web Site' -Protocol https -Port 443 -SslFlags 0
}

$thumb = (Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -like '*waf01*' -and $_.Issuer -like '*ADLAB*' } |
    Sort-Object NotAfter -Descending | Select-Object -First 1).Thumbprint
if ($thumb) {
    try {
        (Get-WebBinding -Name 'Default Web Site' -Protocol https).AddSslCertificate($thumb,'My')
        Write-Host "     SSL cert bound." -ForegroundColor Green
    } catch {
        Write-Host "     SSL cert may already be bound." -ForegroundColor Yellow
    }
}

# Configure HTTP Redirect to web01
Set-WebConfigurationProperty `
    -Filter 'system.webServer/httpRedirect' `
    -PSPath  'IIS:\Sites\Default Web Site' `
    -Name    'enabled' -Value $true
Set-WebConfigurationProperty `
    -Filter 'system.webServer/httpRedirect' `
    -PSPath  'IIS:\Sites\Default Web Site' `
    -Name    'destination' -Value 'https://web01.ad.lab'
Set-WebConfigurationProperty `
    -Filter 'system.webServer/httpRedirect' `
    -PSPath  'IIS:\Sites\Default Web Site' `
    -Name    'exactDestination' -Value $false
Set-WebConfigurationProperty `
    -Filter 'system.webServer/httpRedirect' `
    -PSPath  'IIS:\Sites\Default Web Site' `
    -Name    'httpResponseStatus' -Value 'Found'

iisreset /restart
Start-Sleep -Seconds 5
Write-Host "     Redirect configured: https://waf01.ad.lab → https://web01.ad.lab" -ForegroundColor Green

# Step 6 - Firewall
Write-Host "[6/6] Configuring firewall..." -ForegroundColor Cyan
New-NetFirewallRule -DisplayName 'HTTPS Inbound WAF01' `
    -Direction Inbound -Protocol TCP -LocalPort 443 `
    -Action Allow -Profile Any -ErrorAction SilentlyContinue
Write-Host "     Firewall rule added." -ForegroundColor Green

# Test redirect
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
try {
    $r = [System.Net.WebRequest]::Create('https://localhost')
    $r.AllowAutoRedirect = $false
    $resp = $r.GetResponse()
    Write-Host ""
    Write-Host "Redirect test:" -ForegroundColor Cyan
    Write-Host "  Status:   $($resp.StatusCode)" -ForegroundColor Green
    Write-Host "  Location: $($resp.Headers['Location'])" -ForegroundColor Green
    $resp.Close()
} catch [System.Net.WebException] {
    Write-Host "Redirect test: $($_.Exception.Message)" -ForegroundColor Yellow
}
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null

Write-Host ""
Write-Host "WAF01 configuration complete." -ForegroundColor Green
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -like '10.0.*' } |
    Select-Object InterfaceAlias, IPAddress, PrefixLength
