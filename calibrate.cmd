@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0checkin.ps1" -Mode ImageCalibrate
echo.
pause
