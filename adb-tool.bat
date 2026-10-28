@echo off
rem Battery Guard - Windows launcher
rem Double-click this file, or run from a terminal: adb-tool.bat status
rem It simply forwards all arguments to adb-tool.ps1 (PowerShell engine).

chcp 65001 >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0adb-tool.ps1" %*
echo.
if errorlevel 1 (echo [FAILED] see message above) else (echo [DONE])
pause
