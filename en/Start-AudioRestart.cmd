@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0AudioRestartTool.ps1"
exit /b %errorlevel%
