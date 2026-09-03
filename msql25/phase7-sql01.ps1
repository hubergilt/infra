# phase7-sql01.ps1
# Run on sql01 (Windows Server 2025 Core) — Data tier, lab-data 10.0.6.0/24
# Domain-joins sql01, prepares the F: data disk, and runs an unattended
# SQL Server 2025 install from the attached ISO using ConfigurationFile.ini.
#
# Prereqs:
#   - create-sql01-unattend.sh has completed (Windows installed, static IP set)
#   - attach-sql-iso.sh has attached SQLServer2025-x64-ENU-EntDev.iso
#   - ConfigurationFile.ini is present alongside this script (copied in by
#     deploy-sql01.sh, or manually via scp)
# IP: 10.0.6.70/24  GW: 10.0.6.1  DNS: 10.0.7.10, 10.0.7.11 (ad01/ad02)

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$IniPath   = Join-Path $ScriptDir 'ConfigurationFile.ini'

# ── Step 1 — Confirm hostname + static IP (idempotent) ─────────────────
Write-Host "[1/7] Verifying hostname and static IP..." -ForegroundColor Cyan
if ($env:COMPUTERNAME -ne 'SQL01') {
    Rename-Computer -NewName 'SQL01' -Force
    Write-Host "     Renamed. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
$ifIndex = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1).InterfaceIndex
$currentIp = (Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
if ($currentIp -ne '10.0.6.70') {
    Remove-NetIPAddress -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute     -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress    -InterfaceIndex $ifIndex -IPAddress '10.0.6.70' -PrefixLength 24 -DefaultGateway '10.0.6.1'
    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses '10.0.7.10','10.0.7.11'
    Start-Sleep -Seconds 5
}
Write-Host "     SQL01 @ 10.0.6.70/24, DNS -> ad01/ad02." -ForegroundColor Green

# ── Step 2 — Join domain ad.lab ────────────────────────────────────────
Write-Host "[2/7] Joining domain ad.lab..." -ForegroundColor Cyan
if ((Get-WmiObject Win32_ComputerSystem).Domain -ne 'ad.lab') {
    $cred = Get-Credential -Message "Enter ADLAB\Administrator" -UserName 'ADLAB\Administrator'
    Add-Computer -DomainName 'ad.lab' -Credential $cred -Force
    Write-Host "     Domain joined. Rebooting — re-run this script after logon." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already domain member (ad.lab)." -ForegroundColor Green

# ── Step 3 — Initialize the SQL data disk as F: (idempotent) ──────────
Write-Host "[3/7] Preparing SQL data disk..." -ForegroundColor Cyan
$dataDisk = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' -and $_.OperationalStatus -eq 'Offline' } | Select-Object -First 1
if ($dataDisk) {
    Write-Host "     Initializing raw disk $($dataDisk.Number)..." -ForegroundColor Yellow
    Initialize-Disk -Number $dataDisk.Number -PartitionStyle GPT
    $part = New-Partition -DiskNumber $dataDisk.Number -UseMaximumSize -DriveLetter F
    Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel 'SQLData' -Confirm:$false | Out-Null
}
if (-not (Test-Path 'F:\')) {
    throw "F: drive not present — check that the second (virtio) disk from create-sql01-unattend.sh is attached."
}
New-Item -ItemType Directory -Force -Path 'F:\SQLData','F:\SQLLogs','F:\SQLTempDB','F:\SQLBackup' | Out-Null
Write-Host "     F: ready — SQLData / SQLLogs / SQLTempDB / SQLBackup." -ForegroundColor Green

# ── Step 4 — Locate SQL Server setup media ─────────────────────────────
Write-Host "[4/7] Locating SQL Server install media..." -ForegroundColor Cyan
$sqlDrive = Get-Volume | Where-Object { $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\setup.exe") } | Select-Object -First 1
if (-not $sqlDrive) {
    throw "setup.exe not found on any drive. Run attach-sql-iso.sh on the host, then retry."
}
$setupExe = "$($sqlDrive.DriveLetter):\setup.exe"
Write-Host "     Found: $setupExe" -ForegroundColor Green

if (-not (Test-Path $IniPath)) {
    throw "ConfigurationFile.ini not found at $IniPath — copy it alongside this script first."
}

# ── Step 5 — Unattended SQL Server install (idempotent) ────────────────
Write-Host "[5/7] Running unattended SQL Server 2025 install (5-15 min)..." -ForegroundColor Cyan
$svc = Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
if (-not $svc) {
    $proc = Start-Process -FilePath $setupExe `
        -ArgumentList "/ConfigurationFile=`"$IniPath`"", "/IACCEPTSQLSERVERLICENSETERMS" `
        -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        throw "SQL Server setup exited with code $($proc.ExitCode). Check C:\Program Files\Microsoft SQL Server\...\Setup Bootstrap\Log\Summary.txt"
    }
    Write-Host "     SQL Server Database Engine installed." -ForegroundColor Green
} else {
    Write-Host "     MSSQLSERVER service already present, skipping install." -ForegroundColor Green
}

# ── Step 6 — Fix TCP port to 1433 (idempotent) ─────────────────────────
Write-Host "[6/7] Pinning TCP/IP to static port 1433..." -ForegroundColor Cyan
Import-Module SqlServer -ErrorAction SilentlyContinue
try {
    $wmi = New-Object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer
    $instance = $wmi.ServerInstances['MSSQLSERVER']
    $tcp = $instance.ServerProtocols['Tcp']
    $tcp.IsEnabled = $true
    foreach ($ip in $tcp.IPAddresses) {
        $ip.IPAddressProperties['TcpDynamicPorts'].Value = ''
        $ip.IPAddressProperties['TcpPort'].Value = '1433'
    }
    $tcp.Alter()
    Write-Host "     TCP fixed to 1433 on all IPs." -ForegroundColor Green
    Restart-Service -Name MSSQLSERVER -Force
} catch {
    Write-Host "     WARNING: Could not set TCP port via SMO WMI ($($_.Exception.Message))." -ForegroundColor Yellow
    Write-Host "     Set it manually via SQL Server Configuration Manager if needed." -ForegroundColor Yellow
}

# ── Step 7 — Firewall rule for 1433 ─────────────────────────────────────
Write-Host "[7/7] Opening firewall for SQL Server (TCP 1433)..." -ForegroundColor Cyan
New-NetFirewallRule -DisplayName 'SQL Server TCP 1433' `
    -Direction Inbound -Protocol TCP -LocalPort 1433 `
    -Action Allow -Profile Domain `
    -ErrorAction SilentlyContinue
Write-Host "     Firewall rule added: TCP 1433 inbound." -ForegroundColor Green

Write-Host ""
Write-Host "SQL01 configuration complete." -ForegroundColor Green
Write-Host "Run .\phase7-sql01-verify.ps1 to confirm everything is healthy." -ForegroundColor Cyan
Get-Service MSSQLSERVER, SQLSERVERAGENT | Select-Object Name, Status, StartType
