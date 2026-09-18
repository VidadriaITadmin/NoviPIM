<#
.SYNOPSIS
  Zalogovni cikel: SAOP zaloga, NW zaloga z FTP in Braytronova zaloga iz XML.

.DESCRIPTION
  Trije viri zaloge in nic drugega. Vsak od njih se v istem prehodu prevzame in prebere v
  stock.*, zato ni locenega opravila za prevzem in locenega za branje - to je bila napacna
  delitev, ki je zalogo drzala eno stopnjo zadaj.

      SAOP        kolicine iz ERP, brez prevzema datoteke
      NW_STOCK    FTP dobavitelja Nowodvorski
      BT_STOCK    XML Braytrona prek HTTPS

  Katalog (BT_XML, NW_XML) tu NE sodi. Braytronov katalog je 19 MB in se bere v nocnem toku;
  v petminutnem ciklu bi bil to prenos 5,5 GB na dan brez pomena.

  Zaloga v out.GetExportRows bere stock.* naravnost (glej Stock.ErpCurrent v migraciji 147) in
  je zato sveza ob vsakem izvozu sama po sebi. Cena pa gre skozi val.Promote v pim.ProductPrice
  in brez njega ostane taka, kot je bila ob zadnjem nocnem toku — do 24 ur stara. Uporabnik
  2026-09-10: "zaloga pa cena ... se morata bolj redno osvezevati". Zato korak "Osvezitev objave"
  spodaj pred izvozom cen/zaloge pozene val.RunValidation + val.Promote — s tem je cena v
  petminutnem oknu, enako kot je ze zdaj zaloga.

  Braytron dovoli en prenos na 180 minut in cakalni cas pove v svojem odgovoru. Prevzemnik ga
  spostuje sam, zato ga petminutni cikel ne klice po nepotrebnem - vmesni cikli samo preskocijo
  ta vir in prevzeta datoteka ostane v veljavi.

  Ista nespremenjena datoteka je isti posnetek: worker to pove in ne zapise nicesar. To ni
  napaka, ampak pricakovano stanje med dvema osvezitvama pri dobavitelju.

.PARAMETER Kaj
  Kateri del cikla naj tece: Saop, Dobavitelji ali Vse. Za rocno rabo; opravilo pozene Vse.

.PARAMETER PoUrniku
  Spostuj razpored iz baze in preskoci, kar se ni na vrsti. To poda nacrtovano opravilo.
  Brez tega stikala se vse pozene takoj - tako je rocni zagon uporaben za preizkus.

.PARAMETER Podjetja
  Podjetja, ki jih obdelamo. Privzeto vsa stiri.

.PARAMETER KorenRepozitorija
  Koren repozitorija; privzeto se izpelje iz mesta skripte.
#>
[CmdletBinding()]
param(
  [ValidateSet('Saop', 'Dobavitelji', 'Vse')] [string]$Kaj = 'Vse',
  [int[]]$Podjetja = @(1, 2, 3, 4),

  # Podjetje, katerega katalog.csv in stranke.csv se s svezo zalogo in cenami obnovita vsakih
  # pet minut. Samo eno, namenoma — glej opis parametra -PodjetjeKataloga v Katalog-cikel.ps1
  # (uporabnik 2026-09-15: en katalog, ne po en na podjetje). Zaloga in cene se iz SAOP se vedno
  # berejo za vsa -Podjetja: VID zaloga in VID cenik vstopata v IQ katalog.
  [int]$PodjetjeKataloga = 2,
  [string]$KorenRepozitorija = '',

  # Mapa objavljenih workerjev (<mapa>\<Worker>\<Worker>.exe). Ce je podana, tece .exe namesto
  # dotnet run — tako cikel tece na strezniku brez izvorne kode. Glej Workerji.ps1.
  [string]$MapaWorkerjev = $env:PIM_PUBLISHED_WORKERS,

  # Spostuj razpored iz ops.ScheduleProfile in preskoci, kar se ni na vrsti. Poda ga nacrtovano
  # opravilo. Clovek, ki skripto pozene sam, hoce videti izid zdaj - zato privzeto ni vklopljeno.
  [switch]$PoUrniku,

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
$datotekaDnevnika = Join-Path $dnevnik ("zaloga-{0:yyyy-MM-dd}.log" -f (Get-Date))

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

$padli = 0

# Stikalo se doda samo, kadar tece po urniku. Zapisano na enem mestu, da se trije klici workerjev
# ne razidejo.
$urnik = if ($PoUrniku) { @('--po-urniku') } else { @() }

# EXEC val.RunValidation / val.Promote pred izvozom cen (glej Sql.ps1 in opis zgoraj); PozeniWorker
# (objavljen .exe ali dotnet run) je skupen v Workerji.ps1.
. (Join-Path $mestoSkripte 'Sql.ps1')
. (Join-Path $mestoSkripte 'Workerji.ps1')

# --- povezava: PIM.B2bWorker bere samo PIM_CONNECTION_STRING (ista pot kot v Nocno-vse.ps1) ---
# PimPovezava: okolje, sicer appsettings.Local.json, sicer appsettings.json v korenu.
try { $env:PIM_CONNECTION_STRING = PimPovezava $koren }
catch { Zapisi "NAPAKA: $($_.Exception.Message)"; exit 99 }

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


# Koren prevzema: isti kot ga uporabi PIM.SourceFetchWorker (PimPotPrevzema v Sql.ps1). Skripta ga
# prevzemniku poda z --target in iz njega bere, zato datoteka ne more pristati drugje, kot beremo.
try { $prevzem = PimPotPrevzema $env:PIM_CONNECTION_STRING $resitev }
catch { Zapisi "OPOZORILO: register LANDING_ROOT ni dosegljiv ($($_.Exception.Message)); velja privzetek."; $prevzem = Join-Path $resitev 'data\prevzem' }

function Korak([string]$ime, [scriptblock]$telo) {
  Zapisi "== $ime =="
  try { & $telo; Zapisi "   konec: $ime" }
  catch {
    # Padec enega vira ne ustavi ostalih; izhodna koda pove, koliko jih je padlo.
    $script:padli++
    Zapisi "   NAPAKA: $($_.Exception.Message)"
  }
}

if ($Kaj -in @('Dobavitelji', 'Vse')) {
  # Samo zalogovna vira. Prevzem in branje gresta skupaj, da zaloga ne caka na naslednji cikel.
  foreach ($vir in @('NW_STOCK', 'BT_STOCK')) {
    Korak "Zaloga $vir" {
      PozeniWorker 'workers\PIM.SourceFetchWorker' (@('--source', $vir, '--target', $prevzem) + $urnik)

      $mapa = Join-Path $prevzem $vir
      if (-not (Test-Path $mapa)) { Zapisi "   preskoceno: mape $mapa ni"; return }

      $datoteke = Get-ChildItem $mapa -File | Where-Object { $_.Extension -notin @('.prenos', '.pocakaj') }
      if (-not $datoteke) { Zapisi '   preskoceno: prevzete datoteke ni'; return }

      foreach ($d in $datoteke) {
        foreach ($o in $Podjetja) {
          PozeniWorker 'workers\PIM.StockFileWorker' (@('--file', $d.FullName, '--source', $vir, '--organization-id', "$o") + $urnik)
        }
      }
    }
  }
}

if ($Kaj -in @('Saop', 'Vse')) {
  Korak 'Zaloga iz SAOP (kolicine)' {
    # Ziv klic je odlocitev cloveka (AGENTS.md #4.5). Vklopljen je zavestno: nalogo registrira
    # clovek z Namesti-opravila.ps1 in s tem privoli v ponavljajoc se klic na ERP.
    $env:PIM_SAOP_MODE = 'Live'
    PozeniWorker 'workers\PIM.SaopStockWorker' (@('--organizations', ($Podjetja -join ',')) + $urnik)
  }
}

# --- Cene: delta zajem za vsa podjetja ------------------------------------------------
# Migracija 204 bere cene neposredno iz canon.ProductPrice. Validacija besedil in objava
# ostaneta v urnem katalogu; petminutni cikel ne validira ponovno celotnega podjetja.
# Uporabnik 2026-09-15: cene se morajo za vsa podjetja osvezevati na 5 min, ne samo za eno -
# prej je bil ta korak trajno omejen na podjetje 2 (pilotni preizkus), razpored SAOP_PRICES v
# ops.ScheduleProfile pa je vseeno zajemal vsa stiri (migracija 210), zato so ostala tri padala
# z "Razpored ni omogocen" vsakic, ko bi kdo poskusil.
if ($Kaj -eq 'Vse') {
  Korak 'Osvezitev cen kataloga' {
    $env:PIM_SAOP_MODE = 'Live'
    PozeniWorker 'workers\PIM.KatalogWorker' @('--organizations', ($Podjetja -join ','), '--endpoints', 'GetPrices')
  }
}

# --- Hitra osvezitev cen in zaloge za splet ------------------------------------------------
# Profil MAGENTO_STOCK_PRICES (migracija 146): sifra, EAN, ceni, DDV in zaloga. Namenoma ne gre
# skozi validacijo — vsebuje samo izdelke, ki so ze na spletu. Uporabnik 2026-09-02: "zaloge in
# cene morajo biti zelo redno osvezene". Datoteka: izvoz\magento\<podjetje>\magento-stock-prices.csv.
#
# Poln izvoz (--export-magento) je tu poleg hitrega profila zato, ker slednji ne prenese
# odstranitve odprodajnega popusta ali novega/ukinjenega izdelka - samo poln izvoz to zajame.
# Uporabnik 2026-09-15: »zaloge se posebej pa cene nekako filajo v ta katalog.csv« - katalog.csv
# in stranke.csv dobita sveze cene in zalogo vsakih 5 minut, brez validacije (ta je na uro v
# Katalog-cikel.ps1). Poln izvoz tece SAMO za -PodjetjeKataloga (en katalog); do 2026-09-15 je
# tekel za vsa stiri podjetja in bil en od dveh vzrokov za deadlocke na val.RunValidation (glej
# Katalog-cikel.ps1 in Sql.ps1). Ce bi bila obremenitev se vedno previsoka, je prva stvar za umik
# prav ta drugi klic, ne prvi.
if ($Kaj -eq 'Vse') {
  Korak 'Izvoz cen in zaloge za splet' {
    foreach ($o in $Podjetja) {
      $izhod = Join-Path $koren "izvoz\magento\$o"
      if (-not (Test-Path $izhod)) { New-Item -ItemType Directory -Path $izhod -Force | Out-Null }
      PozeniWorker 'workers\PIM.B2bWorker' @('--export-profile', 'MAGENTO_STOCK_PRICES', '--organization-id', "$o", '--output-dir', $izhod, '--file-name', 'magento-stock-prices.csv')
    }
  }

  Korak "Osvezitev kataloga in strank s cenami in zalogo (podjetje $PodjetjeKataloga)" {
    # Ciljna mapa ni vec tu: worker jo sam razresi (register ops.SystemPath, kljuc EXPORT_ROOT;
    # glej scripts\Nastavi-izvozno-pot.ps1) — ista kot pri urnem izvozu v Katalog-cikel.ps1.
    PozeniWorker 'workers\PIM.B2bWorker' @('--export-magento', '--organization-id', "$PodjetjeKataloga")
  }
}

Zapisi "Zalogovni cikel koncan; padlih korakov: $padli."
exit $padli
