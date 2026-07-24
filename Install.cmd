@echo off
setlocal
title IPQuality for Windows Installer
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
if errorlevel 1 (
  echo.
  echo [IPQuality] Installation failed.
  pause
  exit /b 1
)
echo.
pause
endlocal
