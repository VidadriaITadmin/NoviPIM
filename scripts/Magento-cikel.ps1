<#
.SYNOPSIS
  CSV za Magento: katalog.csv in stranke.csv iz objave v PIM (podjetje 2), vsakih 15 minut (242; prej 5).

.DESCRIPTION
  Samostojen cikel, locen od Zaloga-cikel.ps1, Katalog-cikel.ps1 in Nocno-vse.ps1 (2026-09-21):
  izdelava CSV bere samo PIM in ne klice SAOP ali Magenta. Do takrat je poln izvoz tekel na koncu
  vseh treh ciklov in vsak padec vhoda (SAOP nedosegljiv) ali izvoza (pravice do izhodne mape) je
  drugega pobarval rdece. Uporabnik: katalog.csv je PIM -> Magento; izdelava CSV je neodvisna od
  branja/pisanja SAOP.

  Korak je en sam: PIM.B2bWorker --export-magento --osvezi-validacijo --starost-validacije N.
  Validacija in objava (val.RunValidation + val.Promote) teceta samo, kadar je najstarejsa
  validacija aktivnega izdelka podjetja starejsa od N minut (privzeto 90): urni Katalog-cikel.ps1
  ju sicer ze opravi, validacija celega podjetja pa traja minute in ne sodi v vsak petminutni tik.
  Zaloga in cene v datoteki so sveze ne glede na validacijo (out.GetExportRows bere stock.* in
  cenik neposredno).

  Ciljna mapa: register ops.SystemPath (kljuc EXPORT_ROOT, glej Nastavi-izvozno-pot.ps1), sicer
  PIM_EXPORT_ROOT, sicer izvoz\magento\<podjetje>. Par se zamenja pod kljucavnico in oznako
  magento-export.complete; neuspeh pusti prejsnji veljavni par. Vsak poskus je vrstica v
  out.ExportRun (tudi padec na kljucavnici ali pravicah), vidna na /splet.

  Isti cikel poganja razporejevalnik v intranetu (cikel magento-csv, /sistem/workerji); ta skripta
  je za racunalnik brez tekocega intraneta in se sama umakne, kadar intranet drzi najem.

.PARAMETER PodjetjeKataloga
  Podjetje kataloga. Privzeto 2 (IQLighting) in namenoma samo eno - glej Katalog-cikel.ps1.

.PARAMETER StarostValidacije
  Meja v minutah: validacija in objava teceta samo, ce je validacija podjetja starejsa. 0 = vedno.

.PARAMETER KorenRepozitorija
  Koren repozitorija; privzeto se izpelje iz mesta skripte.

.PARAMETER MapaWorkerjev
  Mapa objavljenih workerjev (<mapa>\<Worker>\<Worker>.exe); glej Workerji.ps1.

.PARAMETER Vseeno
  Pozeni tudi, ce cikle ze poganja razporejevalnik v aplikaciji.
#>
[CmdletBinding()]
param(
  [int]$PodjetjeKataloga = 2,
  [int]$StarostValidacije = 90,
  [string]$KorenRepozitorija = '',
  [string]$MapaWorkerjev = $env:PIM_PUBLISHED_WORKERS,
  [switch]$Vseeno
)

$ErrorActionPreference = 'Stop'

$mestoSkripte = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$koren = if ([string]::IsNullOrWhiteSpace($KorenRepozitorija)) { Split-Path -Parent $mestoSkripte } else { $KorenRepozitorija }
# Mapa resitve je potrebna samo za dotnet run; z objavljenimi workerji je na strezniku ni (Workerji.ps1).
$resitev = Join-Path $koren 'PIM_Solution'

$dnevnik = Join-Path $koren 'logs'
if (-not (Test-Path $dnevnik)) { New-Item -ItemType Directory -Path $dnevnik | Out-Null }
$datotekaDnevnika = Join-Path $dnevnik ("magento-{0:yyyy-MM-dd}.log" -f (Get-Date))

# --- kodne strani (enako kot v Zaloga-cikel.ps1 in Katalog-cikel.ps1) ----------------------
$utf8BrezBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8BrezBom
$OutputEncoding = $utf8BrezBom

function Zapisi([string]$vrstica) {
  $z = "{0:HH:mm:ss}  {1}" -f (Get-Date), $vrstica
  Write-Output $z
  [System.IO.File]::AppendAllText($datotekaDnevnika, $z + [Environment]::NewLine, $utf8BrezBom)
}

$padli = 0

# PozeniWorker (objavljen .exe ali dotnet run) je skupen v Workerji.ps1.
. (Join-Path $mestoSkripte 'Workerji.ps1')

function Korak([string]$ime, [scriptblock]$telo) {
  Zapisi "== $ime =="
  try { & $telo; Zapisi "   konec: $ime" }
  catch {
    $script:padli++
    Zapisi "   NAPAKA: $($_.Exception.Message)"
  }
}

# --- povezava: ista pot kot v ostalih ciklih (Sql.ps1: okolje, appsettings.Local.json, appsettings.json)
. (Join-Path $mestoSkripte 'Sql.ps1')
try { $env:PIM_CONNECTION_STRING = PimPovezava $koren }
catch { Zapisi "NAPAKA: $($_.Exception.Message)"; exit 99 }

# Razporejevalnik v aplikaciji (migracija 221): kadar intranet drzi najem v ops.SchedulerLease, ta
# cikel ze poganja sam; naloga Windows bi ga pognala se enkrat.
if (-not $Vseeno) {
  $lastnikRazporejevalnika = PimRazporejevalnikVAplikaciji $env:PIM_CONNECTION_STRING
  if ($lastnikRazporejevalnika) {
    Zapisi "PRESKOCENO: cikel poganja razporejevalnik v aplikaciji ($lastnikRazporejevalnika). Windows naloga ni vec potrebna - odstrani jo z scripts\Namesti-opravila.ps1 -Odstrani. Za rocni zagon kljub temu dodaj -Vseeno."
    exit 0
  }
}

# Zgodovina na /splet loci urnik od rocnega prenosa (PIM_TRIGGERED_BY -> out.ExportRun.TriggeredBy).
$env:PIM_TRIGGERED_BY = 'Scheduler'

Korak "Validacija in izdelava CSV za Magento (podjetje $PodjetjeKataloga)" {
  PozeniWorker 'workers\PIM.B2bWorker' @('--export-magento', '--osvezi-validacijo', '--starost-validacije', "$StarostValidacije", '--organization-id', "$PodjetjeKataloga")
}

Zapisi "Cikel CSV za Magento koncan; padlih korakov: $padli."
exit $padli
