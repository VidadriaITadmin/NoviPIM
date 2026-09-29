@echo off
rem Dvoklik: zazene nadzorno plosco razvojne ekipe PIM (v ozadju) in jo odpre v brskalniku.
rem Plosca: http://localhost:5099/  (zivo: naloge, agenti, vrata, zdruzevanje, odlocitve)
rem Rezerva brez Node: staticna stran iz Koordinacija.ps1 -Ukaz Stanje -Odpri
where node >nul 2>nul || (powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Koordinacija.ps1" -Ukaz Stanje -Odpri & exit /b)
powershell -NoProfile -Command "try { Invoke-WebRequest http://localhost:5099/api/stanje -UseBasicParsing -TimeoutSec 5 | Out-Null } catch { Start-Process node -ArgumentList ('\"' + '%~dp0tabla\streznik.mjs' + '\"') -WindowStyle Hidden; Start-Sleep 2 }"
start "" http://localhost:5099/
