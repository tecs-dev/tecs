@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tecs.ps1" %*
exit /b %ERRORLEVEL%
