# phase3-rodc01-unattended.ps1
# Launched ONCE by rodc01-autounattend.xml's FirstLogonCommands on rodc01
# (win25) — Windows Server Core. Fully unattended: hostname (RODC01) and
# all three static IPs (DMZ-Web 10.0.2.15/24, DMZ-VPN 10.0.5.15/24, MGMT
# 10.0.3.14/24) are already baked into rodc01-autounattend.xml via
# MAC-matched interfaces, so this script only has to wait for ad01/ad02,
# install AD DS, and promote itself as a read-only replica.
#
# HOW IT WORKS
#   Same reboot-persistence pattern as phase3-ad02-unattended.ps1: a state
#   file (C:\ProvisionState\rodc01.stage) tracks progress, and a scheduled
#   task re-launches this same script as SYSTEM both at every startup AND
#   on a 2-minute repeating timer, so it keeps retrying entirely on its own
#   if ad01/ad02 aren't reachable yet. Once verified, the task deletes
#   itself. See dcs/README.md section 7.
#
# PREREQUISITE
#   fw01 needs an outbound allow rule from lab-dmz-web AND lab-dmz-vpn to
#   ad01/ad02 (10.0.7.10, 10.0.7.11) on 53/88/389/445/636/3268/3269 (the
#   same ADPorts alias opnsense26 already uses for the inbound
#   DMZ-Web->RODC rule). This is a documented gap (dcs/README.md section 3)
#   — without it, Stage 0 below just retries forever.
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
$stateFile  = Join-Path $stateDir 'rodc01.stage'
$taskName   = 'Phase3-RODC01-Continue'
$scriptPath = $MyInvocation.MyCommand.Path
$logFile    = Join-Path $stateDir 'rodc01-unattended.log'

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
Start-Transcript -Path $logFile -Append | Out-Null

function Get-Stage {
    if (Test-Path $stateFile) { return [int](Get-Content $stateFile) }
    return 0
}
function Set-Stage([int]$n) { Set-Content -Path $stateFile -Value $n }

function Register-ContinueTask {
    # Two triggers: AtStartup (survives reboots) AND a 2-minute repeating
    # timer (survives the case where ad01/ad02 simply aren't up yet, or the
    # DMZ->Identity firewall rule from the prerequisite above isn't in
    # place yet, and no reboot is going to happen on its own) — this is
    # what makes rodc01 wait without any human re-running anything.
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
    # anything more sensitive than an isolated lab. Needs Domain/Enterprise
    # Admin rights: Install-ADDSDomainController -ReadOnlyReplica both
    # pre-creates the RODC computer account AND promotes it in one step
    # when no account has been pre-staged from a writable DC.
    $securePwd = ConvertTo-SecureString 'Server2012!' -AsPlainText -Force
    return New-Object System.Management.Automation.PSCredential('ADLAB\Administrator', $securePwd)

    # (B) Encrypted-at-rest alternative — run once, interactively, BEFORE
    # kicking off the unattended flow, from the same account/host that will
    # later read it back:
    #   Get-Credential ADLAB\Administrator |
    #     Export-Clixml C:\ProvisionState\rodc01-cred.xml
    # Then here:
    #   return Import-Clixml C:\ProvisionState\rodc01-cred.xml
}

$stage = Get-Stage
Write-Host "=== rodc01 unattended provisioning - resuming at stage $stage ===" -ForegroundColor Cyan

if ($stage -eq 0) {
    # -- Stage 0 -- wait for a writable DC, install AD DS, promote RODC --
    Register-ContinueTask

    Write-Host "[Stage 0] Checking connectivity to ad01 (10.0.7.10) / ad02 (10.0.7.11)..." -ForegroundColor Cyan
    $pingAd01 = Test-Connection -ComputerName '10.0.7.10' -Count 2 -Quiet -ErrorAction SilentlyContinue
    $pingAd02 = Test-Connection -ComputerName '10.0.7.11' -Count 2 -Quiet -ErrorAction SilentlyContinue
    $dns      = Resolve-DnsName 'ad.lab' -Server '10.0.7.10' -ErrorAction SilentlyContinue

    if ((-not $pingAd01 -and -not $pingAd02) -or -not $dns) {
        Write-Host "     Neither ad01 nor ad02 reachable/resolving yet - will retry automatically in 2 minutes." -ForegroundColor Yellow
        Write-Host "     If this keeps happening, check the fw01 DMZ-Web/DMZ-VPN -> Identity ACL prerequisite (see header of this script)." -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        exit
    }
    Write-Host "     A writable DC is reachable and DNS is working." -ForegroundColor Green

    Write-Host "[Stage 0] Installing AD DS feature..." -ForegroundColor Cyan
    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

    Write-Host "[Stage 0] Promoting rodc01 as a read-only replica DC for ad.lab..." -ForegroundColor Cyan
    $safeModePassword = ConvertTo-SecureString 'Server2012!' -AsPlainText -Force
    $domainCred       = Get-DomainCredential

    # -ReadOnlyReplica: promotes rodc01 as an RODC instead of a writable DC
    #   — it will only ever pull replication inbound from ad01/ad02, never
    #   push writes back, matching this tier's "DMZ identity broker, no
    #   writable DC in the DMZ" design goal.
    # -InstallDns: rodc01 hosts a read-only copy of the ad.lab DNS zone
    #   locally, so DMZ-Web/DMZ-VPN clients can resolve _ldap._tcp SRV
    #   records without ever crossing into the Identity network themselves.
    # -DelegatedAdministratorAccountName is intentionally omitted here —
    #   by default only Domain/Enterprise Admins can administer rodc01.
    #   Pass e.g. 'ADLAB\dmz-admins' if you want a non-DA group to be able
    #   to manage this RODC locally without full domain rights.
    Install-ADDSDomainController `
        -DomainName                    'ad.lab' `
        -InstallDns `
        -ReadOnlyReplica `
        -SiteName                      'Default-First-Site-Name' `
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
    # -- Stage 1 -- forwarders, verify replication + read-only state -----
    Write-Host "[Stage 1] Pinning DNS Server forwarders to Cloudflare (1.1.1.1, 1.0.0.1)..." -ForegroundColor Cyan
    # Same rationale as ad01/ad02: rodc01's pre-promotion resolver list is
    # 10.0.7.10/10.0.7.11 (internal DCs), so there's nothing external for
    # -InstallDns to have inherited here either.

    # Same DNS-role / ADWS readiness race as ad01/ad02 — poll before
    # trusting either. See dcs/README.md section 7.6.
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

    Write-Host "[Stage 1] Verifying replication and read-only status..." -ForegroundColor Cyan

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

    $self = Get-ADDomainController -Identity 'RODC01'
    if (-not $self.IsReadOnly) {
        throw "RODC01 promoted but IsReadOnly is False — promotion did not come up as read-only. Check the Install-ADDSDomainController transcript above."
    }

    Get-ADDomainController -Filter * | Select-Object Name, IPv4Address, Site, IsReadOnly | Out-Host
    Get-DnsServerForwarder | Out-Host
    repadmin /replsummary | Out-Host
    dcdiag /test:replications /test:services /q | Out-Host

    Write-Host "[Stage 1] NOTE: Password Replication Policy is a manual follow-up." -ForegroundColor Yellow
    Write-Host "     By default an RODC caches no user passwords. To let it authenticate DMZ/VPN" -ForegroundColor Yellow
    Write-Host "     clients locally instead of always round-tripping to ad01/ad02, add the relevant" -ForegroundColor Yellow
    Write-Host "     accounts/groups to 'Allowed RODC Password Replication Group' from ad01, e.g.:" -ForegroundColor Yellow
    Write-Host "       Add-ADGroupMember 'Allowed RODC Password Replication Group' -Members '<group>'" -ForegroundColor Yellow

    Set-Stage 2
    Unregister-ContinueTask
    Write-Host "=== rodc01 unattended provisioning complete - Phase 3 done ===" -ForegroundColor Green
}

Stop-Transcript | Out-Null
