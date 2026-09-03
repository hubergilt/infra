<#
  Optional follow-up: wires sql01 (primary) and sql02 (replica/standby) into
  an Always On Availability Group, matching the "SQL primary (R/W)" /
  "SQL replica (standby)" roles in general-nw.puml. Run this from a
  management host (e.g. jump01) with the SqlServer PowerShell module and
  connectivity to both nodes, AFTER both VMs have finished their unattended
  build and SQL Server install.

  This is deliberately NOT wired into the unattended chain — AG setup
  touches both nodes together and is easier to get right (and re-run) as a
  separate, explicit step once both instances are confirmed healthy.

  Usage:
    .\Setup-AlwaysOn.ps1 -Primary sql01.ad.lab -Secondary sql02.ad.lab `
        -AgName AG-Data -ListenerIP 10.0.6.72 -ListenerPort 1433
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Primary,
    [Parameter(Mandatory)] [string]$Secondary,
    [string]$AgName = "AG-Data",
    [Parameter(Mandatory)] [string]$ListenerIP,
    [int]$ListenerPort = 1433,
    [string]$SubnetMask = "255.255.255.0"
)

$ErrorActionPreference = "Stop"
Import-Module SqlServer

Write-Output "Enabling Always On on $Primary and $Secondary..."
foreach ($node in @($Primary, $Secondary)) {
    Enable-SqlAlwaysOn -ServerInstance $node -Force
}

Write-Output "NOTE: each node's SQL Server service needs a restart after"
Write-Output "Enable-SqlAlwaysOn before continuing. Restart both instances,"
Write-Output "confirm they're back up, then re-run this script with"
Write-Output "-SkipEnable to continue from the AG creation step."

# --- AG creation (idempotent-ish: check for existing AG first) ---
$existing = Get-SqlAvailabilityGroup -Path "SQLSERVER:\SQL\$Primary\DEFAULT" -ErrorAction SilentlyContinue |
    Where-Object Name -eq $AgName

if ($existing) {
    Write-Output "Availability Group '$AgName' already exists on $Primary — skipping creation."
} else {
    # A database must already exist on the primary and be in FULL recovery
    # with at least one log backup taken before it can join an AG.
    # This lab script assumes you've created/prepared that DB separately;
    # adjust $dbName below to match.
    $dbName = "AppDb"

    $primaryReplica = New-SqlAvailabilityReplica -Name $Primary -EndpointUrl "TCP://${Primary}:5022" `
        -AvailabilityMode "SynchronousCommit" -FailoverMode "Automatic" -AsTemplate

    $secondaryReplica = New-SqlAvailabilityReplica -Name $Secondary -EndpointUrl "TCP://${Secondary}:5022" `
        -AvailabilityMode "SynchronousCommit" -FailoverMode "Automatic" -AsTemplate

    New-SqlAvailabilityGroup -Name $AgName -Path "SQLSERVER:\SQL\$Primary\DEFAULT" `
        -AvailabilityReplica @($primaryReplica, $secondaryReplica) `
        -Database $dbName

    Join-SqlAvailabilityGroup -Path "SQLSERVER:\SQL\$Secondary\DEFAULT" -Name $AgName

    New-SqlAvailabilityGroupListener -Name "${AgName}-listener" `
        -Path "SQLSERVER:\SQL\$Primary\DEFAULT\AvailabilityGroups\$AgName" `
        -StaticIp "${ListenerIP}/${SubnetMask}" -Port $ListenerPort

    Write-Output "Availability Group '$AgName' created with listener ${ListenerIP}:${ListenerPort}."
}
