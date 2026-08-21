<#
.SYNOPSIS
  Nocni zajem iz SAOP. Enkrat na mesec poln, sicer delta.

.DESCRIPTION
  To je edina stvar, ki jo pozene nacrtovana naloga Windows. Skripta sama odloci, ali je
  nocojsnji zagon poln ali delta, in poskrbi, da se dva zajema ne prekrivata.

  Zakaj poln enkrat mesecno. Delta vprasa SAOP za zapise, spremenjene po mejniku, zato po
  zasnovi ne more povedati dvojega:
    - da je bil artikel v SAOP izbrisan (datum spremembe ima samo tisto, kar obstaja),
    - da SAOP kaksne spremembe ni ozigosal z novim datumom.
  Poln zajem je edini nacin, da se to sploh izve. Zato ni varovalka, ampak redno opravilo.

  Zakaj ponoci. Poln zajem stirih podjetij je 300.000+ zapisov in vec sto klicev na SAOP;
  izmerjeno 2026-08-21 traja od nekaj minut do vec kot ure na podjetje. Podnevi bi to
  jemalo zmogljivost ERP, ki ga hkrati uporabljajo ljudje.

.NOTES
  Pravilo "kateri dan v mesecu" je zaenkrat parameter te skripte. Naslednji korak je, da se
  preseli v ops.ScheduleProfile, tako da se ritem spremeni z enim UPDATE in ne s spremembo
  skripte. Dokler to ni narejeno, je resnica tu — in to je zapisano, da se ne pozabi.
#>
[CmdletBinding()]
param(
  # Na kateri dan v mesecu naj bo zajem poln. 1 = prvi dan.
  [ValidateRange(1, 28)]
  [int]$DanPolnegaZajema = 1,

  # Koliko podjetij hkrati. Znotraj podjetja gre klic za klicem, zato je to hkrati
  # zgornja meja hkratnih zahtevkov na SAOP.
  [ValidateRange(1, 8)]
  [int]$HkratnihPodjetij = 4,

  # Ce zadnji zagon se tece in ni starejsi od tega, se nocojsnji preskoci.
  [int]$SteTeceUr = 6,

  # Prazno pomeni "izpelji iz mesta skripte". Privzetka ni v param bloku, ker $PSScriptRoot
  # tam ob zagonu prek -File ni vedno napolnjen.
  [string]$KorenRepozitorija = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($KorenRepozitorija)) {
  $mestoSkripte = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
  $KorenRepozitorija = Split-Path -Parent $mestoSkripte
}

$resitev = Join-Path $KorenRepozitorija 'PIM_Solution'
$mapaDnevnikov = Join-Path $KorenRepozitorija 'logs'
if (-not (Test-Path $mapaDnevnikov)) { New-Item -ItemType Directory -Path $mapaDnevnikov | Out-Null }

$zaznamek = Get-Date -Format 'yyyy-MM-dd_HHmm'
$dnevnik = Join-Path $mapaDnevnikov "zajem_$zaznamek.log"

function Zapisi([string]$vrstica) {
  $vrstica = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $vrstica"
  Write-Output $vrstica
  Add-Content -Path $dnevnik -Value $vrstica -Encoding UTF8
}

# --- povezava: ista pot kot jo uporablja worker -----------------------------
$povezava = $env:PIM_CONNECTION_STRING
if ([string]::IsNullOrWhiteSpace($povezava)) {
  $lokalne = Join-Path $KorenRepozitorija 'appsettings.Local.json'
  if (-not (Test-Path $lokalne)) {
    Zapisi 'NAPAKA: ni PIM_CONNECTION_STRING in ni appsettings.Local.json.'
    exit 2
  }
  $povezava = (Get-Content $lokalne -Raw | ConvertFrom-Json).ConnectionStrings.Pim
}

function Poizvedba([string]$sql) {
  $ukaz = New-Object System.Data.SqlClient.SqlCommand
  $povezavaObjekt = New-Object System.Data.SqlClient.SqlConnection $povezava
  try {
    $povezavaObjekt.Open()
    $ukaz.Connection = $povezavaObjekt
    $ukaz.CommandText = $sql
    return $ukaz.ExecuteScalar()
  }
  finally { $povezavaObjekt.Dispose() }
}

# --- varovalka: dva zajema se ne smeta prekrivati ---------------------------
# Dva hkratna polna zajema bi SAOP-u podvojila breme, v raw.Inbox pa ne bi prinesla nicesar
# novega: strani z isto vsebino se prepoznajo po hashu in se ne vstavijo znova.
$tece = Poizvedba @"
SELECT COUNT(*) FROM ops.PipelineRun
WHERE Pipeline = N'SAOP_PRODUCTS' AND Status = N'Running'
  AND StartedUtc > DATEADD(hour, -$SteTeceUr, SYSUTCDATETIME());
"@

if ([int]$tece -gt 0) {
  Zapisi "PRESKOCENO: $tece zajem(ov) SAOP_PRODUCTS se tece. Nocojsnji zagon se ne zacne."
  exit 0
}

# --- poln ali delta ---------------------------------------------------------
$danes = (Get-Date).Day
$poln = ($danes -eq $DanPolnegaZajema)
$argumenti = @('run', '--project', 'workers\PIM.KatalogWorker', '--', '--max-parallel', "$HkratnihPodjetij")
if ($poln) { $argumenti += '--full' }

Zapisi "Zacetek: $(if ($poln) { 'POLN zajem (dan ' + $DanPolnegaZajema + ' v mesecu)' } else { 'delta zajem' }), hkratnih podjetij: $HkratnihPodjetij."
Zapisi "Dnevnik: $dnevnik"

# --- zagon ------------------------------------------------------------------
$prej = Get-Location
try {
  Set-Location $resitev
  $env:PIM_SAOP_MODE = 'Live'
  & dotnet @argumenti 2>&1 | ForEach-Object { Zapisi $_ }
  $izhod = $LASTEXITCODE
}
finally { Set-Location $prej }

Zapisi "Konec, izhodna koda: $izhod."

# Dnevniki starejsi od 90 dni gredo stran. Brise se izkljucno to, kar je ustvarila ta skripta.
Get-ChildItem $mapaDnevnikov -Filter 'zajem_*.log' |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) } |
  Remove-Item -Force

exit $izhod
