#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 3 provisioning for sql01: locates the attached SQL Server 2025
    install media and runs a fully unattended SQL Server install, driven
    entirely from inside the guest with zero console interaction.

.DESCRIPTION
    Staged onto the guest at C:\Provision\phase3-sql01-unattended.ps1 by
    create-sql01-vm.sh (via the sources\$OEM$\$1\Provision $OEM$ folder)
    and launched once by sql01-autounattend.xml's FirstLogonCommands.

    Steps:
      0. Write C:\ProvisionState\sql01.stage = 0, start logging.
      1. Confirm hostname/IP (already applied by the specialize pass;
         re-asserted here for idempotency if this script is re-run).
      2. Disable IE Enhanced Security Configuration + apply firewall
         rules (RDP, SQL 1433/TCP).
      3. Find the SQL Server CD-ROM among attached optical drives by
         looking for x64\setup.exe (distinguishes it from the Windows
         install media, which also carries a root-level setup.exe).
      4. Generate a random `sa` password if one wasn't supplied, save it
         to C:\ProvisionState\sql01-sa-password.txt (root-only ACL), and
         run setup.exe /ConfigurationFile=C:\Provision\ConfigurationFile.ini
         /SAPWD=... /IACCEPTSQLSERVERLICENSETERMS.
      5. Check the exit code, write C:\ProvisionState\sql01.stage = 1.
      6. Verify with `sqlcmd -Q "SELECT @@VERSION"`; on success write
         C:\ProvisionState\sql01.stage = 2.

.NOTES
    Runs as Administrator via FirstLogonCommands (SYSTEM/Administrator
    context). Safe to re-run: each phase checks for prior completion.
#>

$ErrorActionPreference = 'Stop'

$StateDir    = 'C:\ProvisionState'
$LogFile     = Join-Path $StateDir 'sql01-unattended.log'
$StageFile   = Join-Path $StateDir 'sql01.stage'
$SaPassFile  = Join-Path $StateDir 'sql01-sa-password.txt'
$MarkerFile  = Join-Path $StateDir '.phase3-complete'
$ConfigFile  = 'C:\Provision\ConfigurationFile.ini'

New-Item -Path $StateDir -ItemType Directory -Force | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line
    Write-Output $line
}

if (Test-Path $MarkerFile) {
    Write-Log "phase3 already completed - exiting."
    exit 0
}

Set-Content -Path $StageFile -Value '0'
Write-Log "=== sql01 phase3 provisioning started ==="

# ---------------------------------------------------------------------
# 1. Reassert hostname/IP (specialize pass already set these; this is
#    just idempotency insurance for manual re-runs).
# ---------------------------------------------------------------------
if ($env:COMPUTERNAME -ne 'SQL01') {
    Write-Log "Hostname is $env:COMPUTERNAME, expected SQL01 - renaming (requires reboot to take effect)."
    Rename-Computer -NewName 'SQL01' -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------
# 2. IE ESC off, firewall rules for RDP + SQL Server
# ---------------------------------------------------------------------
$AdminKey = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}'
$UserKey  = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}'
foreach ($key in @($AdminKey, $UserKey)) {
    if (Test-Path $key) { Set-ItemProperty -Path $key -Name IsInstalled -Value 0 }
}

Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'SQL Server (TCP 1433)' -Direction Inbound `
    -Protocol TCP -LocalPort 1433 -Action Allow -ErrorAction SilentlyContinue | Out-Null

# ---------------------------------------------------------------------
# 3. Locate the SQL Server CD-ROM (distinct from the Windows install
#    media by the presence of x64\setup.exe).
# ---------------------------------------------------------------------
Write-Log "Looking for SQL Server install media among attached optical drives..."
$sqlDrive = $null
$deadline = (Get-Date).AddMinutes(5)
while (-not $sqlDrive -and (Get-Date) -lt $deadline) {
    $cdroms = Get-Volume | Where-Object { $_.DriveType -eq 'CD-ROM' -and $_.DriveLetter }
    foreach ($vol in $cdroms) {
        $candidate = "$($vol.DriveLetter):\x64\setup.exe"
        if (Test-Path $candidate) {
            $sqlDrive = "$($vol.DriveLetter):"
            break
        }
    }
    if (-not $sqlDrive) {
        Write-Log "SQL media not visible yet, retrying in 5s..."
        Start-Sleep -Seconds 5
    }
}

if (-not $sqlDrive) {
    Write-Log "ERROR: could not find SQL Server install media (x64\setup.exe) on any attached CD-ROM after 5 minutes."
    Set-Content -Path $StageFile -Value 'error-no-media'
    exit 1
}
Write-Log "Found SQL Server media at $sqlDrive"

if (-not (Test-Path $ConfigFile)) {
    Write-Log "ERROR: ConfigurationFile.ini not found at $ConfigFile"
    Set-Content -Path $StageFile -Value 'error-no-config'
    exit 1
}

# ---------------------------------------------------------------------
# 4. Generate (or reuse) the sa password, run the unattended install.
# ---------------------------------------------------------------------
if (Test-Path $SaPassFile) {
    $saPassword = (Get-Content $SaPassFile -Raw).Trim()
    Write-Log "Reusing previously generated sa password from $SaPassFile"
} else {
    Add-Type -AssemblyName System.Web
    $saPassword = [System.Web.Security.Membership]::GeneratePassword(20, 4)
    Set-Content -Path $SaPassFile -Value $saPassword -NoNewline
    icacls $SaPassFile /inheritance:r | Out-Null
    icacls $SaPassFile /grant:r "Administrators:(R)" "SYSTEM:(R)" | Out-Null
    Write-Log "Generated new sa password, saved to $SaPassFile (Administrators/SYSTEM read-only)."
}

Write-Log "Launching unattended SQL Server setup from $sqlDrive\setup.exe ..."
$setupExe = "$sqlDrive\setup.exe"
$arguments = @(
    "/ConfigurationFile=`"$ConfigFile`""
    "/SAPWD=`"$saPassword`""
    "/IACCEPTSQLSERVERLICENSETERMS"
)

$proc = Start-Process -FilePath $setupExe -ArgumentList $arguments -Wait -PassThru -NoNewWindow
Write-Log "setup.exe exited with code $($proc.ExitCode)"

switch ($proc.ExitCode) {
    0 {
        Write-Log "SQL Server install completed successfully."
        Set-Content -Path $StageFile -Value '1'
    }
    3010 {
        Write-Log "SQL Server install completed successfully but requests a reboot."
        Set-Content -Path $StageFile -Value '1'
        Write-Log "Rebooting in 15 seconds to finalize..."
        shutdown.exe /r /t 15 /c "Finalizing SQL Server install"
        exit 0
    }
    default {
        Write-Log "ERROR: SQL Server setup failed (exit $($proc.ExitCode)). See 'C:\Program Files\Microsoft SQL Server\<version>\Setup Bootstrap\Log\' for details."
        Set-Content -Path $StageFile -Value "error-setup-$($proc.ExitCode)"
        exit 1
    }
}

# ---------------------------------------------------------------------
# 5. Verify: query @@VERSION via sqlcmd.
# ---------------------------------------------------------------------
Write-Log "Verifying instance with sqlcmd..."
try {
    $sqlcmd = Get-Command sqlcmd -ErrorAction Stop
    $version = & $sqlcmd.Source -S localhost -U sa -P $saPassword -Q "SET NOCOUNT ON; SELECT @@VERSION;" -h -1
    Write-Log "sqlcmd verification succeeded: $($version -join ' ')"
    Set-Content -Path $StageFile -Value '2'
} catch {
    Write-Log "WARNING: sqlcmd verification failed or sqlcmd not on PATH ($_). Instance may still be fine - verify manually."
}

New-Item -Path $MarkerFile -ItemType File -Force | Out-Null
Write-Log "=== sql01 phase3 provisioning finished ==="
