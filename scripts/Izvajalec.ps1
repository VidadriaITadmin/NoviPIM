<#
.SYNOPSIS
  Skupna pot do PowerShella in do tihega zaganjalnika za nacrtovana opravila.

.DESCRIPTION
  Dve skripti registrirata nacrtovana opravila (Namesti-opravila.ps1 in Namesti-nocno-opravilo.ps1).
  Dokler je vsaka gradila svoj ukaz po svoje, je popravek v eni pustil drugo, da je nalogo
  registrirala po starem - in okno se je vrnilo. Zato je gradnja ukaza tu, na enem mestu.

  Ni namenjena zagonu; skripti jo vkljucita z zapisom:  . (Join-Path $PSScriptRoot 'Izvajalec.ps1')
#>

# Vrne polno pot do PowerShella, ne samo imena: razporejevalnik ne deduje nase poti PATH in
# prvi zagon je padel z 0x80070002 (datoteke ni mogoce najti), ceprav pwsh.exe v ukazni vrstici
# deluje.
#
# Get-Command pwsh.exe pa ni dovolj. Ce je PowerShell namescen iz Trgovine, kaze pwsh.exe v
# WindowsApps na dvobajtnega skrbnika (app execution alias), ne na program. Skrbnik gre skozi
# AppX aktivacijo, ki si konzolo vzame vedno in za -WindowStyle Hidden ne ve - prav ta je
# vsakih pet minut odprl in zaprl okno sredi tipkanja. Zato poiscemo pravi program: najprej
# obicajno namestitev, sicer alias vprasamo, kje tece.
function PoisciIzvajalca {
  $obicajne = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
    Where-Object { $_ } |
    ForEach-Object { Join-Path $_ 'PowerShell\7\pwsh.exe' } |
    Where-Object { Test-Path $_ }
  if ($obicajne) { return @($obicajne)[0] }

  $ukaz = Get-Command pwsh.exe -ErrorAction SilentlyContinue
  if ($ukaz) {
    # Alias sam pove, kje je pravi program; Get-Command vrne samo skrbnika.
    $prava = & $ukaz.Source -NoProfile -Command '(Get-Process -Id $PID).Path' 2>$null
    if ($prava -and (Test-Path $prava)) { return "$prava".Trim() }
    if (Test-Path $ukaz.Source) { return $ukaz.Source }
  }

  return (Get-Command powershell.exe -ErrorAction Stop).Source
}

# Vrne program in argumente za New-ScheduledTaskAction. Naloga ne pozene PowerShella naravnost,
# ampak prek Tiho.vbs; zakaj tako, je do konca zapisano v Tiho.vbs.
function TihiUkaz {
  param(
    [Parameter(Mandatory = $true)][string]$Skripta,
    [Parameter(Mandatory = $true)][string]$MapaSkript,
    [string[]]$Argumenti = @()
  )

  $tiho = Join-Path $MapaSkript 'Tiho.vbs'
  if (-not (Test-Path $tiho))    { throw "Ni najden zaganjalnik $tiho." }
  if (-not (Test-Path $Skripta)) { throw "Ni najdena skripta $Skripta." }

  $izvajalec = PoisciIzvajalca
  if (-not (Test-Path $izvajalec)) { throw "Izvajalca $izvajalec ni mogoce najti." }
  if ((Get-Item $izvajalec).Length -lt 1kb) {
    throw "Pot $izvajalec je skrbnik Trgovine, ne PowerShell. Namesti PowerShell 7 ali popravi PoisciIzvajalca."
  }

  $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
  if (-not (Test-Path $wscript)) { throw "Ni najden $wscript." }

  return [pscustomobject]@{
    Program   = $wscript
    Argumenti = (@('//B', '//Nologo', "`"$tiho`"", "`"$izvajalec`"",
                   '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Skripta`"") + $Argumenti) -join ' '
  }
}
