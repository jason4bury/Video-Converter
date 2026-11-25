@echo off
rem Video Converter - double-click to start it.
rem Each time, this makes (or refreshes) the Video Converter shortcut in this folder and in the Start menu,
rem then starts Video Converter from it. After the first run you can use the shortcut, the Start menu or
rem a pinned taskbar button instead: they start Video Converter without a console window.
rem The execution-policy bypass applies to Video Converter's own run only; no Windows settings are changed.
rem If Video Converter doesn't open, run   "Video Converter.cmd" debug   to start it in this window and see any errors.
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if /i "%~1"=="debug" (
    "%PS%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Video-Converter.ps1"
    pause
    exit /b
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-VideoConverterShortcut.ps1" -Launch
if errorlevel 1 pause
