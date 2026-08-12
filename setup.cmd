@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0checkin.ps1" -Mode Install
echo.
echo Setup finished. This folder may be moved or copied; run setup.cmd again afterwards.
pause
