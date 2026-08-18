# phase4-ca02-part2.ps1
# Run on ca02 AFTER domain-join reboot
# Installs enterprise subordinate CA and generates CSR
# PREREQUISITE: Root cert files must be on \\AD01\PKITransfer\

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$transferShare = '\\AD01\PKITransfer'
$localExchange = 'C:\CAExchange'
New-Item -ItemType Directory -Path $localExchange -Force | Out-Null

# ── Step 5 — Import root CA cert and CRL ──────────────────────
Write-Host "[5/7] Importing root CA certificate and CRL from $transferShare..." -ForegroundColor Cyan

# Map the transfer share
$shareCred = Get-Credential -Message "Enter ADLAB\Administrator for share access" `
    -UserName 'ADLAB\Administrator'
New-PSDrive -Name PKI -PSProvider FileSystem -Root $transferShare -Credential $shareCred

# Copy files locally
Copy-Item 'PKI:\*' $localExchange -ErrorAction SilentlyContinue
Write-Host "     Files copied:" -ForegroundColor Green
Get-ChildItem $localExchange

# Publish root cert to AD and local store
$rootCert = Get-ChildItem $localExchange -Filter '*.crt' | Select-Object -First 1
if (-not $rootCert) {
    Write-Host "ERROR: Root cert not found in $localExchange" -ForegroundColor Red
    exit 1
}

# Install root cert into local machine trusted root store
certutil -addstore Root $rootCert.FullName

# Publish root cert and CRL to AD
certutil -dspublish -f $rootCert.FullName RootCA
$crlFile = Get-ChildItem $localExchange -Filter '*.crl' | Select-Object -First 1
if ($crlFile) {
    certutil -addstore Root $crlFile.FullName
    certutil -dspublish -f $crlFile.FullName
}

Write-Host "     Root cert published to AD and local store." -ForegroundColor Green

# ── Step 6 — Install ADCS enterprise subordinate CA ───────────
Write-Host "[6/7] Installing ADCS enterprise subordinate CA..." -ForegroundColor Cyan
Install-WindowsFeature -Name ADCS-Cert-Authority -IncludeManagementTools

# Install as enterprise subordinate — this generates a CSR
# since ca01 is offline we save the CSR to file
Install-AdcsCertificationAuthority `
    -CAType                    EnterpriseSubordinateCa `
    -CACommonName              'ADLAB-ISSUING-CA' `
    -CADistinguishedNameSuffix 'DC=ad,DC=lab' `
    -KeyLength                 2048 `
    -HashAlgorithmName         SHA256 `
    -CryptoProviderName        'RSA#Microsoft Software Key Storage Provider' `
    -OutputCertRequestFile     "$localExchange\ca02.req" `
    -Force

Write-Host "     CSR generated: $localExchange\ca02.req" -ForegroundColor Green

# Copy CSR to transfer share for ca01 to sign
Copy-Item "$localExchange\ca02.req" 'PKI:\ca02.req'
Write-Host "     CSR copied to $transferShare\ca02.req" -ForegroundColor Green

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " NEXT STEPS:" -ForegroundColor Cyan
Write-Host "   1. On ca01: run phase4-ca01-sign.ps1" -ForegroundColor White
Write-Host "      This signs the CSR and saves ca02-signed.crt" -ForegroundColor White
Write-Host "   2. Copy ca02-signed.crt to $transferShare" -ForegroundColor White
Write-Host "   3. On ca02: run phase4-ca02-complete.ps1" -ForegroundColor White
Write-Host "============================================================" -ForegroundColor Green
