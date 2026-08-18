# phase4-ca01-sign.ps1
# Run on ca01 AFTER ca02 has generated its CSR
# Signs the subordinate CA certificate request
# Expects CSR at C:\CAExchange\ca02.req

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$exchangePath = 'C:\CAExchange'
$csrFile      = "$exchangePath\ca02.req"
$certFile     = "$exchangePath\ca02-signed.crt"

Write-Host "=== ca01 signing subordinate CA request ===" -ForegroundColor Cyan

# Get CSR from transfer share
Write-Host "[0/3] Fetching CSR from PKITransfer share..." -ForegroundColor Cyan
net use P: \\AD01\PKITransfer /user:ADLAB\Administrator
copy P:\ca02.req $csrFile
net use P: /delete

if (-not (Test-Path $csrFile)) {
    Write-Host "ERROR: CSR not found at $csrFile" -ForegroundColor Red
    Write-Host "Copy ca02.req from ca02 to C:\CAExchange\ first." -ForegroundColor Red
    exit 1
}

Write-Host "CSR found: $csrFile" -ForegroundColor Green

# Submit CSR to root CA
Write-Host "[1/3] Submitting CSR to root CA..." -ForegroundColor Cyan
$submitOut = certreq -submit -config "CA01\ADLAB-ROOT-CA" -attrib "CertificateTemplate:" $csrFile $certFile 2>&1
Write-Host $submitOut

# Extract request ID
$reqIdLine = $submitOut | Where-Object { $_ -match 'RequestId' } | Select-Object -First 1
$reqId = $null
if ($reqIdLine -match '(\d+)') {
    $reqId = $Matches[1]
}

if (-not $reqId) {
    Write-Host "[1b/3] Checking pending requests in CA..." -ForegroundColor Yellow
    $pendingOut = certutil -view -restrict "Disposition=9" -out "RequestID,RequesterName" 2>&1
    Write-Host $pendingOut

    Write-Host ""
    Write-Host "Enter the RequestID from the list above:" -ForegroundColor Yellow
    $reqId = Read-Host "RequestID"
}

Write-Host "Using RequestID: $reqId" -ForegroundColor Green

# Issue (approve) the certificate
Write-Host "[2/3] Issuing certificate for RequestID $reqId..." -ForegroundColor Cyan
certutil -resubmit $reqId

# Retrieve signed certificate
Write-Host "[3/3] Retrieving signed certificate..." -ForegroundColor Cyan
certutil -retrieve $reqId $certFile

if (Test-Path $certFile) {
    Write-Host "" 
    Write-Host "Signed certificate saved: $certFile" -ForegroundColor Green
    dir $certFile

    Write-Host ""
    Write-Host "Copying signed cert to PKITransfer share..." -ForegroundColor Cyan
    net use P: \\AD01\PKITransfer /user:ADLAB\Administrator
    copy $certFile P:\ca02-signed.crt
    net use P: /delete
    Write-Host "Done. ca02-signed.crt is on the share." -ForegroundColor Green

    Write-Host ""
    Write-Host "NEXT STEPS:" -ForegroundColor Cyan
    Write-Host "  On ca02: run phase4-ca02-complete.ps1" -ForegroundColor White
} else {
    Write-Host "Signed cert not generated. Check CA logs:" -ForegroundColor Red
    Write-Host "  eventvwr (Application log, source CertSvc)" -ForegroundColor Yellow
}