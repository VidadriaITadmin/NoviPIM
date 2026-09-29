@echo off
rem Ponovno sestavi PIM-procesi.html iz vseh procesov v tej mapi.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\scripts\Procesi.ps1" -Ukaz Graf
start "" "%~dp0PIM-procesi.html"
