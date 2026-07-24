@echo off
setlocal
title IPQuality for Windows Uninstaller
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1" %*
if errorlevel 1 (
  echo.
  echo [IPQuality] Uninstallation failed.
  pause
  exit /b 1
)
echo.
pause
endlocal
