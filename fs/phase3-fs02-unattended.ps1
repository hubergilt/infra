# phase3-fs02-unattended.ps1
# Launched ONCE by fs02-autounattend.xml's FirstLogonCommands on fs02
# (Windows Server 2025 Core, Data tier). Fully unattended: hostname
# (FS02) and static IP (10.0.6.32/24) are already baked into
# fs02-autounattend.xml. This script formats the data disk, joins the
# domain, installs the File Server + DFS roles, creates shares, then
# waits for fs01's \\ad.lab\Files DFS-N root to exist before adding
# itself as the STANDBY target and creating the fs01<->fs02 DFS
# Replication group for the Data share.
#
# HOW IT WORKS
#   Same reboot-persistent, staged pattern as phase3-fs01-unattended.ps1
#   and dcs/phase3-ad02-unattended.ps1: a scheduled task re-launches this
#   script at every startup and on a 2-minute timer until it's done, so
#   it can be started immediately after create-fs01-vm.sh without
#   waiting for fs01 to finish first — it just retries until fs01 is
#   ready to be joined.
#
# STAGES
#   0 - Format data disk as D:, join ad.lab, reboot.
#   1 - Install FS-FileServer/DFS-Namespace/DFS-Replication/FSRM,
#       create D:\Shares\{Data,Profiles,Software}, set NTFS/SMB perms.
#   2 - Wait for \\ad.lab\Files DFS-N root (created by fs01) to exist,
#       add \\FS02\Data as a lower-priority (standby) target, then
#       create/verify the fs01<->fs02 DFS Replication group for Data.
#   3 - Verify (share reachable, DFS-N target present, RG healthy) and
#       finish.
#
# CREDENTIAL HANDLING
#   Same lab-only convention as phase3-fs01-unattended.ps1 — see that
#   file's Get-DomainCredential for the Import-Clixml alternative.

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stateDir   = 'C:\ProvisionState'
$stateFile  = Join-Path $stateDir 'fs02.stage'
$taskName   = 'Phase3-FS02-Continue'
$scriptPath = $MyInvocation.MyCommand.Path
$logFile    = Join-Path $stateDir 'fs02-unattended.log'

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
Start-Transcript -Path $logFile -Append | Out-Null

function Get-Stage {
    if (Test-Path $stateFile) { return [int](Get-Content $stateFile) }
    return 0
}
function Set-Stage([int]$n) { Set-Content -Path $stateFile -Value $n }

function Register-ContinueTask {
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
    # (A) Lab-only plaintext — see phase3-fs01-unattended.ps1 for the
    # Import-Clixml alternative (B) for anything beyond an isolated lab.
    $securePwd = ConvertTo-SecureString 'Server2012!' -AsPlainText -Force
    return New-Object System.Management.Automation.PSCredential('ADLAB\Administrator', $securePwd)
}

function Initialize-DataDisk {
    if ((Test-Path 'D:\') -and (Get-Volume -DriveLetter D -ErrorAction SilentlyContinue).FileSystem -eq 'NTFS') {
        Write-Host "     D: already initialized." -ForegroundColor Green
        return
    }
    Write-Host "     Initializing data disk as D:..." -ForegroundColor Cyan
    $rawDisk = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' } | Select-Object -First 1
    if (-not $rawDisk) {
        throw "No RAW data disk found. Check create-fs02-vm.sh attached a second virtio disk."
    }
    Initialize-Disk -Number $rawDisk.Number -PartitionStyle GPT -Confirm:$false
    $partition = New-Partition -DiskNumber $rawDisk.Number -UseMaximumSize -DriveLetter D
    Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel 'FS02-Data' -Confirm:$false | Out-Null
    Write-Host "     D: formatted (NTFS, label FS02-Data)." -ForegroundColor Green
}

$stage = Get-Stage
Write-Host "=== fs02 unattended provisioning — resuming at stage $stage ===" -ForegroundColor Cyan

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
        @{ Path = 'D:\Shares\Data';     Name = 'Data';     Desc = 'General data share (DFS-R replicated, active/standby with fs01)' },
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
        Write-Host "     Share created: \\FS02\$($s.Name)" -ForegroundColor Green
    }

    Enable-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue
    Set-Stage 2
}

if ((Get-Stage) -eq 2) {
    # ── Stage 2 — wait for fs01's DFS-N root, join as STANDBY,
    #             create the DFS-R group ──────────────────────────
    Write-Host "[Stage 2] Waiting for ADWS/AD readiness..." -ForegroundColor Cyan
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

    Write-Host "[Stage 2] Checking for fs01's \\ad.lab\Files DFS-N root..." -ForegroundColor Cyan
    $root = Get-DfsnRoot -Path '\\ad.lab\Files' -ErrorAction SilentlyContinue
    if (-not $root) {
        Write-Host "     DFS-N root not published yet — fs01 hasn't reached Stage 2." -ForegroundColor Yellow
        Write-Host "     Will retry automatically in 2 minutes." -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        exit
    }
    Write-Host "     DFS-N root found." -ForegroundColor Green

    Write-Host "[Stage 2] Adding \\FS02\Data as the STANDBY target..." -ForegroundColor Cyan
    if (-not (Get-DfsnFolderTarget -Path '\\ad.lab\Files' -TargetPath '\\FS02\Data' -ErrorAction SilentlyContinue)) {
        New-DfsnFolderTarget -Path '\\ad.lab\Files' -TargetPath '\\FS02\Data'
    }
    # Lower priority than fs01's GlobalHigh (set in phase3-fs01-unattended.ps1)
    # means clients only get referred to fs02 if fs01 is unavailable.
    Set-DfsnFolderTarget -Path '\\ad.lab\Files' -TargetPath '\\FS02\Data' `
        -ReferralPriorityClass GlobalLow -ErrorAction SilentlyContinue
    Write-Host "     fs02 published as the STANDBY (GlobalLow priority) DFS-N target." -ForegroundColor Green

    Write-Host "[Stage 2] Creating DFS Replication group FS01-FS02-Data..." -ForegroundColor Cyan
    $rgName = 'FS01-FS02-Data'
    if (-not (Get-DfsReplicationGroup -GroupName $rgName -ErrorAction SilentlyContinue)) {
        New-DfsReplicationGroup -GroupName $rgName -Description 'Active/standby replication of the Data share (fs01 active, fs02 standby)' | Out-Null

        New-DfsReplicatedFolder -GroupName $rgName -FolderName 'Data' -DfsnPath '\\ad.lab\Files' | Out-Null

        Add-DfsrMember -GroupName $rgName -ComputerName 'FS01', 'FS02' | Out-Null

        Set-DfsrMembership -GroupName $rgName -FolderName 'Data' -ComputerName 'FS01' `
            -ContentPath 'D:\Shares\Data' -PrimaryMember $true -Force | Out-Null
        Set-DfsrMembership -GroupName $rgName -FolderName 'Data' -ComputerName 'FS02' `
            -ContentPath 'D:\Shares\Data' -PrimaryMember $false -Force | Out-Null

        Add-DfsrConnection -GroupName $rgName -SourceComputerName 'FS01' -DestinationComputerName 'FS02' | Out-Null

        Write-Host "     DFS-R replication group '$rgName' created (fs01 = primary member)." -ForegroundColor Green
    } else {
        Write-Host "     DFS-R replication group '$rgName' already exists." -ForegroundColor Green
    }

    Set-Stage 3
}

if ((Get-Stage) -eq 3) {
    # ── Stage 3 — verify and finish ──────────────────────────────
    Write-Host "[Stage 3] Verifying..." -ForegroundColor Cyan
    Get-SmbShare | Where-Object { $_.Name -notmatch '^\$' } | Select-Object Name, Path, Description | Out-Host
    Get-DfsnRootTarget -Path '\\ad.lab\Files' | Out-Host
    Get-DfsReplicationGroup -GroupName 'FS01-FS02-Data' -ErrorAction SilentlyContinue | Out-Host
    Get-DfsrState -ComputerName FS01, FS02 -ErrorAction SilentlyContinue | Out-Host

    Unregister-ContinueTask
    Write-Host "=== fs02 unattended provisioning complete — Phase 3 done ===" -ForegroundColor Green
    Write-Host "NOTE: initial DFS-R replication (AD polling interval) can take" -ForegroundColor Yellow
    Write-Host "  up to a few minutes to converge after creation. Check with:" -ForegroundColor Yellow
    Write-Host "  dfsrdiag replicationstate /member:FS02" -ForegroundColor White
}

Stop-Transcript | Out-Null
