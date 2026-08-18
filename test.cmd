@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0checkin.ps1" -Mode Test -Target trae
echo.
pause
