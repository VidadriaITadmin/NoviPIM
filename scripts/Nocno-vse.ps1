<#
.SYNOPSIS
  Nocno opravilo: vsi vhodi v PIM, po vrsti, z dnevnikom in povzetkom.

.DESCRIPTION
  Do 2026-08-23 je nacrtovana naloga pognala samo zajem iz SAOP (Nocni-zajem.ps1). Vse ostalo —
  dobaviteljev XML, zaloge dobaviteljev, spletni nazivi, zaloga iz SAOP, validacija, objava in
  izvoz — je bilo treba pognati rocno, zato je bil katalog svez, vse drugo pa staro toliko,
  kolikor casa ni nihce nicesar pognal.

  Ta skripta pozene vse po vrsti. Vrstni red ni nakljucen:

    1. SAOP katalog       nova sifra artikla mora obstajati, preden jo kdo obogati
    2. Dobaviteljev XML   lastnosti, kategorije in slike se vezejo na artikel po EAN
    3. Spletni nazivi     zvezki se vezejo na artikel po sifri
    4. Preslikava zaostanka   kar je v raw.Inbox ostalo Pending, gre skozi preslikavo
    5. Zaloge dobavitelja datoteka na disku -> stock.*, za vsa podjetja
    6. SAOP zaloga        kolicine iz ERP (samo, ce je izrecno dovoljeno)
    7. Validacija+objava  sele ko so vsi podatki v katalogu, ima objava kaj objaviti
    8. Izvoz              Magento CSV iz objave

  Zakaj je korak 4 svoj korak in ne del zajema. Zaostanek v raw.Inbox ne nastane zaradi okvare,
  ampak po zasnovi: ko se preslikava dopolni (nova koncna tocka, novo polje), so strani ze
  zajete in cakajo kot Pending pod svojim RunId, ki ga naslednji zajem ne pozna. Doslej jih je
  bilo treba pobrati rocno, RunId po RunId — in ravno zato so v bazi lezale nepreslikane strani
  vseh stirih podjetij, dokler jih ni nekdo prestel.

  Padec enega koraka ne ustavi ostalih: vsak korak je svoj proces in svoja vrstica v dnevniku.
  Izhodna koda je stevilo padlih korakov, da nadzor vidi razliko med "vse v redu" in "eno je
  padlo".

.NOTES
  Zivi klic na SAOP za zalogo je po AGENTS.md #4.5 odlocitev cloveka, zato je za stikalom
  -ZalogaIzSaop in privzeto izklopljen.

  Nacrtovano nalogo Windows registrira scripts\Namesti-nocno-opravilo.ps1 — to je po
  AGENTS.md #4.7 sistemska nastavitev in jo pozene clovek, ne agent.
#>
[CmdletBinding()]
param(
  [ValidateRange(1, 28)] [int]$DanPolnegaZajema = 1,
  [ValidateRange(1, 8)]  [int]$HkratnihPodjetij = 4,
  [int]$SteTeceUr = 6,
  [string]$KorenRepozitorija = '',

  # Mape virov. Privzetki so fixture mape v repozitoriju; ko dobavitelj postavi datoteke drugam,
  # se spremeni parameter nacrtovane naloge in ne skripta.
  [string]$MapaNwXml = '',
  [string]$MapaBtXml = '',
  [string]$MapaSpletnihNazivov = '',
  [string]$MapaZalogNw = '',
  [string]$MapaZalogBt = '',

  # Podjetja, ki jih obdelamo pri virih, kjer podjetje ni del datoteke.
  [int[]]$Podjetja = @(1, 2, 3, 4),

  # Zivi klic na SAOP za kolicine zaloge. Privzeto izklopljen (AGENTS.md #4.5).
  [switch]$ZalogaIzSaop,

  # Preskoci izvoz; uporabno, kadar se izvozna mapa se ne dostavlja nikamor.
  [switch]$BrezIzvoza,

  # Preskoci gradnjo. Privzeto se zgradi enkrat na zacetku, ker workerji tecejo z --no-build.
  [switch]$BrezGradnje,

  # Preskoci zajem iz SAOP. Rabi se dvakrat: kadar je ERP v vzdrzevanju in kadar se preizkusa
  # sama skripta — vse ostalo tece iz datotek in iz baze, brez enega samega klica navzven.
  [switch]$BrezSaopKataloga
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($KorenRepozitorija)) {
  $mestoSkripte = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
  $KorenRepozitorija = Split-Path -Parent $mestoSkripte
}

$resitev = Join-Path $KorenRepozitorija 'PIM_Solution'
if ([string]::IsNullOrWhiteSpace($MapaNwXml))   { $MapaNwXml = Join-Path $resitev 'fixtures\nw' }
if ([string]::IsNullOrWhiteSpace($MapaBtXml))   { $MapaBtXml = Join-Path $resitev 'fixtures\bt' }
if ([string]::IsNullOrWhiteSpace($MapaZalogNw)) { $MapaZalogNw = Join-Path $resitev 'fixtures\stocks\nw' }
if ([string]::IsNullOrWhiteSpace($MapaZalogBt)) { $MapaZalogBt = Join-Path $resitev 'fixtures\stocks\bt' }

$mapaDnevnikov = Join-Path $KorenRepozitorija 'logs'
if (-not (Test-Path $mapaDnevnikov)) { New-Item -ItemType Directory -Path $mapaDnevnikov | Out-Null }
$zaznamek = Get-Date -Format 'yyyy-MM-dd_HHmm'
$dnevnik = Join-Path $mapaDnevnikov "nocno_$zaznamek.log"

function Zapisi([string]$vrstica) {
  $vrstica = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $vrstica"
  Write-Output $vrstica
  Add-Content -Path $dnevnik -Value $vrstica -Encoding UTF8
}

# --- povezava: ista pot kot jo uporablja worker -----------------------------
$povezava = $env:PIM_CONNECTION_STRING
if ([string]::IsNullOrWhiteSpace($povezava)) {
  $lokalne = Join-Path $KorenRepozitorija 'appsettings.Local.json'
  if (-not (Test-Path $lokalne)) { Zapisi 'NAPAKA: ni PIM_CONNECTION_STRING in ni appsettings.Local.json.'; exit 99 }
  $povezava = (Get-Content $lokalne -Raw | ConvertFrom-Json).ConnectionStrings.Pim
}
$env:PIM_CONNECTION_STRING = $povezava

# Poizvedbe gredo skozi sqlcmd, ne skozi ADO.NET. Razlog je prakticen: Microsoft.Data.SqlClient
# je paket NuGet in ne del PowerShella, ob rocnem nalaganju iz izhoda gradnje pa potrebuje se
# domorodni Microsoft.Data.SqlClient.SNI.dll, ki ga Add-Type ne najde. sqlcmd je standardno
# orodje SQL Serverja, je na tem racunalniku in nima teh tezav.
$sqlcmdUkaz = Get-Command sqlcmd -ErrorAction SilentlyContinue
$sqlcmd = if ($sqlcmdUkaz) { $sqlcmdUkaz.Source } else { '' }
if (-not $sqlcmd) {
  Zapisi 'NAPAKA: sqlcmd ni na voljo. Namesti "SQL Server Command Line Utilities" ali dodaj sqlcmd v PATH.'
  exit 97
}

# Streznik in bazo preberemo iz povezovalnega niza, da je vir resnice en sam.
function VrednostIzPovezave([string]$imena) {
  foreach ($del in $povezava -split ';') {
    $par = $del -split '=', 2
    if ($par.Count -eq 2 -and ($imena -split '\|') -contains $par[0].Trim()) { return $par[1].Trim() }
  }
  return ''
}
$streznik = VrednostIzPovezave 'Server|Data Source|Address|Addr'
$baza     = VrednostIzPovezave 'Database|Initial Catalog'
$uporabnik = VrednostIzPovezave 'User ID|UID|User'
$geslo     = VrednostIzPovezave 'Password|PWD'
if ([string]::IsNullOrWhiteSpace($streznik) -or [string]::IsNullOrWhiteSpace($baza)) {
  Zapisi 'NAPAKA: iz povezovalnega niza ni mogoce prebrati streznika in baze.'
  exit 96
}

function Poizvedba([string]$sql) {
  # Poizvedba gre v datoteko in v sqlcmd z -i, ne z -Q. Vecvrsticni -Q se pri prehodu iz
  # PowerShella v domoroden proces razbije in sqlcmd potem javi "' ': Unknown Option";
  # datoteka te poti nima.
  #
  # -h -1 brez glave, -W brez odvecnih presledkov, -b izhodna koda ob napaki SQL,
  # -I dvojni narekovaj kot oznaka imena, -t meja ene poizvedbe v sekundah.
  $zacasna = [System.IO.Path]::GetTempFileName()
  try {
    Set-Content -Path $zacasna -Value $sql -Encoding UTF8
    $ukazniArgumenti = @('-S', $streznik, '-d', $baza, '-C', '-I', '-b', '-h', '-1', '-W', '-t', '7200', '-i', $zacasna)
    $ukazniArgumenti = if ([string]::IsNullOrWhiteSpace($uporabnik)) { @('-E') + $ukazniArgumenti }
                       else { @('-U', $uporabnik, '-P', $geslo) + $ukazniArgumenti }
    $izhod = & $sqlcmd @ukazniArgumenti 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd je vrnil $LASTEXITCODE`: $($izhod -join ' ')" }
    return ($izhod | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
  }
  finally { Remove-Item $zacasna -Force -ErrorAction SilentlyContinue }
}

$padli = New-Object System.Collections.Generic.List[string]
$opravljeni = New-Object System.Collections.Generic.List[string]

function Korak([string]$ime, [scriptblock]$delo) {
  Zapisi "== $ime =="
  $ura = [Diagnostics.Stopwatch]::StartNew()
  try {
    & $delo
    $ura.Stop()
    Zapisi "   konec: $ime ($([int]$ura.Elapsed.TotalSeconds) s)"
    $opravljeni.Add($ime)
  }
  catch {
    $ura.Stop()
    Zapisi "   NAPAKA v koraku '$ime' po $([int]$ura.Elapsed.TotalSeconds) s: $($_.Exception.Message)"
    $padli.Add($ime)
  }
}

function PozeniWorker([string]$projekt, [string[]]$argumenti) {
  $prej = Get-Location
  try {
    Set-Location $resitev
    & dotnet run --project $projekt --no-build -- @argumenti 2>&1 | ForEach-Object { Zapisi "   $_" }
    if ($LASTEXITCODE -ne 0) { throw "worker $projekt je koncal z izhodno kodo $LASTEXITCODE" }
  }
  finally { Set-Location $prej }
}

function ZajemXml([string]$sifraVira, [string]$mapa, [int]$podjetje) {
  if (-not (Test-Path $mapa)) { Zapisi "   preskoceno: mape $mapa ni"; return }
  $env:PIM_XML_SOURCE_CODE = $sifraVira
  $env:PIM_XML_ORGANIZATION_ID = "$podjetje"
  $env:PIM_XML_ROOT = $mapa
  PozeniWorker 'workers\PIM.XmlFileWorker' @()
}

# --- varovalka: dva zajema se ne smeta prekrivati ---------------------------
#
# Sama vrstica Status = 'Running' v ops.PipelineRun ni dokaz, da kaj tece. Zagon, ki mu je
# proces umrl, ostane Running za vedno — v razvojni bazi jih je bilo ob pisanju te skripte
# deset, najstarejsi iz julija. Varovalka, ki bi gledala samo status, bi nocno opravilo
# blokirala vsako noc, dokler tega ne bi nekdo rocno pocistil, in to tiho.
#
# Zato se vprasa se, ali ta zagon se utripa: ops.IntegrationHealth ima za par (podjetje,
# cevovod) zadnji RunId in cas zadnjega utripa. Blokira samo zagon, ki je hkrati Running,
# je zadnji za svoj cevovod IN je utripnil v zadnjih petnajstih minutah. Vse ostalo je
# zapusceno in ne blokira nicesar.
$tece = [int](Poizvedba @"
SELECT COUNT(*)
FROM ops.PipelineRun zagon
INNER JOIN ops.IntegrationHealth zdravje
  ON zdravje.OrganizationId = zagon.OrganizationId AND zdravje.Pipeline = zagon.Pipeline
  AND zdravje.RunId = zagon.RunId
WHERE zagon.Pipeline IN (N'SAOP_PRODUCTS', N'GENERIC_XML') AND zagon.Status = N'Running'
  AND zagon.StartedUtc > DATEADD(hour, -$SteTeceUr, SYSUTCDATETIME())
  AND zdravje.LastHeartbeatUtc > DATEADD(minute, -15, SYSUTCDATETIME());
"@)
if ($tece -gt 0) {
  Zapisi "PRESKOCENO: $tece ziv zajem(ov) se tece (utrip mlajsi od 15 minut). Nocojsnji zagon se ne zacne."
  exit 0
}

# Zapusceni zagoni ne blokirajo, so pa znak, da je nekaj padlo — zato jih povemo.
$zapusceni = [int](Poizvedba @"
SELECT COUNT(*) FROM ops.PipelineRun
WHERE Status = N'Running' AND StartedUtc < DATEADD(hour, -1, SYSUTCDATETIME());
"@)
if ($zapusceni -gt 0) {
  Zapisi "OPOZORILO: v ops.PipelineRun je $zapusceni zagon(ov) v stanju Running brez konca, starejsih od ure. Ne blokirajo, so pa rep prejsnjih padcev."
}

$poln = ((Get-Date).Day -eq $DanPolnegaZajema)
Zapisi "Zacetek nocnega opravila: $(if ($poln) { 'POLN' } else { 'delta' }) zajem, podjetja: $($Podjetja -join ', ')."
Zapisi "Dnevnik: $dnevnik"

# --- 0. gradnja -------------------------------------------------------------
# Workerji tecejo z --no-build, ker bi sicer vsak od dvajsetih zagonov znova prevajal isto
# resitev. Zgradi se torej enkrat na zacetku; ce gradnja pade, ni smisla poganjati nicesar.
if (-not $BrezGradnje) {
  Zapisi '== Gradnja =='
  $prej = Get-Location
  try {
    Set-Location $KorenRepozitorija
    & dotnet build PIM_Solution\PIM.sln -v q --nologo 2>&1 | ForEach-Object { Zapisi "   $_" }
    if ($LASTEXITCODE -ne 0) { Zapisi 'NAPAKA: gradnja je padla. Nocojsnji zagon se ne nadaljuje.'; exit 98 }
  }
  finally { Set-Location $prej }
}

# --- 1. SAOP katalog --------------------------------------------------------
if ($BrezSaopKataloga) {
  Zapisi '== SAOP katalog == preskoceno: stikalo -BrezSaopKataloga. Klica navzven ni bilo.'
}
else {
  Korak 'SAOP katalog' {
    $argumenti = @('--max-parallel', "$HkratnihPodjetij")
    if ($poln) { $argumenti += '--full' }
    $env:PIM_SAOP_MODE = 'Live'
    PozeniWorker 'workers\PIM.KatalogWorker' $argumenti
  }
}

# --- 2. Dobaviteljev XML ----------------------------------------------------
Korak 'Dobaviteljev XML (Nowodvorski)' { foreach ($o in $Podjetja) { ZajemXml 'NW_XML' $MapaNwXml $o } }
Korak 'Dobaviteljev XML (Braytron)'    { foreach ($o in $Podjetja) { ZajemXml 'BT_XML' $MapaBtXml $o } }

# --- 3. Spletni nazivi ------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($MapaSpletnihNazivov)) {
  Korak 'Spletni nazivi (delovni zvezki)' { foreach ($o in $Podjetja) { ZajemXml 'SPLET_XLSX' $MapaSpletnihNazivov $o } }
}

# --- 4. Preslikava zaostanka ------------------------------------------------
# Tece po vseh zajemih in pred objavo: kar je ostalo Pending (nova preslikava nad ze zajetimi
# stranmi, padel zajem, --only-ingest), gre zdaj skozi in je v katalogu, preden objava pogleda,
# kaj sploh ima. Worker si zagone poisce sam; klica na SAOP ni.
Korak 'Preslikava zaostanka v raw.Inbox' {
  $env:PIM_SAOP_MODE = 'Live'
  PozeniWorker 'workers\PIM.KatalogWorker' @('--preslikaj-zaostanek')
}

# --- 5. Zaloge dobaviteljev -------------------------------------------------
# Za vsa podjetja, ne samo za privzeto. Dobaviteljeva zaloga ni last enega podjetja: sifre
# NW.* in BA.* ima vsako od stirih (migracija 087). Ista nespremenjena datoteka je isti
# posnetek — worker to pove in ne zapise nicesar (to ni napaka, glej PIM.StockFileWorker).
Korak 'Zaloge dobaviteljev' {
  foreach ($par in @(@($MapaZalogNw, 'NW_STOCK'), @($MapaZalogBt, 'BT_STOCK'))) {
    $mapa = $par[0]; $vir = $par[1]
    if (-not (Test-Path $mapa)) { Zapisi "   preskoceno: mape $mapa ni"; continue }
    foreach ($datoteka in Get-ChildItem $mapa -File | Where-Object { $_.Name -notlike '~$*' }) {
      foreach ($o in $Podjetja) {
        PozeniWorker 'workers\PIM.StockFileWorker' @('--file', $datoteka.FullName, '--source', $vir, '--organization-id', "$o")
      }
    }
  }
}

# --- 6. Zaloga iz SAOP ------------------------------------------------------
if ($ZalogaIzSaop) {
  Korak 'Zaloga iz SAOP (kolicine)' {
    $env:PIM_SAOP_MODE = 'Live'
    PozeniWorker 'workers\PIM.SaopStockWorker' @('--organizations', ($Podjetja -join ','))
  }
}
else {
  Zapisi '== Zaloga iz SAOP == preskoceno: brez stikala -ZalogaIzSaop (ziv klic je odlocitev cloveka).'
}

# --- 7. Validacija in objava ------------------------------------------------
Korak 'Validacija in objava' {
  foreach ($o in $Podjetja) {
    $null = Poizvedba "EXEC val.RunValidation @OrganizationId = $o;"
    $null = Poizvedba "EXEC val.Promote @OrganizationId = $o;"
    Zapisi "   podjetje ${o}: validirano in objavljeno."
  }
}

# --- 8. Izvoz ---------------------------------------------------------------
if (-not $BrezIzvoza) {
  Korak 'Magento izvoz' {
    foreach ($o in $Podjetja) {
      $izhod = Join-Path $KorenRepozitorija "izvoz\magento\$o"
      if (-not (Test-Path $izhod)) { New-Item -ItemType Directory -Path $izhod -Force | Out-Null }
      PozeniWorker 'workers\PIM.B2bWorker' @('--export-magento', '--organization-id', "$o", '--output-dir', $izhod)
    }
  }
}

# --- povzetek ---------------------------------------------------------------
# Povzetek pove tudi, kaj je ostalo neobdelano. Brez tega je "vse OK" lahko pomenilo, da so
# koraki tekli, podatek pa je ostal lezati v raw.Inbox — natanko to se je dogajalo mesece.
Zapisi ''
$ostaloPending = [int](Poizvedba "SELECT COUNT(*) FROM raw.Inbox WHERE Status = N'Pending';")
$vKaranteni    = [int](Poizvedba "SELECT COUNT(*) FROM raw.Inbox WHERE Status = N'Quarantined';")
Zapisi "POVZETEK: opravljenih $($opravljeni.Count), padlih $($padli.Count)."
Zapisi "   raw.Inbox: Pending $ostaloPending, Quarantined $vKaranteni."
if ($ostaloPending -gt 0) {
  Zapisi '   OPOZORILO: nekaj strani je ostalo nepreslikanih. Poglej raw.Inbox.FailureReason.'
}
foreach ($korak in $opravljeni) { Zapisi "   OK    $korak" }
foreach ($korak in $padli)      { Zapisi "   PADEL $korak" }

# Dnevniki starejsi od 90 dni gredo stran. Brise se izkljucno to, kar je ustvarila ta skripta.
Get-ChildItem $mapaDnevnikov -Filter 'nocno_*.log' |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) } |
  Remove-Item -Force

exit $padli.Count
