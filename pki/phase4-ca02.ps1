# phase4-ca02.ps1
# Run on ca02 — Windows Server 2022 Core
# Joins domain, installs enterprise subordinate CA, generates CSR
# IP: 10.0.1.21/24
# PREREQUISITE: ca01 must be configured and root cert on \\AD01\PKITransfer

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Step 1 — Rename ───────────────────────────────────────────
Write-Host "[1/7] Renaming computer to CA02..." -ForegroundColor Cyan
if ($env:COMPUTERNAME -ne 'CA02') {
    Rename-Computer -NewName 'CA02' -Force
    Write-Host "     Renamed. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already CA02." -ForegroundColor Green

# ── Step 2 — Static IP ────────────────────────────────────────
Write-Host "[2/7] Setting static IP 10.0.1.21/24..." -ForegroundColor Cyan
$ifIndex = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }).InterfaceIndex
Remove-NetIPAddress   -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute       -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress      -InterfaceIndex $ifIndex -IPAddress '10.0.1.21' -PrefixLength 24 -DefaultGateway '10.0.1.1'
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses '10.0.1.10','10.0.1.11'
Start-Sleep -Seconds 5
Write-Host "     IP set: 10.0.1.21/24" -ForegroundColor Green

# ── Step 3 — Verify connectivity ──────────────────────────────
Write-Host "[3/7] Verifying domain connectivity..." -ForegroundColor Cyan
Start-Sleep -Seconds 10
if (-not (Test-Connection -ComputerName '10.0.1.10' -Count 2 -Quiet -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Cannot reach ad01. Check networking." -ForegroundColor Red
    exit 1
}
Write-Host "     ad01 reachable." -ForegroundColor Green

# ── Step 4 — Join domain ──────────────────────────────────────
Write-Host "[4/7] Joining domain ad.lab..." -ForegroundColor Cyan
$domainCred = Get-Credential -Message "Enter ADLAB\Administrator credentials" `
    -UserName 'ADLAB\Administrator'
Add-Computer -DomainName 'ad.lab' -Credential $domainCred -Force
Write-Host "     Domain joined. Rebooting..." -ForegroundColor Yellow
Restart-Computer -Force
# After reboot run this script again — it will continue from step 5
