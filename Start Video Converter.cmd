@echo off
rem Starts Video Converter from the script, without a console window. The execution-policy
rem bypass applies to this run only; no Windows settings are changed.
rem If it doesn't open, run   "Start Video Converter.cmd" debug   to keep a console and see what it prints.
if /i "%~1"=="debug" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0src\Video-Converter.ps1"
    pause
) else (
    start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0src\Video-Converter.ps1"
)
