# phase4-ca01.ps1
# Run on ca01 - Windows Server 2022 Core
# Configures offline standalone root CA for ad.lab
# IP: 10.0.1.20/24

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Step 1 - Rename
Write-Host "[1/6] Renaming computer to CA01..." -ForegroundColor Cyan
if ($env:COMPUTERNAME -ne 'CA01') {
    Rename-Computer -NewName 'CA01' -Force
    Write-Host "     Renamed. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already CA01." -ForegroundColor Green

# Step 2 - Static IP
Write-Host "[2/6] Setting static IP 10.0.1.20/24..." -ForegroundColor Cyan
$ifIndex = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }).InterfaceIndex
Remove-NetIPAddress -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress '10.0.1.20' -PrefixLength 24 -DefaultGateway '10.0.1.1'
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses '10.0.1.10','10.0.1.11'
Write-Host "     IP set: 10.0.1.20/24" -ForegroundColor Green

# Step 3 - Install ADCS
Write-Host "[3/6] Installing AD Certificate Services..." -ForegroundColor Cyan
Install-WindowsFeature -Name ADCS-Cert-Authority -IncludeManagementTools
Write-Host "     Feature installed." -ForegroundColor Green

# Step 4 - Configure standalone root CA
Write-Host "[4/6] Configuring standalone root CA..." -ForegroundColor Cyan
Install-AdcsCertificationAuthority `
    -CAType                    StandaloneRootCa `
    -CACommonName              'ADLAB-ROOT-CA' `
    -CADistinguishedNameSuffix 'DC=ad,DC=lab' `
    -KeyLength                 4096 `
    -HashAlgorithmName         SHA256 `
    -ValidityPeriod            Years `
    -ValidityPeriodUnits       10 `
    -CryptoProviderName        'RSA#Microsoft Software Key Storage Provider' `
    -Force
Write-Host "     Root CA installed." -ForegroundColor Green

# Step 5 - CRL settings
Write-Host "[5/6] Configuring CRL settings..." -ForegroundColor Cyan
certutil -setreg CA\CRLPeriodUnits 1
certutil -setreg CA\CRLPeriod "Years"
certutil -setreg CA\CRLDeltaPeriodUnits 0
certutil -setreg CA\CRLDeltaPeriod "Days"
certutil -setreg CA\ValidityPeriodUnits 5
certutil -setreg CA\ValidityPeriod "Years"
Restart-Service certsvc
Start-Sleep -Seconds 5
certutil -crl
Write-Host "     CRL published." -ForegroundColor Green

# Step 6 - Export root cert and CRL
Write-Host "[6/6] Exporting root cert and CRL to C:\CAExchange..." -ForegroundColor Cyan
$exportPath = 'C:\CAExchange'
New-Item -ItemType Directory -Path $exportPath -Force | Out-Null

certutil -ca.cert "$exportPath\ADLAB-ROOT-CA.crt"

$crlDir = 'C:\Windows\System32\CertSrv\CertEnroll'
Copy-Item "$crlDir\*.crl" $exportPath -ErrorAction SilentlyContinue
Copy-Item "$crlDir\*.crt" $exportPath -ErrorAction SilentlyContinue

Write-Host "" 
Write-Host "Root CA configured successfully." -ForegroundColor Green
Write-Host ""
Write-Host "Files in C:\CAExchange:" -ForegroundColor Yellow
Get-ChildItem $exportPath | Select-Object Name, Length
Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Cyan
Write-Host "  1. Copy C:\CAExchange\* to \\AD01\PKITransfer\" -ForegroundColor White
Write-Host "     net use P: \\AD01\PKITransfer /user:ADLAB\Administrator" -ForegroundColor White
Write-Host "     copy C:\CAExchange\* P:\" -ForegroundColor White
Write-Host "  2. Run phase4-ca02.ps1 on ca02" -ForegroundColor White
Write-Host "  3. After ca02 generates CSR, run phase4-ca01-sign.ps1 here" -ForegroundColor White
