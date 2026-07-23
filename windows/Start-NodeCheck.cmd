@echo off
setlocal
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" (
  echo [IPQuality] PowerShell 7.2 or newer is required.
  echo Download: https://aka.ms/powershell-release?tag=stable
  exit /b 1
)
"%PWSH%" -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "%~dp0Prompt-Node.ps1"
endlocal
