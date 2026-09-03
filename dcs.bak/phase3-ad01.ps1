# phase3-ad01.ps1
# Run on ad01 (win19) — Windows Server Core
# Promotes ad01 as primary DC and forest root for ad.lab
# IP: 10.0.1.10/24  GW: 10.0.1.1  DNS: 127.0.0.1

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Step 1 — Rename computer ──────────────────────────────────
Write-Host "[1/5] Renaming computer to ad01..." -ForegroundColor Cyan
$currentName = $env:COMPUTERNAME
if ($currentName -ne 'AD01') {
    Rename-Computer -NewName 'AD01' -Force
    Write-Host "     Renamed from $currentName to AD01. Will apply after reboot." -ForegroundColor Yellow
} else {
    Write-Host "     Already named AD01, skipping." -ForegroundColor Green
}

# ── Step 2 — Set static IP ────────────────────────────────────
Write-Host "[2/5] Configuring static IP 10.0.1.10/24..." -ForegroundColor Cyan
$ifIndex = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }).InterfaceIndex

# Remove existing IP/GW if any
Remove-NetIPAddress -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue

New-NetIPAddress `
    -InterfaceIndex  $ifIndex `
    -IPAddress       '10.0.1.10' `
    -PrefixLength    24 `
    -DefaultGateway  '10.0.1.1'

# DNS points to itself — required before AD DS install
Set-DnsClientServerAddress `
    -InterfaceIndex  $ifIndex `
    -ServerAddresses '127.0.0.1','10.0.1.10'

Write-Host "     IP set. Verifying..." -ForegroundColor Green
Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 |
    Select-Object IPAddress, PrefixLength

# ── Step 3 — Install AD DS + DNS ─────────────────────────────
Write-Host "[3/5] Installing AD DS and DNS features..." -ForegroundColor Cyan
Install-WindowsFeature `
    -Name AD-Domain-Services, DNS `
    -IncludeManagementTools

Write-Host "     Features installed." -ForegroundColor Green

# ── Step 4 — Promote as forest root ──────────────────────────
Write-Host "[4/5] Promoting ad01 as forest root for ad.lab..." -ForegroundColor Cyan
Write-Host "     This will reboot automatically when complete." -ForegroundColor Yellow

$safeModePassword = ConvertTo-SecureString `
    'Server2012!' -AsPlainText -Force

Install-ADDSForest `
    -DomainName                    'ad.lab' `
    -DomainNetbiosName             'ADLAB' `
    -ForestMode                    'WinThreshold' `
    -DomainMode                    'WinThreshold' `
    -InstallDns                    `
    -SafeModeAdministratorPassword $safeModePassword `
    -NoRebootOnCompletion:$false `
    -Force

# ── Step 5 — Post-reboot verification (run after reboot) ──────
# After reboot run: .\phase3-ad01-verify.ps1
Write-Host "[5/5] Promotion triggered. VM will reboot..." -ForegroundColor Green
