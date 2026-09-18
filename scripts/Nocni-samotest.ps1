<#
.SYNOPSIS
  Nocni samotest celote: pozene tests\PIM.SelfTest.Nightly in rezultat zapise v bazo.

.DESCRIPTION
  Vsak kos sistema ima svoj zeleni test, celota nima nobenega. Zato se na vprasanje "ali PIM
  zdaj deluje" ni dalo odgovoriti drugace kot z odpiranjem sestih strani in ugibanjem.

  Samotest enkrat na noc prehodi celo verigo — baza, razporedi, srcni utrip, zagoni, katalog,
  karantena, kakovost, spletna datoteka, odhodna vrsta, echo in svezina izvozov — in vsakemu
  koraku izmeri cas. Rezultat gre v ops.SelfTestRun in ops.SelfTestStep (migracija 172); skrbnik
  ga vidi na /sistem in /sistem/samotest, brez branja dnevnikov.

  Samotest samo bere. Ne klice SAOP-a, ne posilja nicesar navzven in ne spreminja podatkov;
  edini zapis je njegov lastni rezultat, edina datoteka pa zacasni CSV, ki ga na koncu pobrise.
  Zato se sme izvajati tudi v produkciji.

  Izhodna koda:
    0  vse je uspelo ali so samo opozorila (karantena, mrtva sporocila)
    1  vsaj en korak je padel — sistem tega dela ne opravlja
    2  samotesta ni bilo mogoce zagnati (ni povezave, ni prevoda)

  Opozorilo ni napaka: nocno opravilo ne sme vsako jutro javljati okvare, ker je v karanteni
  pet vrstic.

.PARAMETER KorenRepozitorija
  Koren repozitorija. Privzeto se izracuna iz mesta te skripte.

.PARAMETER Profil
  Izvozni profil, na katerem samotest dokaze, da spletna datoteka se vedno nastane.
  Privzeto MAGENTO_STOCK_PRICES — isti, ki ga vsakih pet minut izvaza Zaloga-cikel.ps1.

.PARAMETER Podjetje
  Podjetje za ta izvoz. Privzeto 2 (IQLighting), ki ima dejanski spletni katalog.

.NOTES
  Nacrtovano nalogo Windows registrira scripts\Namesti-samotest.ps1 — to je po AGENTS.md #4.7
  sistemska nastavitev in jo pozene clovek, ne agent.
#>
[CmdletBinding()]
param(
  [string]$KorenRepozitorija = '',
  [string]$Profil = 'MAGENTO_STOCK_PRICES',
  [ValidateRange(1, 99)] [int]$Podjetje = 2,

  # Pozeni tudi, ce samotest ze poganja razporejevalnik v aplikaciji (glej spodaj).
  [switch]$Vseeno
)

$ErrorActionPreference = 'Stop'

$mestoSkripte = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $KorenRepozitorija) { $KorenRepozitorija = Split-Path -Parent $mestoSkripte }
$resitev = Join-Path $KorenRepozitorija 'PIM_Solution'
$projekt = Join-Path $resitev 'tests\PIM.SelfTest.Nightly'
if (-not (Test-Path $projekt)) { Write-Error "Ni najden projekt $projekt."; exit 2 }

# --- dnevnik ---------------------------------------------------------------
$mapaDnevnikov = Join-Path $KorenRepozitorija 'logs'
if (-not (Test-Path $mapaDnevnikov)) { New-Item -ItemType Directory -Path $mapaDnevnikov | Out-Null }
$zaznamek = Get-Date -Format 'yyyyMMdd_HHmmss'
$dnevnik = Join-Path $mapaDnevnikov "samotest_$zaznamek.log"

function Zapisi($besedilo) {
  $vrstica = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $besedilo
  Write-Output $vrstica
  [System.IO.File]::AppendAllText($dnevnik, $vrstica + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

# --- povezava --------------------------------------------------------------
# Enako kot Nocno-vse.ps1: iz okolja, sicer iz appsettings.Local.json. Vrednost se nikoli ne
# izpise, ne v konzolo in ne v dnevnik.
$povezava = $env:PIM_CONNECTION_STRING
if (-not $povezava) {
  $lokalne = Join-Path $KorenRepozitorija 'appsettings.Local.json'
  if (-not (Test-Path $lokalne)) { Zapisi 'NAPAKA: ni PIM_CONNECTION_STRING in ni appsettings.Local.json.'; exit 2 }
  $povezava = (Get-Content $lokalne -Raw | ConvertFrom-Json).ConnectionStrings.Pim
}
if (-not $povezava) { Zapisi 'NAPAKA: v appsettings.Local.json ni ConnectionStrings:Pim.'; exit 2 }

$env:PIM_CONNECTION_STRING = $povezava

. (Join-Path $mestoSkripte 'Sql.ps1')
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

$env:PIM_SELFTEST_PROFILE = $Profil
$env:PIM_SELFTEST_ORG = "$Podjetje"

# Enaka pogodba kot pri ops.BeginRun (migracija 144): ob dveh ponoci je razlika med "urnik je
# pognal" in "nekdo je pritisnil" prvo vprasanje.
if (-not $env:PIM_TRIGGERED_BY) { $env:PIM_TRIGGERED_BY = 'Task' }

Zapisi "Samotest se zacenja. Profil=$Profil, podjetje=$Podjetje, sprozil=$($env:PIM_TRIGGERED_BY)."

Push-Location $resitev
try {
  # --no-build je namenoma izpuscen: nocna naloga tece na tem, kar je v repozitoriju zdaj,
  # in ne na binarju, ki je ostal od zadnjega rocnega prevoda.
  $izhod = & dotnet run --project $projekt 2>&1
  $koda = $LASTEXITCODE
}
finally {
  Pop-Location
}

foreach ($vrstica in $izhod) { Zapisi $vrstica }
Zapisi "Izhodna koda: $koda"
Zapisi "Dnevnik: $dnevnik"

# Dnevniki starejsi od 90 dni gredo stran. Brise se izkljucno to, kar je ustvarila ta skripta.
Get-ChildItem $mapaDnevnikov -Filter 'samotest_*.log' |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) } |
  Remove-Item -Force -ErrorAction SilentlyContinue

exit $koda
