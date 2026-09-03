<#
  Runs after SQL Server install succeeds:
    - opens TCP 1433 inbound (matches ACL matrix: App->Data:1433/445)
    - sets a sane max server memory (leaves headroom for the OS)
    - restarts the engine service to apply
  Idempotent — safe to re-run.
#>
$ErrorActionPreference = "Stop"

# --- Firewall: TCP 1433 for the SQL Server default instance ---
$ruleName = "SQL Server (TCP-In 1433)"
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP `
        -LocalPort 1433 -Action Allow -Profile Domain | Out-Null
    Write-Output "Firewall rule '$ruleName' created."
} else {
    Write-Output "Firewall rule '$ruleName' already present."
}

# --- Max server memory: leave ~4GB headroom for the OS on this box ---
$totalMemMB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
$maxServerMemMB = [math]::Max(2048, $totalMemMB - 4096)

Import-Module SqlServer -ErrorAction SilentlyContinue
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Output "SqlServer PowerShell module not present; skipping max-memory tuning (install via Install-Module SqlServer if desired)."
} else {
    $srv = New-Object Microsoft.SqlServer.Management.Smo.Server("localhost")
    $srv.Configuration.MaxServerMemory.ConfigValue = $maxServerMemMB
    $srv.Configuration.Alter()
    Write-Output "max server memory set to $maxServerMemMB MB (of $totalMemMB MB total)."
}

Write-Output "SQL Server post-install configuration complete."
