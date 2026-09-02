<#
.SYNOPSIS
  Nadzor: preveri zastale obdelave in razposlje alarme.

.DESCRIPTION
  To je edini del avtomatike, ki pove, da se je nekaj ustavilo. Brez njega odpoved ostane tiha:
  izmerjeno 28. 8. 2026 je zaloga iz SAOP padla 18-krat zapored (izklopljen VPN) in tega ni
  izvedel nihce, ker ALERT_DISPATCH in WATCHDOG nista tekla nikoli.

  Dva koraka:

    1. Nadzornik (PIM.Watchdog)         najde izvajanja, ki so obticala, in odprte tezave
    2. Razposiljanje (PIM.AlertDispatcher)  odprte alarme poslje prejemnikom po e-posti

  Razposiljanje je za varovalko PIM_ALERT_DELIVERY_ENABLED. Brez nje worker alarme samo prebere
  in izpise, posta pa ne odide - tako se v razvoju ne posilja pravih sporocil. Na strezniku se
  spremenljivka nastavi enkrat in ostane.

  Nadzornik se NIKOLI ne izklopi sam po napakah (MaxConsecutiveFailures je pri WATCHDOG NULL).
  Ce bi se, bi izgubili prav tistega, ki naj bi povedal, da je nekaj narobe.

.PARAMETER KorenRepozitorija
  Koren repozitorija; privzeto se izpelje iz mesta skripte.
#>
[CmdletBinding()]
param([string]$KorenRepozitorija = '')

$ErrorActionPreference = 'Stop'

$mestoSkripte = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$koren = if ([string]::IsNullOrWhiteSpace($KorenRepozitorija)) { Split-Path -Parent $mestoSkripte } else { $KorenRepozitorija }
$resitev = Join-Path $koren 'PIM_Solution'
if (-not (Test-Path $resitev)) { throw "Ni najdena mapa $resitev." }

$dnevnik = Join-Path $koren 'logs'
if (-not (Test-Path $dnevnik)) { New-Item -ItemType Directory -Path $dnevnik | Out-Null }
$datotekaDnevnika = Join-Path $dnevnik ("nadzor-{0:yyyy-MM-dd}.log" -f (Get-Date))

# --- kodne strani ------------------------------------------------------------
# Worker pise UTF-8, konzola pa je na tem racunalniku v kodni strani 852. PowerShell izpis
# zunanjega programa dekodira po [Console]::OutputEncoding, zato je "Watchdog pregled je
# koncan" v dnevniku pristal kot "kon-Zcan". Dnevnik pri tem ni bil pokvarjen: bil je
# pravilen UTF-8, ki je posteno shranil ze pokvarjene znake. Napaka nastane na meji med
# dotnetom in PowerShellom, zato mora biti odpravljena tu, preden preberemo prvo vrstico.
# Isto je ze v Nocno-vse.ps1; tu je manjkalo.
$utf8BrezBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8BrezBom
$OutputEncoding = $utf8BrezBom

function Zapisi([string]$vrstica) {
  $z = "{0:HH:mm:ss}  {1}" -f (Get-Date), $vrstica
  Write-Output $z
  # Add-Content -Encoding UTF8 v PowerShell 5.1 datoteko zacne z BOM. Dnevnik bereta clovek
  # in grep, zato gre ven kot UTF-8 brez BOM.
  [System.IO.File]::AppendAllText($datotekaDnevnika, $z + [Environment]::NewLine, $utf8BrezBom)
}

# PIM.AlertDispatcher bere povezavo samo iz okoljske spremenljivke in brez nje konca z 2.
# Ostali workerji jo znajo prebrati iz appsettings.Local.json; da se nacini ne razhajajo,
# jo tu preberemo iz iste datoteke in postavimo za ta proces.
if ([string]::IsNullOrWhiteSpace($env:PIM_CONNECTION_STRING)) {
  $nastavitve = Join-Path $koren 'appsettings.Local.json'
  if (Test-Path $nastavitve) {
    $env:PIM_CONNECTION_STRING = (Get-Content $nastavitve -Raw | ConvertFrom-Json).ConnectionStrings.Pim
  }
}
if ([string]::IsNullOrWhiteSpace($env:PIM_CONNECTION_STRING)) { throw 'Povezava Pim ni na voljo.' }

$padli = 0

function PozeniWorker([string]$projekt) {
  $prej = Get-Location
  try {
    Set-Location $resitev
    $prejsnjaObravnava = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      & dotnet run --project $projekt --no-build 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { Zapisi "   STDERR: $($_.Exception.Message)" }
        else { Zapisi "   $_" }
      }
    }
    finally { $ErrorActionPreference = $prejsnjaObravnava }
    if ($LASTEXITCODE -ne 0) { throw "worker $projekt je koncal z izhodno kodo $LASTEXITCODE" }
  }
  finally { Set-Location $prej }
}

function Korak([string]$ime, [scriptblock]$telo) {
  Zapisi "== $ime =="
  try { & $telo; Zapisi "   konec: $ime" }
  catch { $script:padli++; Zapisi "   NAPAKA: $($_.Exception.Message)" }
}

Korak 'Nadzornik zastalih obdelav' { PozeniWorker 'workers\PIM.Watchdog' }
Korak 'Razposiljanje alarmov'      { PozeniWorker 'workers\PIM.AlertDispatcher' }

Zapisi "Nadzor koncan; padlih korakov: $padli."
exit $padli
