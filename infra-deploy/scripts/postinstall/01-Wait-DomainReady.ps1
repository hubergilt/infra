<#
  Domain join happens declaratively during the specialize pass (before this
  script runs), but the secure channel can take a few seconds to settle,
  and SQL Server setup needs a healthy domain membership if you're using
  domain service accounts. Wait for it rather than racing it.
#>
$maxAttempts = 30
$delaySeconds = 10

for ($i = 1; $i -le $maxAttempts; $i++) {
    try {
        $inDomain = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
        if ($inDomain -and (Test-ComputerSecureChannel -ErrorAction SilentlyContinue)) {
            Write-Output "Domain membership confirmed on attempt $i."
            exit 0
        }
    } catch {
        Write-Output "Attempt $i check failed: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $delaySeconds
}

Write-Output "WARNING: domain secure channel not confirmed after $($maxAttempts * $delaySeconds)s — proceeding anyway."
exit 0
