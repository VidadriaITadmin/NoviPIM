@echo off
rem Dvoklik: osvezi tablo nalog PIM in jo odpri v brskalniku.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Koordinacija.ps1" -Ukaz Stanje -Odpri
