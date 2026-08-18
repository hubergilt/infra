# phase5-fs01.ps1
# Run on fs01 - Windows Server 2025 Core
# File Server + DNS secondary zone
# Static IP: 10.0.1.31/24

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Step 1 - Rename
Write-Host "[1/7] Renaming to FS01..." -ForegroundColor Cyan
if ($env:COMPUTERNAME -ne 'FS01') {
    Rename-Computer -NewName 'FS01' -Force
    Write-Host "     Renamed. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already FS01." -ForegroundColor Green

# Step 2 - Static IP
Write-Host "[2/7] Setting static IP 10.0.1.31/24..." -ForegroundColor Cyan
$ifIndex = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }).InterfaceIndex
Remove-NetIPAddress   -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute       -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress      -InterfaceIndex $ifIndex -IPAddress '10.0.1.31' -PrefixLength 24 -DefaultGateway '10.0.1.1'
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses '10.0.1.10','10.0.1.11'
Start-Sleep -Seconds 5
Write-Host "     IP set: 10.0.1.31/24" -ForegroundColor Green

# Step 3 - Join domain
Write-Host "[3/7] Joining domain ad.lab..." -ForegroundColor Cyan
if ((Get-WmiObject Win32_ComputerSystem).Domain -ne 'ad.lab') {
    $cred = Get-Credential -Message "Enter ADLAB\Administrator" -UserName 'ADLAB\Administrator'
    Add-Computer -DomainName 'ad.lab' -Credential $cred -Force
    Write-Host "     Domain joined. Rebooting..." -ForegroundColor Yellow
    Restart-Computer -Force
    exit
}
Write-Host "     Already domain member." -ForegroundColor Green

# Step 4 - Install features
Write-Host "[4/7] Installing File Server features..." -ForegroundColor Cyan
Install-WindowsFeature -Name `
    FS-FileServer, `
    FS-DFS-Namespace, `
    FS-DFS-Replication, `
    FS-Resource-Manager, `
    DNS `
    -IncludeManagementTools
Write-Host "     Features installed." -ForegroundColor Green

# Step 5 - Create shares
Write-Host "[5/7] Creating SMB shares..." -ForegroundColor Cyan

$shares = @(
    @{ Path='C:\Shares\Data';    Name='Data';    Desc='General data share' },
    @{ Path='C:\Shares\Profiles'; Name='Profiles'; Desc='Roaming profiles' },
    @{ Path='C:\Shares\Software'; Name='Software'; Desc='Software distribution' }
)

foreach ($s in $shares) {
    New-Item -ItemType Directory -Path $s.Path -Force | Out-Null

    # Set NTFS permissions
    $acl = Get-Acl $s.Path
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

# Step 6 - DNS secondary zone
Write-Host "[6/7] Configuring DNS secondary zone for ad.lab..." -ForegroundColor Cyan
Add-DnsServerSecondaryZone `
    -Name          'ad.lab' `
    -ZoneFile      'ad.lab.dns' `
    -MasterServers '10.0.1.10','10.0.1.11'

Add-DnsServerSecondaryZone `
    -Name          '1.0.10.in-addr.arpa' `
    -ZoneFile      '1.0.10.in-addr.arpa.dns' `
    -MasterServers '10.0.1.10','10.0.1.11'

Write-Host "     DNS secondary zones configured." -ForegroundColor Green

# Allow zone transfers from ad01/ad02 (run on ad01)
Write-Host "     NOTE: Run on ad01 to allow zone transfers:" -ForegroundColor Yellow
Write-Host "     Set-DnsServerPrimaryZone -Name 'ad.lab' -SecondaryServers '10.0.1.31'" -ForegroundColor White

# Step 7 - DFS namespace
Write-Host "[7/7] Creating DFS namespace..." -ForegroundColor Cyan
New-DfsnRoot `
    -Path             '\\ad.lab\Files' `
    -TargetPath       '\\FS01\Data' `
    -Type             DomainV2 `
    -ErrorAction SilentlyContinue
Write-Host "     DFS namespace: \\ad.lab\Files" -ForegroundColor Green

Write-Host ""
Write-Host "FS01 configuration complete." -ForegroundColor Green
Write-Host "Shares available:" -ForegroundColor Cyan
Get-SmbShare | Where-Object { $_.Name -notmatch '^\$' } | Select-Object Name, Path, Description
