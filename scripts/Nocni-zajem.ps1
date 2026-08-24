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
# Absolutna pot: dnevnik pisemo prek .NET, ta pa relativno pot razresi po delovni mapi
# procesa, ki je Set-Location v tej skripti ne spremeni.
$mapaDnevnikov = (Resolve-Path -LiteralPath $mapaDnevnikov).Path

$zaznamek = Get-Date -Format 'yyyy-MM-dd_HHmm'
$dnevnik = Join-Path $mapaDnevnikov "zajem_$zaznamek.log"

# --- kodne strani ------------------------------------------------------------
# Worker pise UTF-8, konzola pa je na tem racunalniku v kodni strani 852. PowerShell izpis
# zunanjega programa dekodira po [Console]::OutputEncoding, zato je "Z" s stresico (UTF-8
# C5 BD) v dnevniku koncal kot dva znaka, "c" s stresico kot trije in pomisljaj kot "OCo".
# Dnevnik pri tem ni bil pokvarjen: bil je pravilen UTF-8, ki je posteno shranil ze
# pokvarjene znake. Napaka nastane na meji med dotnetom in PowerShellom, zato mora biti
# odpravljena tu, preden preberemo prvo vrstico.
#
# Ta datoteka ima odslej UTF-8 BOM, ker PowerShell 5.1 skripto brez njega bere kot ANSI in
# bi sumnike v sporocilih pokvaril ze pri branju same skripte. Sumniki v sporocilih so zato
# od tod naprej dovoljeni; starejsi komentarji ostajajo brez njih.
#
# Nastavitev velja za ta proces in se ne vraca -- skripta tece kot svoj proces (nacrtovana
# naloga, -File), enako kot velja za $env:PIM_SAOP_MODE nizje.
$utf8BrezBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8BrezBom
$OutputEncoding = $utf8BrezBom

function Zapisi([string]$vrstica) {
  $vrstica = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $vrstica"
  Write-Output $vrstica
  # Add-Content -Encoding UTF8 v PowerShell 5.1 datoteko zacne z BOM. Dnevnik bereta clovek
  # in grep, zato gre ven kot UTF-8 brez BOM.
  [System.IO.File]::AppendAllText($dnevnik, $vrstica + [Environment]::NewLine, $utf8BrezBom)
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
  Zapisi "PRESKOČENO: $tece zajem(ov) SAOP_PRODUCTS še teče. Nocojšnji zagon se ne začne."
  exit 0
}

# --- poln ali delta ---------------------------------------------------------
$danes = (Get-Date).Day
$poln = ($danes -eq $DanPolnegaZajema)
$argumenti = @('run', '--project', 'workers\PIM.KatalogWorker', '--', '--max-parallel', "$HkratnihPodjetij")
if ($poln) { $argumenti += '--full' }

Zapisi "Začetek: $(if ($poln) { 'POLN zajem (dan ' + $DanPolnegaZajema + ' v mesecu)' } else { 'delta zajem' }), hkratnih podjetij: $HkratnihPodjetij."
Zapisi "Dnevnik: $dnevnik"

# --- zagon ------------------------------------------------------------------
# Zakaj je zagon ovit tako natancno, kot je. Do 2026-08-24 je tu stala ena sama vrstica:
#
#     & dotnet @argumenti 2>&1 | ForEach-Object { Zapisi $_ }
#
# Pod $ErrorActionPreference = 'Stop' PowerShell vsako vrstico, ki jo dotnet napise na
# stderr, spremeni v ErrorRecord — in ker je nastavitev 'Stop', je to terminirajoca napaka.
# Posledice so bile tri hkrati in nobena ni bila vidna:
#
#   1. skripta je umrla sredi pipeline, zato vrstice "Konec, izhodna koda" ni nikoli
#      zapisala — dnevnik je izgledal, kot da zajem se tece;
#   2. razlog padca ni pristal nikjer: ne v dnevniku, ne v nacrtovani nalogi, ki je
#      pokazala samo LastTaskResult = 1;
#   3. s pipeline je umrl tudi proces workerja. Worker svoj zagon ob prekinitvi sicer zna
#      zapreti (OperationsRun.DisposeAsync ga zakljuci z "Izvajanje je bilo prekinjeno."),
#      a ubit proces tega nima kje izvesti — zato so zagoni v ops.PipelineRun obticali v
#      stanju Running brez konca in jih je bilo treba pospravljati na roke.
#
# Merjeno 2026-08-24 ob 02:00: stiri podjetja, RowsRead = 0, dnevnik pet vrstic, izhod 1;
# zadnja stran iz SAOP v raw.Inbox je bila takrat stara tri dni.
#
# Zato je tu — in samo tu — obravnava napak 'Continue': stderr je pri dotnetu obicajen
# izpis, ne dogodek, ki bi smel ubiti nocno opravilo. Vsaka vrstica gre v dnevnik, vrstice
# s stderr pa oznacene, da se v dnevniku loci, kaj je worker javil kot napako.
$prej = Get-Location
$prejsnjaObravnava = $ErrorActionPreference
$izhod = $null
try {
  Set-Location $resitev
  $env:PIM_SAOP_MODE = 'Live'
  $ErrorActionPreference = 'Continue'
  & dotnet @argumenti 2>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) { Zapisi "STDERR: $($_.Exception.Message)" }
    else { Zapisi $_ }
  }
  $izhod = $LASTEXITCODE
}
catch {
  # Sem pride to, kar ni stderr workerja: dotnet ni na poti, mape ni, povezava je padla.
  Zapisi "NAPAKA: $($_.Exception.Message)"
  $izhod = 1
}
finally {
  $ErrorActionPreference = $prejsnjaObravnava
  Set-Location $prej
}

# Ce se & dotnet sploh ni izvedel, $izhod ostane $null. Prazna izhodna koda se navzven bere
# kot uspeh, zato je to izrecno neuspeh — nacrtovana naloga mora videti razliko.
if ($null -eq $izhod) { $izhod = 1 }

Zapisi "Konec, izhodna koda: $izhod."

# Dnevniki starejsi od 90 dni gredo stran. Brise se izkljucno to, kar je ustvarila ta skripta.
Get-ChildItem $mapaDnevnikov -Filter 'zajem_*.log' |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) } |
  Remove-Item -Force

exit $izhod
