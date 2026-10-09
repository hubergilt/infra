# phase3-fs01-unattended.ps1
# Launched ONCE by fs01-autounattend.xml's FirstLogonCommands on fs01
# (Windows Server 2025 Core, Data tier). Fully unattended: hostname
# (FS01) and static IP (10.0.6.31/24) are already baked into
# fs01-autounattend.xml, so this script only has to format the data
# disk, join the domain, install the File Server + DFS roles, create
# shares, and publish fs01 as the ACTIVE target in the \\ad.lab\Files
# DFS Namespace (plus start the DFS Replication group with fs02).
#
# HOW IT WORKS
#   A state file (C:\ProvisionState\fs01.stage) tracks progress. A
#   scheduled task re-launches this same script as SYSTEM both at every
#   startup AND on a 2-minute repeating timer, so it keeps retrying
#   entirely on its own across the domain-join reboot — no manual
#   reboot or rerun required. Once verified, the task deletes itself.
#   Same pattern as dcs/phase3-ad02-unattended.ps1.
#
# STAGES
#   0 - Format data disk as D:, join ad.lab, reboot.
#   1 - Install FS-FileServer/DFS-Namespace/DFS-Replication/FSRM,
#       create D:\Shares\{Data,Profiles,Software}, set NTFS/SMB perms.
#   2 - Create \\ad.lab\Files DFS-N root pointed at \\FS01\Data
#       (fs01 is the only/first target here — fs02 adds itself later
#       and this script sets fs01's own target to the higher referral
#       priority so it's preferred, i.e. "active").
#   3 - Verify (share reachable, DFS-N root present) and finish.
#
# CREDENTIAL HANDLING
#   Add-Computer normally blocks on Get-Credential. To stay unattended,
#   Get-DomainCredential below hardcodes the ADLAB\Administrator
#   password — lab-only, matching this repo's existing convention (see
#   dcs/phase3-ad02-unattended.ps1). For anything beyond an isolated
#   lab, swap this for an Import-Clixml credential exported once via
#   Export-Clixml under the same account/host.

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stateDir   = 'C:\ProvisionState'
$stateFile  = Join-Path $stateDir 'fs01.stage'
$taskName   = 'Phase3-FS01-Continue'
$scriptPath = $MyInvocation.MyCommand.Path
$logFile    = Join-Path $stateDir 'fs01-unattended.log'

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
Start-Transcript -Path $logFile -Append | Out-Null

function Get-Stage {
    if (Test-Path $stateFile) { return [int](Get-Content $stateFile) }
    return 0
}
function Set-Stage([int]$n) { Set-Content -Path $stateFile -Value $n }

function Register-ContinueTask {
    # Two triggers: AtStartup (survives the domain-join reboot) AND a
    # 2-minute repeating timer (covers "not ready yet" retries that
    # don't involve a reboot, e.g. waiting on fs01/ad01 reachability).
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
    #     Export-Clixml C:\ProvisionState\fs01-cred.xml
    # Then here:
    #   return Import-Clixml C:\ProvisionState\fs01-cred.xml
}

function Initialize-DataDisk {
    # Second virtio disk attached by create-fs01-vm.sh, left raw by the
    # autounattend.xml (which only touches DiskID 0). Idempotent: skips
    # if D: is already a usable NTFS volume.
    if ((Test-Path 'D:\') -and (Get-Volume -DriveLetter D -ErrorAction SilentlyContinue).FileSystem -eq 'NTFS') {
        Write-Host "     D: already initialized." -ForegroundColor Green
        return
    }
    Write-Host "     Initializing data disk as D:..." -ForegroundColor Cyan
    $rawDisk = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' } | Select-Object -First 1
    if (-not $rawDisk) {
        throw "No RAW data disk found. Check create-fs01-vm.sh attached a second virtio disk."
    }
    Initialize-Disk -Number $rawDisk.Number -PartitionStyle GPT -Confirm:$false
    $partition = New-Partition -DiskNumber $rawDisk.Number -UseMaximumSize -DriveLetter D
    Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel 'FS01-Data' -Confirm:$false | Out-Null
    Write-Host "     D: formatted (NTFS, label FS01-Data)." -ForegroundColor Green
}

$stage = Get-Stage
Write-Host "=== fs01 unattended provisioning — resuming at stage $stage ===" -ForegroundColor Cyan

if ($stage -eq 0) {
    # ── Stage 0 — data disk, connectivity check, domain join ────
    Register-ContinueTask

    Write-Host "[Stage 0] Formatting data disk..." -ForegroundColor Cyan
    Initialize-DataDisk

    Write-Host "[Stage 0] Checking connectivity to ad01 (10.0.7.10)..." -ForegroundColor Cyan
    $ping = Test-Connection -ComputerName '10.0.7.10' -Count 2 -Quiet -ErrorAction SilentlyContinue
    $dns  = Resolve-DnsName 'ad.lab' -Server '10.0.7.10' -ErrorAction SilentlyContinue

    if (-not $ping -or -not $dns) {
        Write-Host "     ad01 not ready yet — will retry automatically in 2 minutes." -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        exit
    }
    Write-Host "     ad01 reachable and DNS working." -ForegroundColor Green

    if ((Get-CimInstance Win32_ComputerSystem).Domain -ne 'ad.lab') {
        Write-Host "[Stage 0] Joining domain ad.lab..." -ForegroundColor Cyan
        $domainCred = Get-DomainCredential
        Add-Computer -DomainName 'ad.lab' -Credential $domainCred -Force
        Set-Stage 0
        Write-Host "     Domain joined. Rebooting to apply..." -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        Restart-Computer -Force
        exit
    }
    Write-Host "     Already domain member." -ForegroundColor Green
    Set-Stage 1
}

if ((Get-Stage) -eq 1) {
    # ── Stage 1 — File Server role + shares ──────────────────────
    Write-Host "[Stage 1] Installing File Server + DFS roles..." -ForegroundColor Cyan
    Install-WindowsFeature -Name `
        FS-FileServer, `
        FS-DFS-Namespace, `
        FS-DFS-Replication, `
        FS-Resource-Manager `
        -IncludeManagementTools
    Write-Host "     Features installed." -ForegroundColor Green

    Write-Host "[Stage 1] Creating SMB shares on D:\Shares..." -ForegroundColor Cyan
    $shares = @(
        @{ Path = 'D:\Shares\Data';     Name = 'Data';     Desc = 'General data share (DFS-R replicated, active/standby with fs02)' },
        @{ Path = 'D:\Shares\Profiles'; Name = 'Profiles'; Desc = 'Roaming profiles' },
        @{ Path = 'D:\Shares\Software'; Name = 'Software'; Desc = 'Software distribution' }
    )
    foreach ($s in $shares) {
        New-Item -ItemType Directory -Path $s.Path -Force | Out-Null

        $acl  = Get-Acl $s.Path
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            'ADLAB\Domain Users', 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.SetAccessRule($rule)
        Set-Acl $s.Path $acl

        New-SmbShare `
            -Name        $s.Name `
            -Path        $s.Path `
            -Description $s.Desc `
            -FullAccess  'ADLAB\Domain Admins' `
            -ChangeAccess 'ADLAB\Domain Users' `
            -FolderEnumerationMode AccessBased `
            -ErrorAction SilentlyContinue
        Write-Host "     Share created: \\FS01\$($s.Name)" -ForegroundColor Green
    }

    Enable-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue
    Set-Stage 2
}

if ((Get-Stage) -eq 2) {
    # ── Stage 2 — DFS Namespace root, fs01 as the ACTIVE target ──
    Write-Host "[Stage 2] Waiting for ADWS/AD readiness before touching DFS-N..." -ForegroundColor Cyan
    $adwsReady = $false
    for ($i = 0; $i -lt 12; $i++) {
        try {
            Get-ADRootDSE -ErrorAction Stop | Out-Null
            $adwsReady = $true
            break
        } catch {
            Write-Host "[Stage 2] ADWS not ready yet, retrying in 5s... ($($i + 1)/12)" -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }
    if (-not $adwsReady) {
        throw "Active Directory Web Services did not become available after 60 seconds."
    }

    Write-Host "[Stage 2] Creating DFS Namespace root \\ad.lab\Files -> \\FS01\Data..." -ForegroundColor Cyan
    if (-not (Get-DfsnRoot -Path '\\ad.lab\Files' -ErrorAction SilentlyContinue)) {
        New-DfsnRoot `
            -Path       '\\ad.lab\Files' `
            -TargetPath '\\FS01\Data' `
            -Type       DomainV2
        Write-Host "     DFS-N root created." -ForegroundColor Green
    } else {
        Write-Host "     DFS-N root already exists." -ForegroundColor Green
        if (-not (Get-DfsnFolderTarget -Path '\\ad.lab\Files' -TargetPath '\\FS01\Data' -ErrorAction SilentlyContinue)) {
            New-DfsnFolderTarget -Path '\\ad.lab\Files' -TargetPath '\\FS01\Data'
        }
    }

    # fs01 = active: lower referral cost = preferred target. fs02
    # (standby) sets its own target to a higher cost when it joins.
    Set-DfsnFolderTarget -Path '\\ad.lab\Files' -TargetPath '\\FS01\Data' `
        -ReferralPriorityClass GlobalHigh -ErrorAction SilentlyContinue

    Write-Host "     fs01 published as the ACTIVE (GlobalHigh priority) DFS-N target." -ForegroundColor Green
    Set-Stage 3
}

if ((Get-Stage) -eq 3) {
    # ── Stage 3 — verify and finish ──────────────────────────────
    Write-Host "[Stage 3] Verifying..." -ForegroundColor Cyan
    Get-SmbShare | Where-Object { $_.Name -notmatch '^\$' } | Select-Object Name, Path, Description | Out-Host
    Get-DfsnRoot -Path '\\ad.lab\Files' | Out-Host
    Get-DfsnRootTarget -Path '\\ad.lab\Files' | Out-Host

    Write-Host ""
    Write-Host "NOTE: DFS Replication group (fs01<->fs02) is created from fs02's" -ForegroundColor Yellow
    Write-Host "  provisioning script once fs02 joins, since New-DfsReplicationGroup" -ForegroundColor Yellow
    Write-Host "  only needs to run once and fs02 knows to wait for fs01 first." -ForegroundColor Yellow

    Unregister-ContinueTask
    Write-Host "=== fs01 unattended provisioning complete — Phase 3 done ===" -ForegroundColor Green
}

Stop-Transcript | Out-Null
