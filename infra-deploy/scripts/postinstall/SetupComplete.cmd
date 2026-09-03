@echo off
:: Auto-executed once by Windows Setup at the end of specialize, as SYSTEM.
:: Chains through the numbered postinstall scripts and logs each step.
setlocal
set LOGDIR=C:\Windows\Setup\Scripts\logs
mkdir "%LOGDIR%" 2>nul

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Windows\Setup\Scripts\01-Wait-DomainReady.ps1"    >> "%LOGDIR%\01-domain.log" 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Windows\Setup\Scripts\02-Install-SQLServer.ps1"   >> "%LOGDIR%\02-sql-install.log" 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Windows\Setup\Scripts\03-Configure-SQLServer.ps1" >> "%LOGDIR%\03-sql-config.log" 2>&1

endlocal
