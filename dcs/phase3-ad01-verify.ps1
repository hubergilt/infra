# phase3-ad01-verify.ps1
# Run on ad01 AFTER reboot to verify AD DS and DNS are healthy

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest

Write-Host "=== ad01 post-promotion verification ===" -ForegroundColor Cyan

Write-Host "`n[1] Domain info:" -ForegroundColor Yellow
Get-ADDomain | Select-Object DNSRoot, NetBIOSName, DomainMode, Forest

Write-Host "`n[2] Forest info:" -ForegroundColor Yellow
Get-ADForest | Select-Object Name, ForestMode, SchemaMaster, DomainNamingMaster

Write-Host "`n[3] DC info:" -ForegroundColor Yellow
Get-ADDomainController | Select-Object Name, IPv4Address, IsGlobalCatalog, OperationMasterRoles

Write-Host "`n[4] DNS zones:" -ForegroundColor Yellow
Get-DnsServerZone | Select-Object ZoneName, ZoneType, IsDsIntegrated

Write-Host "`n[5] DCDiag summary:" -ForegroundColor Yellow
dcdiag /test:dns /test:replications /test:services /q

Write-Host "`n[6] DNS resolution test:" -ForegroundColor Yellow
Resolve-DnsName 'ad.lab' -Server '127.0.0.1' -ErrorAction SilentlyContinue

Write-Host "`n[7] FSMO roles:" -ForegroundColor Yellow
netdom query fsmo

Write-Host "`n=== Verification complete ===" -ForegroundColor Cyan
Write-Host "If all tests pass, run phase3-ad02.ps1 on ad02." -ForegroundColor Green
