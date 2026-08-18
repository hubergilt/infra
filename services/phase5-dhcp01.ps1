# phase5-dhcp01.ps1
# Run on dhcp01 - Windows Server 2025 Core
# DHCP Server for LAN 10.0.1.0/24
# Static IP: 10.0.1.30/24

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Step 1 - Rename
Write-Host "[1/6] Renaming to DHCP01..." -ForegroundColor Cyan
if ($env:COMPUTERNAME -ne 'DHCP01') {
    Rename-Computer -NewName 'DHCP01' -Force
    Write-Host "     Renamed. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already DHCP01." -ForegroundColor Green

# Step 2 - Static IP
Write-Host "[2/6] Setting static IP 10.0.1.30/24..." -ForegroundColor Cyan
$ifIndex = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }).InterfaceIndex
Remove-NetIPAddress   -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute       -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress      -InterfaceIndex $ifIndex -IPAddress '10.0.1.30' -PrefixLength 24 -DefaultGateway '10.0.1.1'
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses '10.0.1.10','10.0.1.11'
Start-Sleep -Seconds 5
Write-Host "     IP set: 10.0.1.30/24" -ForegroundColor Green

# Step 3 - Join domain
Write-Host "[3/6] Joining domain ad.lab..." -ForegroundColor Cyan
if ((Get-WmiObject Win32_ComputerSystem).Domain -ne 'ad.lab') {
    $cred = Get-Credential -Message "Enter ADLAB\Administrator" -UserName 'ADLAB\Administrator'
    Add-Computer -DomainName 'ad.lab' -Credential $cred -Force
    Write-Host "     Domain joined. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already domain member." -ForegroundColor Green

# Step 4 - Install DHCP
Write-Host "[4/6] Installing DHCP Server feature..." -ForegroundColor Cyan
Install-WindowsFeature -Name DHCP -IncludeManagementTools
Write-Host "     Feature installed." -ForegroundColor Green

# Step 5 - Configure DHCP scope
Write-Host "[5/6] Configuring DHCP scope for LAN 10.0.1.0/24..." -ForegroundColor Cyan

# Add scope
Add-DhcpServerv4Scope `
    -Name        'ad.lab LAN' `
    -StartRange  '10.0.1.50' `
    -EndRange    '10.0.1.200' `
    -SubnetMask  '255.255.255.0' `
    -Description 'LAN scope for ad.lab domain members' `
    -State       Active

# Scope options
Set-DhcpServerv4OptionValue `
    -ScopeId    '10.0.1.0' `
    -Router     '10.0.1.1' `
    -DnsServer  '10.0.1.10','10.0.1.11' `
    -DnsDomain  'ad.lab'

# Lease duration - 8 hours for lab (shorter than default 8 days)
Set-DhcpServerv4Scope -ScopeId '10.0.1.0' -LeaseDuration '0.08:00:00'

# Exclusions for static assignments
Add-DhcpServerv4ExclusionRange -ScopeId '10.0.1.0' -StartRange '10.0.1.1'  -EndRange '10.0.1.49'

# DNS dynamic update
Set-DhcpServerv4DnsSetting `
    -ScopeId               '10.0.1.0' `
    -DynamicUpdates        Always `
    -DeleteDnsRRonLeaseExpiry $true `
    -UpdateDnsRRForOlderClients $true

Write-Host "     Scope configured: 10.0.1.50-200" -ForegroundColor Green

# Static reservations for known VMs
$reservations = @(
    @{ IP='10.0.1.10'; MAC='52-54-00-49-37-cc'; Name='AD01'   },
    @{ IP='10.0.1.11'; MAC='52-54-00-02-73-68'; Name='AD02'   },
    @{ IP='10.0.1.20'; MAC='52-54-00-29-b6-fc'; Name='CA01'   },
    @{ IP='10.0.1.21'; MAC='52-54-00-d0-92-e0'; Name='CA02'   },
    @{ IP='10.0.1.30'; MAC='52-54-00-fe-d2-cb'; Name='DHCP01' },
    @{ IP='10.0.1.31'; MAC='52-54-00-32-08-19'; Name='FS01'   },
    @{ IP='10.0.1.40'; MAC='52-54-00-a1-d3-37'; Name='APP01'  },
    @{ IP='10.0.1.41'; MAC='52-54-00-40-36-68'; Name='JUMP01' }
)
foreach ($r in $reservations) {
    Add-DhcpServerv4Reservation `
        -ScopeId     '10.0.1.0' `
        -IPAddress   $r.IP `
        -ClientId    $r.MAC `
        -Description $r.Name `
        -ErrorAction SilentlyContinue
    Write-Host "     Reserved: $($r.IP) for $($r.Name)" -ForegroundColor Green
}

# Step 6 - Authorize in AD and verify
Write-Host "[6/6] Authorizing DHCP server in Active Directory..." -ForegroundColor Cyan
Add-DhcpServerInDC -DnsName 'DHCP01.ad.lab' -IPAddress '10.0.1.30'
Set-DhcpServerv4Binding -InterfaceAlias 'Ethernet Instance 0' -BindingState $true

# Verify
Write-Host ""
Write-Host "DHCP Server status:" -ForegroundColor Yellow
Get-DhcpServerv4Scope | Select-Object ScopeId, Name, State, StartRange, EndRange, LeaseDuration
Write-Host ""
Write-Host "DHCP authorized in AD:" -ForegroundColor Yellow
Get-DhcpServerInDC
Write-Host ""
Write-Host "Phase 5 dhcp01 complete." -ForegroundColor Green
Write-Host "Verify from any domain member: ipconfig /all" -ForegroundColor Cyan
