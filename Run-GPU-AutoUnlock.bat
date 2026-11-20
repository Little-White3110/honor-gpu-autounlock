@echo off
setlocal

rem === Self-elevate to Administrator ===
net session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator privileges. Click YES in the UAC prompt...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

rem === Resolve main script: prefer files next to this launcher, fallback to original tools dir ===
set "SCRIPT=%~dp0Set-GpuAutoSwitch.ps1"
if not exist "%SCRIPT%" set "SCRIPT=C:\Users\32732\Desktop\TRAE SOLO\honor power\tools\Set-GpuAutoSwitch.ps1"
if not exist "%SCRIPT%" (
    echo ERROR: Set-GpuAutoSwitch.ps1 not found. Keep all files in the same folder.
    pause
    exit /b 1
)

echo.
echo ============================================================
echo   GPU AutoUnlock - Lazy Launcher
echo   Pure toggle / NO clock cap / OSD suppressed
echo ============================================================
echo.
echo   Auto Fn+P toggle when GPU hits thermal throttle (30W lock).
echo   Clock cap: OFF (performance first, may hit the wall again).
echo   OSD overlay suppressed while toggling at GPU load ^>= 50%%.
echo.
echo   Minimize this window. Press Ctrl+C or close it to stop.
echo ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -SuppressOsd -MaxSwitches 0

echo.
echo [!] Daemon stopped. Press any key to close...
pause >nul
