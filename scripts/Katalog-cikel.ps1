<#
.SYNOPSIS
  Urni izvoz celotnega kataloga in strank za splet (katalog.csv, stranke.csv).

.DESCRIPTION
  Locen od Nocno-vse.ps1 in Zaloga-cikel.ps1, namenoma:

    Nocno-vse.ps1     enkrat na dan, cel vhodni tok (SAOP, dobaviteljev XML, zaloge, validacija,
                       objava, izvoz) — tezek, ker zajema navzven (SAOP, FTP, HTTPS).
    Zaloga-cikel.ps1   vsakih 5 minut, samo zaloga in hiter profil cena+zaloga (MAGENTO_STOCK_PRICES).
    Katalog-cikel.ps1  (ta skripta) vsako uro, samo objava + poln izvoz (MAGENTO_PRODUCTS,
                       MAGENTO_CUSTOMERS) — brez zunanjih klicev, zato je poceni pognati pogosteje
                       kot enkrat na dan.

  Uporabnik 2026-09-10: katalog naj se osvezuje vsako uro; cena in zaloga (ki sta stolpca v isti
  datoteki) pa pogosteje — to pokrije Zaloga-cikel.ps1 s petminutnim val.Promote. Ta skripta pred
  vsakim izvozom se enkrat pozene val.RunValidation + val.Promote (poceni, ista operacija kot v
  Zaloga-cikel.ps1), da urni izvoz ne zamudi objave, ki jo je Zaloga-cikel.ps1 naredil minuto prej.

  Datoteki gresta v izvoz\magento\<podjetje>\ — ista mapa in ista imena (katalog.csv,
  stranke.csv), kot ju pise nocni tok (MagentoExportCommand.ExecuteAsync). Kdorkoli iz
  te mape bere (uvoznik na spletni strani), z urnim ciklom ne dobi drugacnega imena ali poti,
  samo pogostejso osvezitev.

  To ni isto kot predogled/prenos na /splet v intranetu: tisti bere iz baze na zahtevo, ta
  skripta pise datoteko na disk. Glej primerjavo v out.ExportRun (TriggeredBy = Scheduler za to
  skripto, Human za prenos iz brskalnika) — oboje je vidno na /splet pod "Zgodovina dostav".

.PARAMETER Podjetja
  Podjetja, za katera tecejo narocila, validacija in objava. Privzeto vsa stiri.

.PARAMETER PodjetjeKataloga
  Podjetje, katerega artikli in stranke gredo v katalog.csv in stranke.csv. Privzeto 2
  (IQLighting) in NAMENOMA samo eno: uporabnik 2026-09-15 — »katalog.csv in stranke.csv bi
  mogle biti samo ena datoteka, ne pa da za vsako podjetje posebej imamo katalog«. Splet dobi
  en katalog z IQ artikli, skupno IQ+VID zalogo (146) in B2B ceno iz VID cenika (213). Pred tem
  je zanka tekla cez vsa stiri podjetja (in @(2) je bil ob 210 pomotoma »popravljen« nazaj na
  vsa stiri — to NI bil ostanek pilota, ampak namera). Ne vracaj na seznam.

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

# En par datotek, samo podjetje iz -PodjetjeKataloga (glej opis parametra). Validacija in objava
# zgoraj tecejo za vsa podjetja, ker VID zaloga in VID cenik v ta katalog vstopata prek objavljenega
# sloja podjetja 3 — brez njegove objave bi bila IQ datoteka stara pri zalogi in B2B ceni.
Korak "Izvoz kataloga in strank (podjetje $PodjetjeKataloga)" {
  # Ciljna mapa ni vec tu: worker jo sam razresi (register ops.SystemPath, kljuc EXPORT_ROOT;
  # glej scripts\Nastavi-izvozno-pot.ps1), da je ena sprememba dovolj za urnik in nocni tok skupaj.
  PozeniWorker 'workers\PIM.B2bWorker' @('--export-magento', '--organization-id', "$PodjetjeKataloga")
}

Zapisi "Katalog cikel koncan; padlih korakov: $padli."
exit $padli
