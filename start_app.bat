@echo off
title ytdlpGui
cd /d "%~dp0"

echo =======================================================
echo           Avvio di ytdlpGui...
echo =======================================================
echo.
echo Avvio del micro-server locale...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"

echo.
pause
