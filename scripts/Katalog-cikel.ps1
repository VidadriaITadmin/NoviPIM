<#
.SYNOPSIS
  Urni cikel kataloga: SAOP katalog (delta), narocila iz SAOP, validacija in objava vseh podjetij.

.DESCRIPTION
  Locen od Nocno-vse.ps1, Zaloga-cikel.ps1 in Magento-cikel.ps1, namenoma:

    Nocno-vse.ps1      enkrat na dan, cel vhodni tok (SAOP, dobaviteljev XML, zaloge, validacija,
                       objava) - tezek, ker zajema navzven (SAOP, FTP, HTTPS).
    Zaloga-cikel.ps1   vsakih 5 minut, samo zaloga in hiter profil cena+zaloga (MAGENTO_STOCK_PRICES).
    Katalog-cikel.ps1  (ta skripta) vsako uro: SAOP katalog (delta), narocila, validacija in objava
                       v pim.* za vsa podjetja.
    Magento-cikel.ps1  vsakih 5 minut, samo izdelava katalog.csv in stranke.csv iz objave
                       (MAGENTO_PRODUCTS, MAGENTO_CUSTOMERS) - bere PIM, ne klice SAOP.

  Do 2026-09-21 je ta skripta na koncu izdelala tudi par CSV za Magento. Odslej ga izdeluje
  samostojen cikel (Magento-cikel.ps1 oziroma cikel magento-csv v intranetu): neuspesen vhod iz
  SAOP ne sme biti videti kot neuspesna izdelava CSV in obratno (uporabnik: katalog.csv je
  PIM -> Magento, izdelava CSV je neodvisna od branja/pisanja SAOP). Validacija in objava ostajata
  tu za vsa podjetja, ker VID zaloga in VID cenik v IQ katalog vstopata prek objavljenega sloja
  podjetja 3; cikel CSV ju ponovi le, kadar ta urni cikel ni tekel (meja 90 min).

  To ni isto kot predogled na /splet/izvoz v intranetu: tisti bere iz baze na zahtevo. Dejanski
  datoteki in njuno zgodovino (out.ExportRun, TriggeredBy = Scheduler za cikel) kaze /splet.

.PARAMETER Podjetja
  Podjetja, za katera tecejo narocila, validacija in objava. Privzeto vsa stiri.

.PARAMETER PodjetjeKataloga
  Podjetje, katerega artikli in stranke gredo v katalog.csv in stranke.csv. Privzeto 2
  (IQLighting) in NAMENOMA samo eno: uporabnik 2026-09-15 — »katalog.csv in stranke.csv bi
  mogle biti samo ena datoteka, ne pa da za vsako podjetje posebej imamo katalog«. Splet dobi
  en katalog z IQ artikli, skupno IQ+VID zalogo (146) in B2B ceno iz VID cenika (213). Pred tem
  je zanka tekla cez vsa stiri podjetja (in @(2) je bil ob 210 pomotoma »popravljen« nazaj na
  vsa stiri — to NI bil ostanek pilota, ampak namera). Ne vracaj na seznam.
  Od 2026-09-21 ta skripta izvoza ne izdeluje vec (glej Magento-cikel.ps1); parameter ostaja
  sprejet zaradi zdruzljivosti klicev.

.PARAMETER KorenRepozitorija
  Koren repozitorija; privzeto se izpelje iz mesta skripte.

.PARAMETER MapaWorkerjev
  Mapa objavljenih workerjev (<mapa>\<Worker>\<Worker>.exe). Ce je podana, tece .exe namesto
  dotnet run — tako cikel tece na strezniku brez izvorne kode. Privzeto PIM_PUBLISHED_WORKERS.
#>
[CmdletBinding()]
param(
  [int[]]$Podjetja = @(1, 2, 3, 4),
  [int]$PodjetjeKataloga = 2,
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
$datotekaDnevnika = Join-Path $dnevnik ("katalog-{0:yyyy-MM-dd}.log" -f (Get-Date))

# --- kodne strani (enako kot v Zaloga-cikel.ps1 in Nocno-vse.ps1) ------------------------
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

# --- povezava: ista pot kot v Zaloga-cikel.ps1 / Nocno-vse.ps1 ---------------------------
# PimPovezava (Sql.ps1): okolje, sicer appsettings.Local.json, sicer appsettings.json v korenu.
. (Join-Path $mestoSkripte 'Sql.ps1')
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


# Datoteko, ki jo pise urnik, mora biti mogoce loceno prepoznati od tiste, ki jo je nekdo
# prenesel rocno iz /splet — glej PIM_TRIGGERED_BY v ExportRunLog.cs (worker) oz. AdminConsoleService
# (intranet). Brez tega bi "Zgodovina dostav" na /splet vsak zapis kazala kot "rocno".
$env:PIM_TRIGGERED_BY = 'Scheduler'

# --- Narocila iz SAOP (VNK/VND) za MIN/MID/MAX -------------------------------------------
# Uporabnik 2026-09-15: narocila naj se berejo avtomatsko. Locena razporeda SAOP_ORDERS_VNK in
# SAOP_ORDERS_VND (migracija 210) - kupci in dobavitelji se lahko vklopita/izklopita loceno.
# Sodi sem in ne v Zaloga-cikel.ps1: razpored obeh je na uro (3600 s), enako kot ta cikel; ura
# Windows naloge in razpored v bazi se torej ujemata, brez petminutnega "ni na vrsti" suma.
Korak 'Narocila iz SAOP (VNK/VND)' {
  $env:PIM_SAOP_MODE = 'Live'
  PozeniWorker 'workers\PIM.SaopOrdersWorker' @('--organizations', ($Podjetja -join ','))
}

foreach ($o in $Podjetja) {
  Korak "Osvezitev objave (podjetje $o)" {
    $povezava = PimPovezava $koren
    PimUkaz $povezava "EXEC val.RunValidation @OrganizationId = $o;" | Out-Null
    PimUkaz $povezava "EXEC val.Promote @OrganizationId = $o;" | Out-Null
  }
}

# Izvoz kataloga in strank (katalog.csv, stranke.csv) od 2026-09-21 ni vec tu: izdeluje ga
# samostojen cikel Magento-cikel.ps1 (naloga "PIM magento", v intranetu cikel magento-csv) vsakih
# 5 minut iz objave, ki jo je ta cikel pravkar osvezil. Validacija in objava zgoraj tecejo za vsa
# podjetja, ker VID zaloga in VID cenik v ta katalog vstopata prek objavljenega sloja podjetja 3.

Zapisi "Katalog cikel koncan; padlih korakov: $padli."
exit $padli
