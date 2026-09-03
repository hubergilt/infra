# phase3-ad01-unattended.ps1
# Run ONCE on ad01 (win19) — Windows Server Core
# Fully unattended version of phase3-ad01.ps1 + phase3-ad01-verify.ps1
# Survives both reboots (rename, promotion) with no console interaction.
# IP: 10.0.7.10/24  GW: 10.0.7.254  DNS: 127.0.0.1
#
# HOW IT WORKS
#   A state file (C:\ProvisionState\ad01.stage) tracks progress across
#   reboots. A scheduled task re-launches this same script as SYSTEM at
#   every startup until stage 3 (verified) is reached, then the task
#   deletes itself. Nothing here waits on a human.

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stateDir   = 'C:\ProvisionState'
$stateFile  = Join-Path $stateDir 'ad01.stage'
$taskName   = 'Phase3-AD01-Continue'
$scriptPath = $MyInvocation.MyCommand.Path
$logFile    = Join-Path $stateDir 'ad01-unattended.log'

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
Start-Transcript -Path $logFile -Append | Out-Null

function Get-Stage {
    if (Test-Path $stateFile) { return [int](Get-Content $stateFile) }
    return 0
}
function Set-Stage([int]$n) { Set-Content -Path $stateFile -Value $n }

function Register-ContinueTask {
    # Runs at every startup as SYSTEM, no logon required, no user prompt.
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

$stage = Get-Stage
Write-Host "=== ad01 unattended provisioning — resuming at stage $stage ===" -ForegroundColor Cyan

if ($stage -eq 0) {
    # ── Stage 0 — rename, schedule continuation, reboot ────────
    Write-Host "[Stage 0] Renaming computer to AD01..." -ForegroundColor Cyan
    Register-ContinueTask
    if ($env:COMPUTERNAME -ne 'AD01') {
        Rename-Computer -NewName 'AD01' -Force
    }
    Set-Stage 1
    Write-Host "     Rebooting to apply hostname..." -ForegroundColor Yellow
    Stop-Transcript | Out-Null
    Restart-Computer -Force
    exit
}

if ($stage -eq 1) {
    # ── Stage 1 — static IP, features, promote forest root ─────
    Write-Host "[Stage 1] Configuring static IP 10.0.7.10/24..." -ForegroundColor Cyan
    $ifIndex = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }).InterfaceIndex
    Remove-NetIPAddress -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress '10.0.7.10' `
        -PrefixLength 24 -DefaultGateway '10.0.7.254'
    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses '127.0.0.1','10.0.7.10'

    Write-Host "[Stage 1] Installing AD DS and DNS features..." -ForegroundColor Cyan
    Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools

    Write-Host "[Stage 1] Promoting ad01 as forest root for ad.lab..." -ForegroundColor Cyan
    # Lab-only: plaintext DSRM password, same convention as the rest of this repo.
    # For anything beyond an isolated lab, pull this from a vault instead.
    $safeModePassword = ConvertTo-SecureString 'Server2012!' -AsPlainText -Force

    Install-ADDSForest `
        -DomainName                    'ad.lab' `
        -DomainNetbiosName             'ADLAB' `
        -ForestMode                    'WinThreshold' `
        -DomainMode                    'WinThreshold' `
        -InstallDns `
        -SafeModeAdministratorPassword $safeModePassword `
        -NoRebootOnCompletion:$false `
        -Force `
        -Confirm:$false

    Set-Stage 2
    # Install-ADDSForest reboots on its own; the scheduled task picks the
    # script back up automatically at next startup — nothing to do here.
    Stop-Transcript | Out-Null
    exit
}

if ($stage -eq 2) {
    # ── Stage 2 — post-promotion verification, then done ───────
    Write-Host "[Stage 2] Verifying AD DS and DNS..." -ForegroundColor Cyan
    Get-ADDomain | Select-Object DNSRoot, NetBIOSName, DomainMode, Forest | Out-Host
    Get-ADForest | Select-Object Name, ForestMode, SchemaMaster | Out-Host
    Get-ADDomainController | Select-Object Name, IPv4Address, IsGlobalCatalog | Out-Host
    dcdiag /test:dns /test:replications /test:services /q | Out-Host

    Set-Stage 3
    Unregister-ContinueTask
    Write-Host "=== ad01 unattended provisioning complete ===" -ForegroundColor Green
    Write-Host "Proceed to ad02: phase3-ad02-unattended.ps1" -ForegroundColor Green
}

Stop-Transcript | Out-Null
