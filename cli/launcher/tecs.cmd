@echo off
rem cmd.exe shim for the PowerShell launcher used by the Windows installation.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tecs.ps1" %*
exit /b %ERRORLEVEL%
