@echo off
rem Starts the TV launcher (helper, hotkeys and the launcher window).
rem   start.cmd            full-screen kiosk, as on the TV
rem   start.cmd -Windowed  normal window, for trying it on a desktop PC
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0start.ps1" %*
