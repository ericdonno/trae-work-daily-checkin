@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0checkin.ps1" -Mode Install
set "setup_result=%errorlevel%"
echo.
if not "%setup_result%"=="0" (
    echo Setup failed with exit code %setup_result%. No verified task was installed.
    pause
    exit /b %setup_result%
)
echo Setup finished and the scheduled task was verified.
echo This folder may be moved or copied; run setup.cmd again afterwards.
pause
exit /b 0
