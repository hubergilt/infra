# phase3-ad02.ps1
# Run on ad02 (win22) — Windows Server Core
# Promotes ad02 as replica DC for ad.lab
# IP: 10.0.1.11/24  GW: 10.0.1.1  DNS: 10.0.1.10 (ad01)
# PREREQUISITE: ad01 must be fully promoted and verified first

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Step 1 — Rename computer ──────────────────────────────────
Write-Host "[1/5] Renaming computer to ad02..." -ForegroundColor Cyan
$currentName = $env:COMPUTERNAME
if ($currentName -ne 'AD02') {
    Rename-Computer -NewName 'AD02' -Force
    Write-Host "     Renamed from $currentName to AD02." -ForegroundColor Yellow
    Write-Host "     Rebooting to apply name..." -ForegroundColor Yellow
    Restart-Computer -Force
    # Script will stop here — rerun after reboot
    exit
} else {
    Write-Host "     Already named AD02, skipping." -ForegroundColor Green
}

# ── Step 2 — Set static IP ────────────────────────────────────
Write-Host "[2/5] Configuring static IP 10.0.1.11/24..." -ForegroundColor Cyan
$ifIndex = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }).InterfaceIndex

Remove-NetIPAddress -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue

New-NetIPAddress `
    -InterfaceIndex  $ifIndex `
    -IPAddress       '10.0.1.11' `
    -PrefixLength    24 `
    -DefaultGateway  '10.0.1.1'

# DNS must point to ad01 first, then itself as secondary
Set-DnsClientServerAddress `
    -InterfaceIndex  $ifIndex `
    -ServerAddresses '10.0.1.10','10.0.1.11'

Write-Host "     IP set." -ForegroundColor Green
Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 |
    Select-Object IPAddress, PrefixLength

# ── Step 3 — Verify connectivity to ad01 ─────────────────────
Write-Host "[3/5] Verifying connectivity to ad01..." -ForegroundColor Cyan


Start-Sleep -Seconds 10
$ping = Test-Connection -ComputerName '10.0.1.10' -Count 2 -Quiet -ErrorAction SilentlyContinue
if (-not $ping) {
    Write-Host "ERROR: Cannot reach ad01 at 10.0.1.10." -ForegroundColor Red
    Write-Host "       Ensure ad01 is running and promoted before continuing." -ForegroundColor Red
    exit 1
}

if (-not (Resolve-DnsName 'ad.lab' -Server '10.0.1.10' -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: DNS resolution for ad.lab failed via ad01." -ForegroundColor Red
    Write-Host "       Check DNS on ad01 is running correctly." -ForegroundColor Red
    exit 1
}

Write-Host "     ad01 reachable and DNS working." -ForegroundColor Green

# ── Step 4 — Install AD DS ────────────────────────────────────
Write-Host "[4/5] Installing AD DS feature..." -ForegroundColor Cyan
Install-WindowsFeature `
    -Name AD-Domain-Services `
    -IncludeManagementTools

Write-Host "     Feature installed." -ForegroundColor Green

# ── Step 5 — Promote as replica DC ───────────────────────────
Write-Host "[5/5] Promoting ad02 as replica DC for ad.lab..." -ForegroundColor Cyan
Write-Host "      Enter ADLAB\Administrator credentials when prompted." -ForegroundColor Yellow

$safeModePassword = ConvertTo-SecureString `
    'Server2012!' -AsPlainText -Force

$domainCred = Get-Credential -Message "Enter ADLAB\Administrator credentials" `
    -UserName 'ADLAB\Administrator'

Install-ADDSDomainController `
    -DomainName                    'ad.lab' `
    -InstallDns                    `
    -Credential                    $domainCred `
    -SafeModeAdministratorPassword $safeModePassword `
    -NoRebootOnCompletion:$false `
    -Force

Write-Host "Promotion triggered. VM will reboot..." -ForegroundColor Green
