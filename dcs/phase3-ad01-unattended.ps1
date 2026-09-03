# phase3-ad01-unattended.ps1
# Launched ONCE by ad01-autounattend.xml's FirstLogonCommands on ad01 (win19)
# — Windows Server Core. Fully unattended: hostname (AD01) and static IP
# (10.0.7.10/24) are already baked into ad01-autounattend.xml, so this script
# only has to install AD DS + DNS and promote the forest. It survives the
# reboot Install-ADDSForest triggers with no console interaction.
#
# HOW IT WORKS
#   A state file (C:\ProvisionState\ad01.stage) tracks progress across
#   reboots. A scheduled task re-launches this same script as SYSTEM at
#   every startup until stage 2 (verified) is reached, then the task
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
    # ── Stage 0 — install AD DS + DNS, promote forest root ──────
    # Re-arm the continuation task BEFORE promoting, since
    # Install-ADDSForest reboots the machine on its own.
    Register-ContinueTask

    Write-Host "[Stage 0] Installing AD DS and DNS features..." -ForegroundColor Cyan
    Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools

    Write-Host "[Stage 0] Promoting ad01 as forest root for ad.lab..." -ForegroundColor Cyan
    Write-Host "          This will reboot automatically when complete." -ForegroundColor Yellow

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

    Set-Stage 1
    # Install-ADDSForest reboots on its own; the scheduled task picks the
    # script back up automatically at next startup — nothing to do here.
    Stop-Transcript | Out-Null
    exit
}

if ($stage -eq 1) {
    # ── Stage 1 — point DNS at the now-local DNS role, verify, done ─
    Write-Host "[Stage 1] Repointing DNS client to the local DNS role..." -ForegroundColor Cyan
    $ifIndex = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }).InterfaceIndex
    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses '127.0.0.1', '10.0.7.10'

    Write-Host "[Stage 1] Pinning DNS Server forwarders to Cloudflare (1.1.1.1, 1.0.0.1)..." -ForegroundColor Cyan
    # Explicit rather than relying on whatever the pre-promotion NIC resolver
    # happened to be — makes the upstream DNS a deliberate, auditable setting
    # instead of an implicit side effect of Install-ADDSForest -InstallDns.

    # The DNS Server role's WMI/CIM provider can lag a few seconds behind
    # the service reporting "Running" right after a post-promotion reboot,
    # so Set-DnsServerForwarder can hit a transient WIN32 1722 (RPC server
    # unavailable). Poll until it actually answers before configuring it.
    $dnsReady = $false
    for ($i = 0; $i -lt 12; $i++) {
        try {
            Get-DnsServerForwarder -ErrorAction Stop | Out-Null
            $dnsReady = $true
            break
        } catch {
            Write-Host "[Stage 1] DNS Server role not ready yet, retrying in 5s... ($($i + 1)/12)" -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }
    if (-not $dnsReady) {
        throw "DNS Server role did not become queryable after 60 seconds."
    }

    Set-DnsServerForwarder -IPAddress '1.1.1.1', '1.0.0.1' -UseRootHint $false

    Write-Host "[Stage 1] Verifying AD DS and DNS..." -ForegroundColor Cyan

    # Get-AD* cmdlets depend on Active Directory Web Services (ADWS), which
    # routinely takes longer to come up than the DNS role after a promotion
    # reboot — hence "Unable to find a default server with Active Directory
    # Web Services running" even when DNS is already responding. Poll a
    # lightweight ADWS probe before trusting any Get-AD* call below.
    $adwsReady = $false
    for ($i = 0; $i -lt 12; $i++) {
        try {
            Get-ADRootDSE -ErrorAction Stop | Out-Null
            $adwsReady = $true
            break
        } catch {
            Write-Host "[Stage 1] ADWS not ready yet, retrying in 5s... ($($i + 1)/12)" -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }
    if (-not $adwsReady) {
        throw "Active Directory Web Services did not become available after 60 seconds."
    }

    Get-ADDomain | Select-Object DNSRoot, NetBIOSName, DomainMode, Forest | Out-Host
    Get-ADForest | Select-Object Name, ForestMode, SchemaMaster | Out-Host
    Get-ADDomainController | Select-Object Name, IPv4Address, IsGlobalCatalog | Out-Host
    Get-DnsServerForwarder | Out-Host
    dcdiag /test:dns /test:replications /test:services /q | Out-Host

    Set-Stage 2
    Unregister-ContinueTask
    Write-Host "=== ad01 unattended provisioning complete ===" -ForegroundColor Green
    Write-Host "ad02 can now be created (create-ad02-vm.sh) and will promote itself" -ForegroundColor Green
    Write-Host "automatically once it can reach ad01." -ForegroundColor Green
}

Stop-Transcript | Out-Null
