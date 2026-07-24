@echo off
setlocal
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" (
  where.exe pwsh.exe >nul 2>nul
  if errorlevel 1 (
    echo [IPQuality] PowerShell 7.2 or newer is required.
    echo Download: https://aka.ms/powershell-release?tag=stable
    exit /b 1
  )
  set "PWSH=pwsh.exe"
)
start "IPQuality" "%PWSH%" -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "%~dp0Start-IPQuality.ps1" %*
endlocal
