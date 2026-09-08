# phase3-client01-unattended.ps1
# Launched ONCE by client01-autounattend.xml's FirstLogonCommands on
# client01 (Windows 11 Pro). Hostname (CLIENT01) and static IP
# (10.0.4.10/24 on lab-clients) are already baked into
# client01-autounattend.xml, so this script only has to join ad.lab and
# verify it after the reboot that requires.
#
# HOW IT WORKS
#   A state file (C:\ProvisionState\client01.stage) tracks progress. A
#   scheduled task re-launches this same script as SYSTEM both at every
#   startup AND on a 2-minute repeating timer, so it keeps retrying on its
#   own if ad01/ad02 aren't reachable yet — no manual reboot or rerun
#   required. Same pattern as dcs/phase3-ad02-unattended.ps1 and
#   dhcp/phase3-dhcp01-unattended.ps1, minus the parts that don't apply to
#   a plain workstation (no DHCP/DNS role to install, no AD-authorization
#   step — so no CredSSP/double-hop concern here: Add-Computer takes a
#   -Credential parameter natively and authenticates directly, unlike
#   Get/Add-DhcpServerInDC which have no such parameter).
#
#   Stage 0 — wait for ad01, join ad.lab, reboot (domain join requires it)
#   Stage 1 — verify domain membership, done
#
# CREDENTIAL HANDLING
#   Same lab-only convention as the rest of this repo: Get-DomainCredential
#   hardcodes the ADLAB\Administrator password. Swap for the Import-Clixml
#   alternative (commented in the same function) for anything beyond an
#   isolated lab.

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stateDir   = 'C:\ProvisionState'
$stateFile  = Join-Path $stateDir 'client01.stage'
$taskName   = 'Phase3-Client01-Continue'
$scriptPath = $MyInvocation.MyCommand.Path
$logFile    = Join-Path $stateDir 'client01-unattended.log'

# ── Site-specific settings — edit these if your lab differs ────────────
$DomainName   = 'ad.lab'
$DomainNbName = 'ADLAB'
$AdDcIp       = '10.0.7.10'          # ad01 — used for the pre-join reachability probe
# ─────────────────────────────────────────────────────────────────────

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
Start-Transcript -Path $logFile -Append | Out-Null

function Get-Stage {
    if (Test-Path $stateFile) { return [int](Get-Content $stateFile) }
    return 0
}
function Set-Stage([int]$n) { Set-Content -Path $stateFile -Value $n }

function Register-ContinueTask {
    # Two triggers: AtStartup (survives the post-join reboot) AND a
    # 2-minute repeating timer (survives the case where ad01 simply isn't
    # up yet and no reboot is going to happen on its own).
    #
    # NOTE: -RepetitionDuration ([TimeSpan]::MaxValue) serializes to
    # "P99999999DT23H59M59S", which the Task Scheduler XML schema rejects
    # outright with "The task XML contains a value which is incorrectly
    # formatted or out of range" — confirmed the hard way in both
    # dcs/phase3-ad02-unattended.ps1 and dhcp/phase3-dhcp01-unattended.ps1.
    # 9999 days is effectively indefinite for a lab VM and stays inside
    # the valid range — use it from the start here instead of rediscovering
    # the same crash a third time.
    $action         = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    $startupTrigger = New-ScheduledTaskTrigger -AtStartup
    $retryTrigger   = New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 2) `
        -RepetitionDuration (New-TimeSpan -Days 9999)
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
    return New-Object System.Management.Automation.PSCredential("$DomainNbName\Administrator", $securePwd)

    # (B) Encrypted-at-rest alternative — run once, interactively, BEFORE
    # kicking off the unattended flow, from the same account/host that will
    # later read it back:
    #   Get-Credential ADLAB\Administrator |
    #     Export-Clixml C:\ProvisionState\client01-cred.xml
    # Then here:
    #   return Import-Clixml C:\ProvisionState\client01-cred.xml
}

$stage = Get-Stage
Write-Host "=== client01 unattended provisioning — resuming at stage $stage ===" -ForegroundColor Cyan

if ($stage -eq 0) {
    # ── Stage 0 — wait for ad01, join ad.lab, reboot ────────────────────
    Register-ContinueTask

    Write-Host "[Stage 0] Checking connectivity to ad01 ($AdDcIp)..." -ForegroundColor Cyan
    # NOT Test-Connection (ICMP) — confirmed against fw01's OPNsense config
    # that the CLIENTS->IDENTITY firewall rule deliberately permits only
    # the specific ports a domain join needs (DNS 53, Kerberos 88, LDAP
    # 389, SMB 445, LDAPS 636, GC 3268/3269 — the "ADPorts" alias) and
    # nothing else, ICMP included. That's a real, intentional segmentation
    # policy, not a gap to route around — a ping-based gate would loop
    # forever on any host reaching ad01/ad02 across a segment boundary
    # (unlike dhcp01/ad02, which share ad01's own segment and never hit
    # this). Probe LDAP over TCP instead, which the firewall actually
    # allows and which is a more meaningful signal anyway — it directly
    # tests the protocol the join itself depends on.
    $ldapUp = (Test-NetConnection -ComputerName $AdDcIp -Port 389 -InformationLevel Quiet -WarningAction SilentlyContinue)
    $dns    = Resolve-DnsName $DomainName -Server $AdDcIp -ErrorAction SilentlyContinue

    if (-not $ldapUp -or -not $dns) {
        Write-Host "     ad01 not ready yet — will retry automatically in 2 minutes." -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        exit
    }
    Write-Host "     ad01 reachable and DNS working." -ForegroundColor Green

    if ((Get-WmiObject Win32_ComputerSystem).Domain -ne $DomainName) {
        # Belt-and-suspenders: the LDAP probe above tests port reachability
        # only, and Resolve-DnsName -Server bypasses the adapter's own
        # resolver, so neither actually proves the NIC has a DNS server
        # bound. Confirmed necessary the hard way on dhcp01 — if this
        # adapter's own DNS-Client identifier ever drifts out of sync with
        # its TCPIP identifier again, this makes sure DNS is bound
        # correctly regardless before attempting the join.
        $liveIfAlias = (Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).Name
        Set-DnsClientServerAddress -InterfaceAlias $liveIfAlias -ServerAddresses '10.0.7.10', '10.0.7.11'

        Write-Host "[Stage 0] Joining domain $DomainName..." -ForegroundColor Cyan
        $domainCred = Get-DomainCredential
        Add-Computer -DomainName $DomainName -Credential $domainCred -Force

        Set-Stage 1
        Write-Host "     Domain joined. Rebooting..." -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        Restart-Computer -Force
        exit
    }

    Write-Host "     Already a domain member (unexpected at stage 0, continuing)." -ForegroundColor Green
    Set-Stage 1
}

if ($stage -eq 1) {
    # ── Stage 1 — verify domain membership ──────────────────────────────
    Write-Host "[Stage 1] Verifying domain membership..." -ForegroundColor Cyan

    $computerSystem = Get-WmiObject Win32_ComputerSystem
    if ($computerSystem.Domain -ne $DomainName -or -not $computerSystem.PartOfDomain) {
        throw "CLIENT01 is not showing as a member of $DomainName after the join+reboot — check C:\ProvisionState\client01-unattended.log."
    }

    Write-Host "     Confirmed: $($computerSystem.Name) is a member of $($computerSystem.Domain)." -ForegroundColor Green

    # Force onto the domain time hierarchy rather than trust Windows to
    # pick this up on its own. Confirmed the hard way: this VM sat on its
    # local CMOS clock ("not synchronized", Source: Local CMOS Clock)
    # through the entire join + reboot + verification above without that
    # blocking any of it — clock drift doesn't stop the join itself, it
    # silently breaks Kerberos-dependent operations later (in this case,
    # sshd's per-connection logon path reset every single SSH attempt
    # until this was fixed). Requires fw01 to permit NTP (123) from
    # CLIENTS to DomainControllers — see README.md's Prerequisites.
    Write-Host "[Stage 1] Syncing time to domain hierarchy..." -ForegroundColor Cyan
    w32tm /config /syncfromflags:domhier /update | Out-Null
    Restart-Service w32time
    $resync = w32tm /resync /force 2>&1
    Write-Host "     $resync" -ForegroundColor Gray
    Start-Sleep -Seconds 2
    w32tm /query /status | Out-Host

    Set-Stage 2
    Unregister-ContinueTask
    Write-Host "=== client01 unattended provisioning complete ===" -ForegroundColor Green
}

Stop-Transcript | Out-Null
