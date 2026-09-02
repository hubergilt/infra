# phase3-ad02-unattended.ps1
# Launched ONCE by ad02-autounattend.xml's FirstLogonCommands on ad02 (win22)
# — Windows Server Core. Fully unattended: hostname (AD02) and static IP
# (10.0.7.11/24) are already baked into ad02-autounattend.xml, so this script
# only has to wait for ad01, install AD DS, and promote as a replica.
#
# HOW IT WORKS
#   A state file (C:\ProvisionState\ad02.stage) tracks progress. A scheduled
#   task re-launches this same script as SYSTEM both at every startup AND on
#   a 2-minute repeating timer, so it keeps retrying entirely on its own if
#   ad01 isn't reachable yet — no manual reboot or rerun required, and no
#   ordering dependency to babysit between create-ad01-vm.sh and
#   create-ad02-vm.sh. Once promoted, the task deletes itself.
#
# CREDENTIAL HANDLING
#   Install-ADDSDomainController normally blocks on Get-Credential. To stay
#   unattended, Get-DomainCredential below hardcodes the ADLAB\Administrator
#   password — lab-only, matching this repo's existing convention of a
#   plaintext DSRM password. For anything beyond an isolated lab, swap this
#   for an Import-Clixml credential exported once via Export-Clixml under
#   the same account/host (see dcs/README.md section 7.3).

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
    # Two triggers: AtStartup (survives reboots) AND a 2-minute repeating
    # timer (survives the case where ad01 simply isn't up yet and no reboot
    # is going to happen on its own) — this is what makes ad02 wait for ad01
    # without any human re-running anything.
    $action        = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    $startupTrigger = New-ScheduledTaskTrigger -AtStartup
    $retryTrigger   = New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 2) `
        -RepetitionDuration ([TimeSpan]::MaxValue)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($startupTrigger, $retryTrigger) `
        -Principal $principal -Settings $settings -Force | Out-Null
}

function Unregister-ContinueTask {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Get-DomainCredential {
    # (A) Lab-only plaintext — remove this block and use (B) below for
    # anything more sensitive than an isolated lab.
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
    # ── Stage 0 — wait for ad01, install AD DS, promote replica ─
    Register-ContinueTask

    Write-Host "[Stage 0] Checking connectivity to ad01 (10.0.7.10)..." -ForegroundColor Cyan
    $ping = Test-Connection -ComputerName '10.0.7.10' -Count 2 -Quiet -ErrorAction SilentlyContinue
    $dns  = Resolve-DnsName 'ad.lab' -Server '10.0.7.10' -ErrorAction SilentlyContinue

    if (-not $ping -or -not $dns) {
        Write-Host "     ad01 not ready yet — will retry automatically in 2 minutes." -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        exit
    }
    Write-Host "     ad01 reachable and DNS working." -ForegroundColor Green

    Write-Host "[Stage 0] Installing AD DS feature..." -ForegroundColor Cyan
    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

    Write-Host "[Stage 0] Promoting ad02 as replica DC for ad.lab..." -ForegroundColor Cyan
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

    Set-Stage 1
    Stop-Transcript | Out-Null
    exit
}

if ($stage -eq 1) {
    # ── Stage 1 — verify replication, then done ─────────────────
    Write-Host "[Stage 1] Verifying replication..." -ForegroundColor Cyan
    Get-ADDomainController | Select-Object Name, IPv4Address, IsGlobalCatalog | Out-Host
    repadmin /replsummary | Out-Host
    Get-ADDomainController -Filter * | Select-Object Name, IPv4Address, Site | Out-Host
    dcdiag /test:replications /test:services /q | Out-Host

    Set-Stage 2
    Unregister-ContinueTask
    Write-Host "=== ad02 unattended provisioning complete — Phase 3 done ===" -ForegroundColor Green
}

Stop-Transcript | Out-Null
