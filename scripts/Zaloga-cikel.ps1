<#
.SYNOPSIS
  Zalogovni cikel cez dan: prevzem datotek, dobaviteljeva zaloga in zaloga iz SAOP.

.DESCRIPTION
  Nocno opravilo (Nocno-vse.ps1) pozene cel tok enkrat na dan. Zaloga se cez dan premika
  bistveno hitreje od kataloga, zato tece v svojem, pogostejsem ciklu.

  Ritem je enak kot v ops.ScheduleProfile (migraciji 106 in 107) — urnik naloge in razpored v
  bazi se ne smeta razhajati, sicer worker zavrne zagon z napako 51100:

      -Kaj Prevzem   180 min   Braytron dovoli en prenos na 180 minut
      -Kaj Datoteke   60 min   bere lokalno datoteko, ne dobavitelja
      -Kaj Saop       15 min   nas ERP, brez omejitve pogostosti

  Zaloga je samo za branje. Nobena od teh poti ne pise kolicin nazaj v SAOP.

.PARAMETER Kaj
  Kateri del cikla naj tece: Prevzem, Datoteke, Saop ali Vse.

.PARAMETER Podjetja
  Podjetja, ki jih obdelamo. Privzeto vsa stiri.

.PARAMETER KorenRepozitorija
  Koren repozitorija; privzeto se izpelje iz mesta skripte.
#>
[CmdletBinding()]
param(
  [ValidateSet('Prevzem', 'Datoteke', 'Saop', 'Vse')] [string]$Kaj = 'Vse',
  [int[]]$Podjetja = @(1, 2, 3, 4),
  [string]$KorenRepozitorija = ''
)

$ErrorActionPreference = 'Stop'

$mestoSkripte = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$koren = if ([string]::IsNullOrWhiteSpace($KorenRepozitorija)) { Split-Path -Parent $mestoSkripte } else { $KorenRepozitorija }
$resitev = Join-Path $koren 'PIM_Solution'
if (-not (Test-Path $resitev)) { throw "Ni najdena mapa $resitev." }

$dnevnik = Join-Path $koren 'logs'
if (-not (Test-Path $dnevnik)) { New-Item -ItemType Directory -Path $dnevnik | Out-Null }
$datoteka = Join-Path $dnevnik ("zaloga-{0:yyyy-MM-dd}.log" -f (Get-Date))

function Zapisi([string]$vrstica) {
  $z = "{0:HH:mm:ss}  {1}" -f (Get-Date), $vrstica
  Write-Output $z
  Add-Content -Path $datoteka -Value $z -Encoding UTF8
}

$padli = 0

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
    # Padec enega koraka ne ustavi ostalih; izhodna koda pove, koliko jih je padlo.
    $script:padli++
    Zapisi "   NAPAKA: $($_.Exception.Message)"
  }
}

if ($Kaj -in @('Prevzem', 'Vse')) {
  Korak 'Prevzem dobaviteljevih datotek' { PozeniWorker 'workers\PIM.SourceFetchWorker' @() }
}

if ($Kaj -in @('Datoteke', 'Vse')) {
  # Ista nespremenjena datoteka je isti posnetek: worker to pove in ne zapise nicesar. To ni
  # napaka - dobavitelj datoteke ne osvezuje ob vsakem nasem zagonu.
  Korak 'Zaloga dobaviteljev iz datotek' {
    foreach ($par in @(@('NW_STOCK'), @('BT_STOCK'))) {
      $vir = $par[0]
      $mapa = Join-Path $resitev "data\prevzem\$vir"
      if (-not (Test-Path $mapa)) { Zapisi "   preskoceno: mape $mapa ni"; continue }
      foreach ($d in Get-ChildItem $mapa -File | Where-Object { $_.Name -notlike '*.prenos' }) {
        foreach ($o in $Podjetja) {
          PozeniWorker 'workers\PIM.StockFileWorker' @('--file', $d.FullName, '--source', $vir, '--organization-id', "$o")
        }
      }
    }
  }
}

if ($Kaj -in @('Saop', 'Vse')) {
  Korak 'Zaloga iz SAOP (kolicine)' {
    # Ziv klic je odlocitev cloveka (AGENTS.md #4.5). Tu je vklopljen zavestno: nalogo registrira
    # clovek z Namesti-opravila.ps1 in s tem privoli v ponavljajoc se klic na ERP.
    $env:PIM_SAOP_MODE = 'Live'
    PozeniWorker 'workers\PIM.SaopStockWorker' @('--organizations', ($Podjetja -join ','))
  }
}

Zapisi "Zalogovni cikel koncan; padlih korakov: $padli."
exit $padli
