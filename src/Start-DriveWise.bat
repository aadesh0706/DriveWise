@echo off
title DriveWise
REM Launches DriveWise. Requests administrator permission (needed for a
REM complete scan) and then opens your browser to the dashboard automatically.

net session >nul 2>&1
if %errorLevel% == 0 goto :run

echo Requesting administrator permission for DriveWise...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DriveWise.ps1"
