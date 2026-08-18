# phase5-app01.ps1
# Run on app01 - Windows Server 2025 Core
# IIS + ASP.NET + .NET 8 application server
# Static IP: 10.0.1.40/24

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Step 1 - Rename
Write-Host "[1/7] Renaming to APP01..." -ForegroundColor Cyan
if ($env:COMPUTERNAME -ne 'APP01') {
    Rename-Computer -NewName 'APP01' -Force
    Write-Host "     Renamed. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already APP01." -ForegroundColor Green

# Step 2 - Static IP
Write-Host "[2/7] Setting static IP 10.0.1.40/24..." -ForegroundColor Cyan
$ifIndex = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }).InterfaceIndex
Remove-NetIPAddress   -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute       -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress      -InterfaceIndex $ifIndex -IPAddress '10.0.1.40' -PrefixLength 24 -DefaultGateway '10.0.1.1'
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses '10.0.1.10','10.0.1.11'
Start-Sleep -Seconds 5
Write-Host "     IP set: 10.0.1.40/24" -ForegroundColor Green

# Step 3 - Join domain
Write-Host "[3/7] Joining domain ad.lab..." -ForegroundColor Cyan
if ((Get-WmiObject Win32_ComputerSystem).Domain -ne 'ad.lab') {
    $cred = Get-Credential -Message "Enter ADLAB\Administrator" -UserName 'ADLAB\Administrator'
    Add-Computer -DomainName 'ad.lab' -Credential $cred -Force
    Write-Host "     Domain joined. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already domain member." -ForegroundColor Green

# Step 4 - Install IIS + ASP.NET features
Write-Host "[4/7] Installing IIS and ASP.NET features..." -ForegroundColor Cyan
Install-WindowsFeature -Name `
    Web-Server, `
    Web-WebServer, `
    Web-Common-Http, `
    Web-Default-Doc, `
    Web-Dir-Browsing, `
    Web-Http-Errors, `
    Web-Static-Content, `
    Web-Http-Redirect, `
    Web-Health, `
    Web-Http-Logging, `
    Web-Log-Libraries, `
    Web-Request-Monitor, `
    Web-Http-Tracing, `
    Web-Performance, `
    Web-Stat-Compression, `
    Web-Dyn-Compression, `
    Web-Security, `
    Web-Filtering, `
    Web-Windows-Auth, `
    Web-App-Dev, `
    Web-Net-Ext45, `
    Web-Asp-Net45, `
    Web-ISAPI-Ext, `
    Web-ISAPI-Filter, `
    Web-Mgmt-Tools, `
    Web-Mgmt-Console, `
    NET-Framework-45-Core, `
    NET-Framework-45-ASPNET `
    -IncludeManagementTools
Write-Host "     IIS and ASP.NET installed." -ForegroundColor Green

# Step 5 - Request HTTPS certificate from ADLAB-ISSUING-CA
Write-Host "[5/7] Requesting HTTPS certificate from ADLAB-ISSUING-CA..." -ForegroundColor Cyan
$certParams = @{
    Template          = 'WebServer'
    SubjectName       = 'CN=app01.ad.lab'
    DnsName           = 'app01.ad.lab','app01'
    CertStoreLocation = 'Cert:\LocalMachine\My'
}
try {
    $cert = Get-Certificate @certParams
    Write-Host "     Certificate issued: $($cert.Certificate.Thumbprint)" -ForegroundColor Green
} catch {
    Write-Host "     WARNING: Could not auto-request cert. Requesting manually..." -ForegroundColor Yellow
    certreq -enroll -machine WebServer
}

# Step 6 - Configure IIS
Write-Host "[6/7] Configuring IIS..." -ForegroundColor Cyan
Import-Module WebAdministration

# Remove default HTTP binding, add HTTPS only
Remove-WebBinding -Name 'Default Web Site' -Protocol http -Port 80 -ErrorAction SilentlyContinue
New-WebBinding -Name 'Default Web Site' -Protocol https -Port 443 -SslFlags 0

# Set Windows Authentication on Default Web Site
Set-WebConfigurationProperty `
    -Filter 'system.webServer/security/authentication/windowsAuthentication' `
    -Name   enabled `
    -Value  $true `
    -PSPath 'IIS:\Sites\Default Web Site'

Set-WebConfigurationProperty `
    -Filter 'system.webServer/security/authentication/anonymousAuthentication' `
    -Name   enabled `
    -Value  $false `
    -PSPath 'IIS:\Sites\Default Web Site'

# Bind SSL cert to HTTPS binding
$thumbprint = (Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -like '*app01*' } |
    Select-Object -First 1).Thumbprint

if ($thumbprint) {
    $binding = Get-WebBinding -Name 'Default Web Site' -Protocol https
    $binding.AddSslCertificate($thumbprint, 'My')
    Write-Host "     SSL cert bound to HTTPS binding." -ForegroundColor Green
} else {
    Write-Host "     WARNING: No cert found for app01. Bind manually after cert enrollment." -ForegroundColor Yellow
}

# Create app pool with domain service account
New-WebAppPool -Name 'AdLabAppPool' -ErrorAction SilentlyContinue
Set-ItemProperty IIS:\AppPools\AdLabAppPool processModel.identityType -Value 2
Set-ItemProperty IIS:\AppPools\AdLabAppPool processModel.userName -Value 'ADLAB\Administrator'
Set-ItemProperty IIS:\AppPools\AdLabAppPool processModel.password -Value ''

Write-Host "     IIS configured: HTTPS only, Windows Auth, AdLabAppPool." -ForegroundColor Green

# Step 7 - Firewall rules
Write-Host "[7/7] Configuring firewall rules..." -ForegroundColor Cyan
New-NetFirewallRule -DisplayName 'IIS HTTPS Inbound' `
    -Direction Inbound -Protocol TCP -LocalPort 443 `
    -Action Allow -Profile Domain `
    -ErrorAction SilentlyContinue
Write-Host "     Firewall rule added: TCP 443 inbound." -ForegroundColor Green

Write-Host ""
Write-Host "APP01 configuration complete." -ForegroundColor Green
Write-Host "Test from browser (via ssh tunnel or jump01):" -ForegroundColor Cyan
Write-Host "  https://app01.ad.lab" -ForegroundColor White
Get-Website | Select-Object Name, State, PhysicalPath
