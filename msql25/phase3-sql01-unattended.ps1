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
#    media, which also has a root-level setup.exe, by the presence of
#    SqlSetupBootstrapper.dll - unique to the SQL Server install media.
#    NOTE: SQL Server 2025 media dropped the old x64\setup.exe path -
#    the bootstrapper now lives at the media root as plain setup.exe.
# ---------------------------------------------------------------------
Write-Log "Looking for SQL Server install media among attached optical drives..."
$sqlDrive = $null
$deadline = (Get-Date).AddMinutes(5)
while (-not $sqlDrive -and (Get-Date) -lt $deadline) {
    # Get-Volume (Storage Management API) does not reliably enumerate
    # optical/CD-ROM volumes on this platform (QEMU SATA CD-ROMs under
    # Windows Server) - it can come back empty even with media loaded
    # and a drive letter assigned. Win32_CDROMDrive (legacy WMI class)
    # sees them correctly, so use that instead.
    $cdroms = Get-CimInstance Win32_CDROMDrive -ErrorAction SilentlyContinue |
        Where-Object { $_.MediaLoaded -and $_.Drive }
    foreach ($vol in $cdroms) {
        $marker = Join-Path $vol.Drive 'SqlSetupBootstrapper.dll'
        $setup  = Join-Path $vol.Drive 'setup.exe'
        if ((Test-Path $marker) -and (Test-Path $setup)) {
            $sqlDrive = $vol.Drive
            break
        }
    }
    if (-not $sqlDrive) {
        Write-Log "SQL media not visible yet, retrying in 5s..."
        Start-Sleep -Seconds 5
    }
}

if (-not $sqlDrive) {
    Write-Log "ERROR: could not find SQL Server install media (setup.exe + SqlSetupBootstrapper.dll) on any attached CD-ROM after 5 minutes."
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
# 5. Locate sqlcmd.exe (setup.exe installs it under the ODBC Client SDK
#    path, e.g. ...\Client SDK\ODBC\180\Tools\Binn\, but never adds it
#    to PATH), add its folder to the machine PATH permanently so it's
#    usable from any future session/RDP login, then verify @@VERSION.
#    ODBC Driver 18+ defaults to encrypted connections and validates
#    the server cert, which fails against this instance's self-signed
#    cert - pass -C to trust it, same as connecting from a lab/dev tool.
# ---------------------------------------------------------------------
Write-Log "Locating sqlcmd.exe..."
$sqlcmdExe = Get-ChildItem "C:\Program Files\Microsoft SQL Server" -Recurse -Filter 'sqlcmd.exe' -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName

if (-not $sqlcmdExe) {
    Write-Log "WARNING: sqlcmd.exe not found under C:\Program Files\Microsoft SQL Server. Instance may still be fine - verify manually."
} else {
    $sqlcmdDir = Split-Path $sqlcmdExe -Parent
    Write-Log "Found sqlcmd.exe at $sqlcmdExe"

    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($machinePath -split ';') -notcontains $sqlcmdDir) {
        [Environment]::SetEnvironmentVariable('Path', "$machinePath;$sqlcmdDir", 'Machine')
        Write-Log "Added $sqlcmdDir to the machine PATH (persists across sessions/reboots)."
    } else {
        Write-Log "$sqlcmdDir already on the machine PATH."
    }
    # Update this process's PATH too, so the verification below works
    # without needing a new session.
    $env:Path = "$env:Path;$sqlcmdDir"

    Write-Log "Verifying instance with sqlcmd..."
    try {
        $version = & $sqlcmdExe -S localhost -U sa -P $saPassword -C -Q "SET NOCOUNT ON; SELECT @@VERSION;" -h -1
        Write-Log "sqlcmd verification succeeded: $($version -join ' ')"
        Set-Content -Path $StageFile -Value '2'
    } catch {
        Write-Log "WARNING: sqlcmd verification failed ($_). Instance may still be fine - verify manually."
    }
}

New-Item -Path $MarkerFile -ItemType File -Force | Out-Null
Write-Log "=== sql01 phase3 provisioning finished ==="
