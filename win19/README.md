# Windows Serial Console (SAC) Setup for libvirt/KVM

## 1. Enable Serial Console (EMS) inside Windows

Run these commands **as Administrator** in PowerShell or Command Prompt inside the Windows VM:

```powershell
# Enable Emergency Management Services (EMS)
bcdedit /ems on

# Configure serial port (COM1) and baud rate
bcdedit /emssettings EMSPORT:1 EMSBAUDRATE:115200

# Reboot the VM
Restart-Computer

```

## 2. Connect to the Serial Console

Bashvirsh console <domain-name>
Example:
Bashvirsh console ad01
Exit console: Ctrl + ]
If you only see a blank screen after reboot, double-check that the commands above were executed correctly.

## 3. Using SAC (Special Administration Console)

Basic SAC Commands
sacSAC> ch # List available channels
SAC> cmd # Create a new command prompt channel
You will see something like:
textEVENT: A new channel has been created. Use "ch -?" for channel help.
Channel: Cmd0001
Switch to the new channel:
sacSAC> ch -si 1
Login
textPlease enter login credentials.
Username: Administrator
Domain: .
Password: **\*\*\*\***
Once logged in you will get a normal command prompt:
cmdC:\Windows\System32>
Then launch PowerShell if needed:
cmdpowershell

## Change network type

## Install virtio drivers

https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/

1. Identifica la letra de la unidad de CD
   Primero, asegúrate de haber montado la ISO de virtio-win en Virt-Manager. Luego, busca qué letra tiene asignada la lectora:
   powershell

Get-PSDrive -PSProvider FileSystem

Usa el código con precaución.
(Supongamos que la unidad de CD es la D:).

3. Si quieres instalar TODOS los drivers VirtIO (Recomendado)
   Para evitar problemas futuros con el disco duro o el mouse, puedes instalar todos los controladores de la ISO de una vez:
   powershell

pnputil.exe /add-driver "D:\NetKVM\2k19\amd64\*.inf" /install

Usa el código con precaución. 4. Verifica el resultado
Una vez que el comando termine (debería decir "Driver package added successfully"), intenta listar la interfaz de nuevo:
powershell

Get-NetAdapter

Usa el código con precaución.

## 4. Configure Network and Start SSH

After logging into the command prompt (C:\Windows\System32>), launch PowerShell and run the following step by step:
PowerShell# 1. Launch PowerShell
powershell

# 2. List all network adapters to find the correct InterfaceIndex

Get-NetAdapter | Select-Object Name, InterfaceIndex, Status, MacAddress
Note the InterfaceIndex of your active adapter (usually the one with Status = Up).

PowerShell# 3. Remove any existing IP configuration (important!)
$ifIndex = 6 # ← CHANGE THIS to your actual InterfaceIndex

Remove-NetIPAddress -InterfaceIndex $ifIndex -Confirm:$false
Remove-NetRoute -InterfaceIndex $ifIndex -Confirm:$false

PowerShell# 4. Set static IP address
New-NetIPAddress `  -IPAddress 10.0.1.10`
-PrefixLength 24 `  -InterfaceIndex $ifIndex`
-DefaultGateway 10.0.1.1 `
-Confirm:$false

Remove-NetIPAddress -InterfaceIndex 6 -Confirm:$false
Remove-NetRoute -InterfaceIndex 6 -Confirm:$false
New-NetIPAddress -IPAddress 10.0.1.10 -PrefixLength 24 -InterfaceIndex 6 -DefaultGateway 10.0.1.1 -Confirm:$false

PowerShell# 5. Start and enable OpenSSH Server
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

Method 1: Enable Built-in Rules (Recommended)
Windows includes built-in rules for ICMP that are disabled by default. Enabling these is the cleanest method for standard setups.

    To allow IPv4 Ping:
    powershell

Enable-NetFirewallRule -DisplayName "File and Printer Sharing (Echo Request - ICMPv4-In)"

# Open firewall for SSH

New-NetFirewallRule -Name sshd -DisplayName "OpenSSH Server (sshd)" `
-Enabled True -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow

# Start and enable OpenSSH Server

Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

# Optional: Open firewall for SSH

New-NetFirewallRule -Name sshd -DisplayName "OpenSSH Server (sshd)" `
-Enabled True -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow
