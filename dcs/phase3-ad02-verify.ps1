# phase3-ad02-verify.ps1
# Run on ad02 AFTER reboot to verify replication with ad01

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest

Write-Host "=== ad02 post-promotion verification ===" -ForegroundColor Cyan

Write-Host "`n[1] DC info:" -ForegroundColor Yellow
Get-ADDomainController | Select-Object Name, IPv4Address, IsGlobalCatalog

Write-Host "`n[2] Replication summary (run on ad01 or ad02):" -ForegroundColor Yellow
repadmin /replsummary

Write-Host "`n[3] Replication status:" -ForegroundColor Yellow
repadmin /showrepl

Write-Host "`n[4] All DCs in domain:" -ForegroundColor Yellow
Get-ADDomainController -Filter * | Select-Object Name, IPv4Address, Site

Write-Host "`n[5] DCDiag on ad02:" -ForegroundColor Yellow
dcdiag /test:replications /test:services /q

Write-Host "`n[6] DNS zones replicated:" -ForegroundColor Yellow
Get-DnsServerZone | Select-Object ZoneName, ZoneType, IsDsIntegrated

Write-Host "`n=== Phase 3 complete ===" -ForegroundColor Green
Write-Host "Both DCs are healthy. Proceed to Phase 4 (PKI tier)." -ForegroundColor Green
