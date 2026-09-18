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

.PARAMETER MapaWorkerjev
  Mapa objavljenih workerjev (<mapa>\<Worker>\<Worker>.exe). Ce je podana, tece .exe namesto
  dotnet run — tako nadzor tece na strezniku brez izvorne kode. Privzeto PIM_PUBLISHED_WORKERS.
#>
[CmdletBinding()]
param(
  [string]$KorenRepozitorija = '',
  [string]$MapaWorkerjev = $env:PIM_PUBLISHED_WORKERS,

  # Pozeni tudi, ce cikle ze poganja razporejevalnik v aplikaciji (glej spodaj).
  [switch]$Vseeno
)

$ErrorActionPreference = 'Stop'

$mestoSkripte = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$koren = if ([string]::IsNullOrWhiteSpace($KorenRepozitorija)) { Split-Path -Parent $mestoSkripte } else { $KorenRepozitorija }
# Mapa resitve je potrebna samo za dotnet run; z objavljenimi workerji je na strezniku ni (Workerji.ps1).
$resitev = Join-Path $koren 'PIM_Solution'

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
# jo tu preberemo po isti poti (PimPovezava: okolje, .Local.json, .json) in postavimo za ta proces.
. (Join-Path $mestoSkripte 'Sql.ps1')
$env:PIM_CONNECTION_STRING = PimPovezava $koren

# Razporejevalnik v aplikaciji (2026-09-17, migracija 221): kadar intranet drzi najem v
# ops.SchedulerLease, ta cikel ze poganja sam; naloga Windows bi ga pognala se enkrat. -Vseeno
# je za cloveka, ki skripto pozene rocno in hoce izid zdaj.
if (-not $Vseeno) {
  $lastnikRazporejevalnika = PimRazporejevalnikVAplikaciji $env:PIM_CONNECTION_STRING
  if ($lastnikRazporejevalnika) {
    Zapisi "PRESKOCENO: cikel poganja razporejevalnik v aplikaciji ($lastnikRazporejevalnika). Windows naloga ni vec potrebna - odstrani jo z scripts\Namesti-opravila.ps1 -Odstrani. Za rocni zagon kljub temu dodaj -Vseeno."
    exit 0
  }
}


$padli = 0

# PozeniWorker (objavljen .exe ali dotnet run) je skupen v Workerji.ps1.
. (Join-Path $mestoSkripte 'Workerji.ps1')

function Korak([string]$ime, [scriptblock]$telo) {
  Zapisi "== $ime =="
  try { & $telo; Zapisi "   konec: $ime" }
  catch { $script:padli++; Zapisi "   NAPAKA: $($_.Exception.Message)" }
}

Korak 'Nadzornik zastalih obdelav' { PozeniWorker 'workers\PIM.Watchdog' }
Korak 'Razposiljanje alarmov'      { PozeniWorker 'workers\PIM.AlertDispatcher' }

Zapisi "Nadzor koncan; padlih korakov: $padli."
exit $padli
