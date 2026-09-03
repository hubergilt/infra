<#
  Mounts the SQL Server ISO (attached by deploy-vm.sh as a dedicated
  CD-ROM device), runs setup.exe against ConfigurationFile.ini staged at
  C:\Windows\Setup\Scripts\sql\, and enables the firewall rule for 1433.
  credentials.ps1 (SA_PASSWORD) is generated at answer-ISO build time by
  scripts/make-answer-iso.sh from the host's SA_PASSWORD env var — never
  hardcoded here.
#>
$ErrorActionPreference = "Stop"
$scriptRoot = "C:\Windows\Setup\Scripts"
$sqlConfigDir = Join-Path $scriptRoot "sql"

. (Join-Path $sqlConfigDir "credentials.ps1")   # defines $SA_PASSWORD

# Find the SQL Server install media — attached as its own CD-ROM, identify
# it by setup.exe existing at the root.
$sqlDrive = Get-Volume | Where-Object { $_.DriveType -eq 'CD-ROM' } |
    Where-Object { Test-Path (Join-Path "$($_.DriveLetter):\" "setup.exe") } |
    Select-Object -First 1

if (-not $sqlDrive) {
    throw "Could not locate SQL Server setup.exe on any attached CD-ROM."
}

$setupExe = "$($sqlDrive.DriveLetter):\setup.exe"
$configFile = Join-Path $sqlConfigDir "ConfigurationFile.ini"

Write-Output "Running SQL Server silent install from $setupExe"

$proc = Start-Process -FilePath $setupExe -ArgumentList @(
    "/ConfigurationFile=`"$configFile`"",
    "/SAPWD=`"$SA_PASSWORD`""
) -Wait -PassThru -NoNewWindow

if ($proc.ExitCode -ne 0) {
    throw "SQL Server setup exited with code $($proc.ExitCode). See C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt"
}

Write-Output "SQL Server install completed successfully."
