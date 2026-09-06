# phase3-dhcp01-unattended.ps1
# Launched ONCE by dhcp01-autounattend.xml's FirstLogonCommands on dhcp01
# (Windows Server 2025 Core). Fully unattended: hostname (DHCP01) and
# static IP (10.0.7.30/24 on lab-identity) are already baked into
# dhcp01-autounattend.xml, so this script only has to join ad.lab, install
# the DHCP Server role, and configure the lab-clients scope.
#
# TOPOLOGY (per general-nw.puml — Identity/PKI tier)
#   dhcp01 lives on lab-identity (10.0.7.0/24) alongside ad01/ad02, NOT on
#   the segment it serves. It hands out leases for the lab-clients segment
#   (10.0.4.0/24) via fw01's DHCP relay (ip helper) — client01 and other
#   workstations never talk to dhcp01 directly.
#
# HOW IT WORKS
#   A state file (C:\ProvisionState\dhcp01.stage) tracks progress. A
#   scheduled task re-launches this same script as SYSTEM both at every
#   startup AND on a 2-minute repeating timer, so it keeps retrying on its
#   own if ad01/ad02 aren't reachable yet — no manual reboot or rerun
#   required. Same pattern as dcs/phase3-ad02-unattended.ps1. Once
#   authorized and verified, the task deletes itself.
#
#   Stage 0 — wait for ad01, join ad.lab, reboot (domain join requires it)
#   Stage 1 — install DHCP Server feature, configure scope, authorize, verify
#
# CREDENTIAL HANDLING
#   Add-Computer normally blocks on Get-Credential. To stay unattended,
#   Get-DomainCredential below hardcodes the ADLAB\Administrator password —
#   lab-only, matching this repo's existing convention (see
#   dcs/phase3-ad02-unattended.ps1). For anything beyond an isolated lab,
#   swap this for an Import-Clixml credential exported once via
#   Export-Clixml under the same account/host (see dcs/README.md section 7.3).

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stateDir   = 'C:\ProvisionState'
$stateFile  = Join-Path $stateDir 'dhcp01.stage'
$taskName   = 'Phase3-DHCP01-Continue'
$scriptPath = $MyInvocation.MyCommand.Path
$logFile    = Join-Path $stateDir 'dhcp01-unattended.log'

# ── Site-specific settings — edit these if your lab differs ────────────
$DomainName   = 'ad.lab'
$DomainNbName = 'ADLAB'
$AdDcIp       = '10.0.7.10'          # ad01 — used for the pre-join reachability probe
$DhcpHostIp   = '10.0.7.30'          # dhcp01 itself, on lab-identity
$DhcpNicAlias = 'Ethernet'           # matches the TCPIP <Identifier> in dhcp01-autounattend.xml
$DnsServers   = '10.0.7.10', '10.0.7.11'

$ScopeId      = '10.0.4.0'           # lab-clients segment served via fw01 relay
$ScopeMask    = '255.255.255.0'
$ScopeRouter  = '10.0.4.1'           # fw01's lab-clients gateway leg
# The scope itself spans the whole usable subnet; exclusions carve out the
# static-reserved bands at each end so the actual leasable pool ends up as
# 10.0.4.50-10.0.4.200. (An exclusion range must be a SUBSET of the
# scope's own Start/End range — a scope of just .50-.200 plus a .1-.49
# "exclusion" is invalid and Add-DhcpServerv4ExclusionRange rejects it
# with DHCP error 20023, confirmed in practice.)
$ScopeStart   = '10.0.4.1'
$ScopeEnd     = '10.0.4.254'
$LowExclStart = '10.0.4.1'           # reserved for statics/infrastructure
$LowExclEnd   = '10.0.4.49'
$HighExclStart = '10.0.4.201'        # reserved / headroom above the lease pool
$HighExclEnd   = '10.0.4.254'
$LeaseTime    = New-TimeSpan -Hours 8
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
    $action         = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    $startupTrigger = New-ScheduledTaskTrigger -AtStartup
    # NOTE: [TimeSpan]::MaxValue serializes to "P99999999DT23H59M59S", which
    # the Task Scheduler XML schema rejects with "The task XML contains a
    # value which is incorrectly formatted or out of range." 9999 days is
    # effectively indefinite for a lab VM and stays inside the valid range.
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
    #     Export-Clixml C:\ProvisionState\dhcp01-cred.xml
    # Then here:
    #   return Import-Clixml C:\ProvisionState\dhcp01-cred.xml
}

$stage = Get-Stage
Write-Host "=== dhcp01 unattended provisioning — resuming at stage $stage ===" -ForegroundColor Cyan

if ($stage -eq 0) {
    # ── Stage 0 — wait for ad01, join ad.lab, reboot ────────────────────
    Register-ContinueTask

    Write-Host "[Stage 0] Checking connectivity to ad01 ($AdDcIp)..." -ForegroundColor Cyan
    $ping = Test-Connection -ComputerName $AdDcIp -Count 2 -Quiet -ErrorAction SilentlyContinue
    $dns  = Resolve-DnsName $DomainName -Server $AdDcIp -ErrorAction SilentlyContinue

    if (-not $ping -or -not $dns) {
        Write-Host "     ad01 not ready yet — will retry automatically in 2 minutes." -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        exit
    }
    Write-Host "     ad01 reachable and DNS working." -ForegroundColor Green

    if ((Get-WmiObject Win32_ComputerSystem).Domain -ne $DomainName) {
        # Belt-and-suspenders: Test-Connection is pure ICMP and
        # Resolve-DnsName -Server above bypasses the adapter's own
        # resolver, so neither actually proves the NIC has a DNS server
        # bound. Add-Computer's domain-locator SRV lookup relies on the
        # adapter's configured resolver, not an explicit -Server override
        # — if dhcp01-autounattend.xml's DNS-Client <Identifier> ever
        # drifts out of sync with the TCPIP component's again (confirmed
        # to happen in practice — silently leaves the adapter with no DNS
        # server at all), this makes sure it's bound correctly regardless.
        $liveIfAlias = (Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).Name
        Set-DnsClientServerAddress -InterfaceAlias $liveIfAlias -ServerAddresses $DnsServers

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
    # ── Stage 1 — install DHCP, configure scope, authorize, verify ──────
    Write-Host "[Stage 1] Installing DHCP Server feature..." -ForegroundColor Cyan
    Install-WindowsFeature -Name DHCP -IncludeManagementTools
    Write-Host "     Feature installed." -ForegroundColor Green

    # The DHCP Server service's CIM/WMI provider can lag a few seconds
    # behind the service reporting "Running" right after install — same
    # class of race condition as the DNS role in dcs/phase3-ad0X-unattended.ps1.
    # Poll until it actually answers before configuring it.
    Write-Host "[Stage 1] Waiting for DHCP Server service to become queryable..." -ForegroundColor Cyan
    $dhcpReady = $false
    for ($i = 0; $i -lt 12; $i++) {
        try {
            Get-DhcpServerv4Scope -ErrorAction Stop | Out-Null
            $dhcpReady = $true
            break
        } catch {
            Write-Host "     DHCP Server not ready yet, retrying in 5s... ($($i + 1)/12)" -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }
    if (-not $dhcpReady) {
        throw "DHCP Server service did not become queryable after 60 seconds."
    }

    Write-Host "[Stage 1] Configuring scope for lab-clients ($ScopeId/24)..." -ForegroundColor Cyan

    $existingScope = Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction SilentlyContinue
    if (-not $existingScope) {
        Add-DhcpServerv4Scope `
            -Name        'ad.lab Clients' `
            -StartRange  $ScopeStart `
            -EndRange    $ScopeEnd `
            -SubnetMask  $ScopeMask `
            -Description 'lab-clients (10.0.4.0/24) — relayed via fw01 ip-helper' `
            -State       Active
    } elseif ($existingScope.StartRange.ToString() -ne $ScopeStart -or $existingScope.EndRange.ToString() -ne $ScopeEnd) {
        # Rerun-safety: a prior attempt may have created the scope with a
        # different (e.g. narrower, since-corrected) range. Reconcile it
        # rather than silently leaving stale values that break the
        # exclusion-range step below (confirmed in practice — rerunning
        # against a stale .50-.200 scope reproduces the exact same "not
        # within range" error even after fixing the exclusion logic here).
        Write-Host "     Existing scope range ($($existingScope.StartRange)-$($existingScope.EndRange)) doesn't match expected ($ScopeStart-$ScopeEnd) — correcting." -ForegroundColor Yellow
        Set-DhcpServerv4Scope -ScopeId $ScopeId -StartRange $ScopeStart -EndRange $ScopeEnd
    }

    # -Force skips this cmdlet's built-in live validation of each DNS
    # server (it actively queries each one with a short timeout before
    # accepting it). That validation can fail transiently even when the
    # server is genuinely up and reachable — confirmed in practice: ad02
    # answered ICMP fine, but the option-value validation query still
    # rejected it as "not a valid DNS server" (likely a brief AD
    # replication/DNS-settling window right after dhcp01 itself joined).
    Set-DhcpServerv4OptionValue `
        -ScopeId    $ScopeId `
        -Router     $ScopeRouter `
        -DnsServer  $DnsServers `
        -DnsDomain  $DomainName `
        -Force

    Set-DhcpServerv4Scope -ScopeId $ScopeId -LeaseDuration $LeaseTime

    # Idempotent: skip an exclusion that's already present rather than
    # re-adding it. Confirmed in practice this matters even on a single
    # "fresh" run — the Stage 0 retry task keeps re-firing this script in
    # the background every 2 minutes until stage 2 is reached, so a
    # foreground rerun can easily race a background run that already
    # succeeded, hitting ERROR_DHCP_INVALID_RANGE (20023, "overlaps with
    # an existing range") for a range that's already correctly there.
    $existingExclusions = Get-DhcpServerv4ExclusionRange -ScopeId $ScopeId -ErrorAction SilentlyContinue
    function Test-ExclusionExists([string]$start, [string]$end) {
        return [bool]($existingExclusions | Where-Object {
            $_.StartRange.ToString() -eq $start -and $_.EndRange.ToString() -eq $end
        })
    }

    if (-not (Test-ExclusionExists $LowExclStart $LowExclEnd)) {
        try {
            Add-DhcpServerv4ExclusionRange -ScopeId $ScopeId -StartRange $LowExclStart -EndRange $LowExclEnd
        } catch {
            Write-Host "     WARNING: could not add low exclusion range ($LowExclStart-$LowExclEnd): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if (-not (Test-ExclusionExists $HighExclStart $HighExclEnd)) {
        try {
            Add-DhcpServerv4ExclusionRange -ScopeId $ScopeId -StartRange $HighExclStart -EndRange $HighExclEnd
        } catch {
            Write-Host "     WARNING: could not add high exclusion range ($HighExclStart-$HighExclEnd): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    Set-DhcpServerv4DnsSetting `
        -ScopeId                    $ScopeId `
        -DynamicUpdates             Always `
        -DeleteDnsRRonLeaseExpiry   $true `
        -UpdateDnsRRForOlderClients $true

    Write-Host "     Scope configured: 10.0.4.1-254, leasable pool 10.0.4.50-10.0.4.200" -ForegroundColor Green

    Write-Host "[Stage 1] Authorizing DHCP01 in Active Directory..." -ForegroundColor Cyan

    # Get/Add-DhcpServerInDC have NO -Credential parameter — they always run
    # under whatever token launched the script. When Stage 1 is resumed by
    # the Stage-0-registered scheduled task, that token is LOCAL SYSTEM,
    # which authenticates to AD as the computer account (DHCP01$) — a plain
    # domain member with no rights to write CN=NetServices,CN=Services,
    # CN=Configuration. DHCP authorization specifically requires Enterprise
    # Admin rights (confirmed against Microsoft's own DHCP-authorization
    # troubleshooting guide's "Permission issues" cause) — this call cannot
    # succeed as SYSTEM regardless of DNS/LDAP connectivity, which is why
    # pointing DNS at ad01 alone made no difference. Route it through a
    # local WinRM hop under the same domain credential used for the join.
    #
    # Plain Negotiate/Kerberos WinRM auth issues a non-delegable token for
    # the remote session: it authenticates THAT hop fine, but the DHCP
    # cmdlets inside it then make a SECOND, separate outbound hop (LDAP to
    # the DC) which needs the credential forwarded again — the classic
    # "double hop" problem. This is inherent to Invoke-Command -Credential
    # itself, regardless of what launched the outer script (SSH, RDP,
    # console, or the Stage-0 scheduled task as SYSTEM) — confirmed in
    # practice: supplying -Credential explicitly hit the identical DHCP
    # 20070 error. CredSSP forwards the actual credential rather than a
    # restricted ticket, which survives the extra hop — but
    # Enable-WSManCredSSP alone only configures the WinRM/CredSSP
    # *provider*; it does NOT grant the "Allow Delegating Fresh
    # Credentials" policy that governs which target SPNs a credential may
    # delegate to (normally set via gpedit.msc — the registry keys below
    # are the direct, unattended equivalent). Without it, Invoke-Command
    # fails immediately with "A computer policy does not allow the
    # delegation of the user credentials..." before ever reaching the DHCP
    # cmdlets — confirmed in practice. Lab-only tradeoff, consistent with
    # this repo's existing hardcoded-credential posture — CredSSP and this
    # policy should only ever target trusted, isolated hosts like this one
    # on lab-identity, never anything internet-facing.
    $domainCred = Get-DomainCredential
    $localFqdn  = "$env:COMPUTERNAME.$DomainName"

    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    Enable-WSManCredSSP -Role Server -Force | Out-Null
    Enable-WSManCredSSP -Role Client -DelegateComputer $localFqdn -Force | Out-Null

    $credDelegationKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation'
    $freshCredsKey     = Join-Path $credDelegationKey 'AllowFreshCredentials'
    New-Item -Path $freshCredsKey -Force | Out-Null
    New-ItemProperty -Path $credDelegationKey -Name 'AllowFreshCredentials' -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $credDelegationKey -Name 'ConcatenateDefaults_AllowFresh' -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $freshCredsKey -Name '1' -PropertyType String -Value "WSMAN/$localFqdn" -Force | Out-Null
    Restart-Service WinRM -Force

    $authResult = Invoke-Command -ComputerName $localFqdn -Credential $domainCred -Authentication Credssp -ScriptBlock {
        param($DnsHostName, $HostIp, $NicAlias)
        if (-not (Get-DhcpServerInDC | Where-Object { $_.IPAddress -eq $HostIp })) {
            Add-DhcpServerInDC -DnsName $DnsHostName -IPAddress $HostIp
        }
        Set-DhcpServerv4Binding -InterfaceAlias $NicAlias -BindingState $true
        Get-DhcpServerInDC
    } -ArgumentList "DHCP01.$DomainName", $DhcpHostIp, $DhcpNicAlias

    # Verify
    Write-Host ""
    Write-Host "DHCP Server status:" -ForegroundColor Yellow
    Get-DhcpServerv4Scope | Select-Object ScopeId, Name, State, StartRange, EndRange, LeaseDuration | Out-Host
    Write-Host ""
    Write-Host "DHCP authorized in AD:" -ForegroundColor Yellow
    $authResult | Out-Host

    Set-Stage 2
    Unregister-ContinueTask
    Write-Host "=== dhcp01 unattended provisioning complete — Phase 5 (dhcp01) done ===" -ForegroundColor Green
}

Stop-Transcript | Out-Null
