# phase3-ad02-unattended.ps1
# Run ONCE on ad02 (win22) — Windows Server Core
# Fully unattended version of phase3-ad02.ps1 + phase3-ad02-verify.ps1
# PREREQUISITE: ad01 must already show stage 3 (verified) before this runs.
# IP: 10.0.7.11/24  GW: 10.0.7.254  DNS: 10.0.7.10 (ad01)
#
# CREDENTIAL HANDLING
#   phase3-ad02.ps1 blocks on Get-Credential. To run unattended, provide
#   the ADLAB\Administrator password one of two ways:
#     A) Lab-only, matches this repo's existing convention of plaintext
#        DSRM passwords: hardcode via ConvertTo-SecureString -AsPlainText.
#     B) Slightly better: encrypt it once with Export-Clixml under the
#        SAME account/machine context that will later import it, then
#        read it back with Import-Clixml (DPAPI-protected at rest, but
#        only decryptable by that same local account on that same host).
#   This script uses (A) by default and shows (B) commented out below.

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stateDir   = 'C:\ProvisionState'
$stateFile  = Join-Path $stateDir 'ad02.stage'
$taskName   = 'Phase3-AD02-Continue'
$scriptPath = $MyInvocation.MyCommand.Path
$logFile    = Join-Path $stateDir 'ad02-unattended.log'

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
Start-Transcript -Path $logFile -Append | Out-Null

function Get-Stage {
    if (Test-Path $stateFile) { return [int](Get-Content $stateFile) }
    return 0
}
function Set-Stage([int]$n) { Set-Content -Path $stateFile -Value $n }

function Register-ContinueTask {
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
}

function Unregister-ContinueTask {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Get-DomainCredential {
    # (A) Lab-only plaintext — remove this block and uncomment (B) for anything
    # more sensitive than an isolated lab.
    $securePwd = ConvertTo-SecureString 'Server2012!' -AsPlainText -Force
    return New-Object System.Management.Automation.PSCredential('ADLAB\Administrator', $securePwd)

    # (B) Encrypted-at-rest alternative — run once, interactively, BEFORE
    # kicking off the unattended flow, from the same account/host that will
    # later read it back:
    #   Get-Credential ADLAB\Administrator |
    #     Export-Clixml C:\ProvisionState\ad02-cred.xml
    # Then here:
    #   return Import-Clixml C:\ProvisionState\ad02-cred.xml
}

$stage = Get-Stage
Write-Host "=== ad02 unattended provisioning — resuming at stage $stage ===" -ForegroundColor Cyan

if ($stage -eq 0) {
    # ── Stage 0 — rename, schedule continuation, reboot ────────
    Write-Host "[Stage 0] Renaming computer to AD02..." -ForegroundColor Cyan
    Register-ContinueTask
    if ($env:COMPUTERNAME -ne 'AD02') {
        Rename-Computer -NewName 'AD02' -Force
    }
    Set-Stage 1
    Write-Host "     Rebooting to apply hostname..." -ForegroundColor Yellow
    Stop-Transcript | Out-Null
    Restart-Computer -Force
    exit
}

if ($stage -eq 1) {
    # ── Stage 1 — static IP, connectivity check, promote replica ─
    Write-Host "[Stage 1] Configuring static IP 10.0.7.11/24..." -ForegroundColor Cyan
    $ifIndex = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }).InterfaceIndex
    Remove-NetIPAddress -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress '10.0.7.11' `
        -PrefixLength 24 -DefaultGateway '10.0.7.254'
    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses '10.0.7.10','10.0.7.11'

    Write-Host "[Stage 1] Verifying connectivity to ad01..." -ForegroundColor Cyan
    Start-Sleep -Seconds 10
    $ping = Test-Connection -ComputerName '10.0.7.10' -Count 4 -Quiet -ErrorAction SilentlyContinue
    if (-not $ping) {
        Write-Host "ERROR: Cannot reach ad01 at 10.0.7.10. Will retry on next startup." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    if (-not (Resolve-DnsName 'ad.lab' -Server '10.0.7.10' -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: DNS resolution for ad.lab failed via ad01. Will retry on next startup." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }

    Write-Host "[Stage 1] Installing AD DS feature..." -ForegroundColor Cyan
    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

    Write-Host "[Stage 1] Promoting ad02 as replica DC for ad.lab..." -ForegroundColor Cyan
    $safeModePassword = ConvertTo-SecureString 'Server2012!' -AsPlainText -Force
    $domainCred       = Get-DomainCredential

    Install-ADDSDomainController `
        -DomainName                    'ad.lab' `
        -InstallDns `
        -Credential                    $domainCred `
        -SafeModeAdministratorPassword $safeModePassword `
        -NoRebootOnCompletion:$false `
        -Force `
        -Confirm:$false

    Set-Stage 2
    Stop-Transcript | Out-Null
    exit
}

if ($stage -eq 2) {
    # ── Stage 2 — post-promotion verification, then done ───────
    Write-Host "[Stage 2] Verifying replication..." -ForegroundColor Cyan
    Get-ADDomainController | Select-Object Name, IPv4Address, IsGlobalCatalog | Out-Host
    repadmin /replsummary | Out-Host
    Get-ADDomainController -Filter * | Select-Object Name, IPv4Address, Site | Out-Host
    dcdiag /test:replications /test:services /q | Out-Host

    Set-Stage 3
    Unregister-ContinueTask
    Write-Host "=== ad02 unattended provisioning complete — Phase 3 done ===" -ForegroundColor Green
}

Stop-Transcript | Out-Null
