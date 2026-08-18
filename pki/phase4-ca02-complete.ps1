# phase4-ca02-complete.ps1
# Run on ca02 as ADLAB\Administrator AFTER ca01 has signed the CSR
# Installs signed cert, publishes templates, enables autoenroll GPO

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$transferShare = '\\AD01\PKITransfer'
$localExchange = 'C:\CAExchange'
New-Item -ItemType Directory -Path $localExchange -Force | Out-Null

Write-Host "=== ca02 completing enterprise CA setup ===" -ForegroundColor Cyan

# Step 1 - Get signed certificate from share
Write-Host "[1/5] Fetching signed certificate from share..." -ForegroundColor Cyan
net use P: $transferShare /user:ADLAB\Administrator
copy P:\ca02-signed.crt "$localExchange\ca02-signed.crt"
copy P:\CA01_ADLAB-ROOT-CA.crt "$localExchange\CA01_ADLAB-ROOT-CA.crt"
copy P:\ADLAB-ROOT-CA.crl "$localExchange\ADLAB-ROOT-CA.crl"
net use P: /delete

dir $localExchange
Write-Host "Files retrieved." -ForegroundColor Green

# Step 2 - Install signed certificate into CA
Write-Host "[2/5] Installing signed certificate into CA service..." -ForegroundColor Cyan
certutil -installcert "$localExchange\ca02-signed.crt"

Write-Host "Starting certificate service..." -ForegroundColor Cyan
Start-Service certsvc -ErrorAction SilentlyContinue
Start-Sleep -Seconds 10

$svc = Get-Service certsvc
Write-Host "CertSvc status: $($svc.Status)" -ForegroundColor Green

# Step 3 - Publish root CRL and cert to AD stores
Write-Host "[3/5] Publishing root CA cert and CRL to AD..." -ForegroundColor Cyan
certutil -addstore Root "$localExchange\CA01_ADLAB-ROOT-CA.crt"
certutil -addstore Root "$localExchange\ADLAB-ROOT-CA.crl"
certutil -dspublish -f "$localExchange\CA01_ADLAB-ROOT-CA.crt" RootCA
certutil -dspublish -f "$localExchange\ADLAB-ROOT-CA.crl"

# Publish issuing CA CRL
certutil -crl
Write-Host "CRL published." -ForegroundColor Green

# Step 4 - Publish certificate templates
Write-Host "[4/5] Publishing certificate templates..." -ForegroundColor Cyan
$templates = @(
    'Computer',
    'WebServer',
    'User',
    'DomainController',
    'DomainControllerAuthentication',
    'DirectoryEmailReplication',
    'Workstation'
)

foreach ($t in $templates) {
    try {
        Add-CATemplate -Name $t -Force -ErrorAction SilentlyContinue
        Write-Host "  Added: $t" -ForegroundColor Green
    } catch {
        Write-Host "  Skipped (may exist): $t" -ForegroundColor Yellow
    }
}

# Step 5 - Configure autoenrollment GPO
Write-Host "[5/5] Configuring autoenrollment GPO..." -ForegroundColor Cyan
$gpoName = 'PKI-Autoenrollment'
$domain  = 'ad.lab'

try {
    $gpo = New-GPO -Name $gpoName -Domain $domain
    Write-Host "GPO created: $gpoName" -ForegroundColor Green
} catch {
    $gpo = Get-GPO -Name $gpoName -Domain $domain
    Write-Host "GPO already exists: $gpoName" -ForegroundColor Yellow
}

# AEPolicy value 7 = Enroll + Renew + Update
Set-GPRegistryValue -Name $gpoName -Domain $domain `
    -Key 'HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment' `
    -ValueName 'AEPolicy' -Type DWord -Value 7

Set-GPRegistryValue -Name $gpoName -Domain $domain `
    -Key 'HKCU\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment' `
    -ValueName 'AEPolicy' -Type DWord -Value 7

New-GPLink -Name $gpoName -Domain $domain `
    -Target 'DC=ad,DC=lab' -ErrorAction SilentlyContinue

Write-Host "Autoenrollment GPO linked to domain root." -ForegroundColor Green

# Final verification
Write-Host ""
Write-Host "=== Verification ===" -ForegroundColor Cyan
Write-Host "CA service status:" -ForegroundColor Yellow
Get-Service certsvc | Select-Object Name, Status

Write-Host "Published templates:" -ForegroundColor Yellow
Get-CATemplate | Select-Object Name

Write-Host "CA cert in store:" -ForegroundColor Yellow
Get-ChildItem Cert:\LocalMachine\CA |
    Where-Object { $_.Subject -like '*ADLAB*' } |
    Select-Object Subject, Thumbprint, NotAfter

Write-Host ""
Write-Host "Phase 4 PKI complete." -ForegroundColor Green
Write-Host ""
Write-Host "CA hierarchy:" -ForegroundColor Cyan
Write-Host "  ADLAB-ROOT-CA    (ca01 offline, 10yr validity)" -ForegroundColor White
Write-Host "  ADLAB-ISSUING-CA (ca02 online,  5yr validity)" -ForegroundColor White
Write-Host ""
Write-Host "Verify from any domain member:" -ForegroundColor Cyan
Write-Host "  certutil -ping" -ForegroundColor White
Write-Host "  certutil -verify -urlfetch <cert>" -ForegroundColor White
Write-Host ""
Write-Host "Proceed to Phase 5 - services tier." -ForegroundColor Green