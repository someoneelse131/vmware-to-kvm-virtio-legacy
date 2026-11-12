@echo off
wpeinit

REM Give WinPE a moment to finish initialization
ping -n 3 127.0.0.1 >nul

setlocal EnableExtensions EnableDelayedExpansion

echo Running PowerShell Driver Injection Script...
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File X:\driver_injection.ps1
