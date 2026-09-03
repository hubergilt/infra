# phase7-sql01-verify.ps1
# Run on sql01 after phase7-sql01.ps1 to confirm the engine is healthy,
# reachable, and correctly placed on the data tier.

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest

Write-Host "=== sql01 post-install verification ===" -ForegroundColor Cyan

Write-Host "`n[1] Domain membership:" -ForegroundColor Yellow
Get-WmiObject Win32_ComputerSystem | Select-Object Name, Domain, PartOfDomain

Write-Host "`n[2] Network config:" -ForegroundColor Yellow
Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, IPAddress, PrefixLength
Get-DnsClientServerAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, ServerAddresses

Write-Host "`n[3] SQL Server services:" -ForegroundColor Yellow
Get-Service MSSQLSERVER, SQLSERVERAGENT | Select-Object Name, Status, StartType

Write-Host "`n[4] TCP 1433 listener:" -ForegroundColor Yellow
Get-NetTCPConnection -LocalPort 1433 -State Listen -ErrorAction SilentlyContinue |
    Select-Object LocalAddress, LocalPort, State
Test-NetConnection -ComputerName localhost -Port 1433 | Select-Object ComputerName, TcpTestSucceeded

Write-Host "`n[5] Firewall rule:" -ForegroundColor Yellow
Get-NetFirewallRule -DisplayName 'SQL Server TCP 1433' -ErrorAction SilentlyContinue |
    Select-Object DisplayName, Enabled, Direction, Action

Write-Host "`n[6] F: data disk layout:" -ForegroundColor Yellow
Get-Volume -DriveLetter F -ErrorAction SilentlyContinue |
    Select-Object DriveLetter, FileSystemLabel, SizeRemaining, Size
Get-ChildItem 'F:\' -ErrorAction SilentlyContinue | Select-Object Name

Write-Host "`n[7] Engine query (sqlcmd, Windows Auth):" -ForegroundColor Yellow
try {
    sqlcmd -S localhost -E -Q "SELECT SERVERPROPERTY('ProductVersion') AS Version, SERVERPROPERTY('Edition') AS Edition, @@SERVERNAME AS ServerName"
} catch {
    Write-Host "     sqlcmd not on PATH or engine not responding: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n[8] Data file placement (should all be under F:\):" -ForegroundColor Yellow
try {
    sqlcmd -S localhost -E -Q "SELECT name, physical_name FROM sys.master_files"
} catch {
    Write-Host "     Could not query sys.master_files." -ForegroundColor Red
}

Write-Host "`n=== Verification complete ===" -ForegroundColor Cyan
Write-Host "From app01/jump01, confirm reachability with:" -ForegroundColor Green
Write-Host "  Test-NetConnection sql01.ad.lab -Port 1433" -ForegroundColor White
Write-Host "  sqlcmd -S sql01.ad.lab -E -Q `"SELECT @@VERSION`"" -ForegroundColor White
