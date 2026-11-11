@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0login.ps1" %*
exit /b %errorlevel%
