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
  [string]$KorenRepozitorija = '',

  # Spostuj razpored iz ops.ScheduleProfile in preskoci, kar se ni na vrsti. Poda ga nacrtovano
  # opravilo. Clovek, ki skripto pozene sam, hoce videti izid zdaj - zato privzeto ni vklopljeno.
  [switch]$PoUrniku
)

$ErrorActionPreference = 'Stop'

$mestoSkripte = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$koren = if ([string]::IsNullOrWhiteSpace($KorenRepozitorija)) { Split-Path -Parent $mestoSkripte } else { $KorenRepozitorija }
$resitev = Join-Path $koren 'PIM_Solution'
if (-not (Test-Path $resitev)) { throw "Ni najdena mapa $resitev." }

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

function PozeniWorker([string]$projekt, [string[]]$argumenti) {
  $prej = Get-Location
  try {
    Set-Location $resitev
    $prejsnjaObravnava = $ErrorActionPreference
    try {
      # Izhodna koda je merilo, ne to, ali je worker kaj napisal na stderr.
      $ErrorActionPreference = 'Continue'
      & dotnet run --project $projekt --no-build -- @argumenti 2>&1 | ForEach-Object {
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
      PozeniWorker 'workers\PIM.SourceFetchWorker' (@('--source', $vir) + $urnik)

      $mapa = Join-Path $resitev "data\prevzem\$vir"
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

Zapisi "Zalogovni cikel koncan; padlih korakov: $padli."
exit $padli
