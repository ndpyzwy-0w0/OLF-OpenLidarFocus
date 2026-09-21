@echo off
cd /d "%~dp0"
powershell -NoExit -ExecutionPolicy Bypass -Command ". 'J:\New soft project\commands\env.ps1'; flutter run -d windows"
