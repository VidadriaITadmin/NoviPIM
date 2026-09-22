<#
.SYNOPSIS
  Dodeli racunom, ki izdelujejo CSV za Magento, pravico pisanja v izhodno mapo (EXPORT_ROOT) in to preveri.

.DESCRIPTION
  Zakaj obstaja: 2026-09-21 je izvoz katalog.csv/stranke.csv padel 76-krat v 48 urah z "Access to the
  path 'C:\inetpub\wwwroot\PIM_exports_csv\.magento-export.lock' is denied". Mapa je bila ustvarjena
  kot administrator, racun Windows nalog (in racun aplikacijskega bazena IIS) pa je imel samo branje.
  Datoteke za Magento zato niso nastajale, PIM pa je vsak poskus zabelezil kot padec.

  Ta skripta je edini korak, ki ga sistem ne more narediti sam: pravice na mapi so sistemska nastavitev
  in zahtevajo PowerShell kot administrator (na mapi, ki je tvoja, dela tudi brez povisanja).
  Vse ostalo (pot v ops.SystemPath, kljucavnica, oznaka dokoncanosti, zgodovina v out.ExportRun) je
  v kodi. Po tej skripti mora naslednji tek cikla "CSV za Magento" uspeti brez drugih posegov.

  Kaj naredi:
    1. pot vzame iz -Pot ali iz registra ops.SystemPath (kljuc EXPORT_ROOT, glej Nastavi-izvozno-pot.ps1);
    2. mapo ustvari, ce je ni;
    3. vsakemu racunu dodeli Modify z dedovanjem na podmape in datoteke: icacls <mapa> /grant "<racun>:(OI)(CI)M";
    4. izpise dejanski ACL in preveri, da ima vsak racun M ali F;
    5. za trenutni racun naredi se poskusni zapis (ustvari in pobrise datoteko) - enako kot worker.

  Racuni, ki potrebujejo pisanje (podaj tiste, ki pri tebi izdelujejo CSV):
    - racun Windows nalog "PIM magento"/"PIM zaloga" (Namesti-opravila.ps1 jih registrira pod tvojim racunom);
    - racun aplikacijskega bazena IIS, kadar cikle poganja razporejevalnik v intranetu (-BazenIis, npr. PIM_dev_app
      -> "IIS AppPool\PIM_dev_app");
    - racun storitve PIM.AutomationHost (-RacunStoritve), kadar posle poganja gostitelj avtomatike.

  Samo ASCII v tej datoteki (PowerShell 5.1 bere datoteko brez BOM kot ANSI).

.PARAMETER Pot
  Izhodna mapa. Privzeto se prebere iz registra ops.SystemPath (EXPORT_ROOT).

.PARAMETER Racuni
  Racuni v obliki DOMENA\uporabnik. Privzeto trenutni racun ($env:USERDOMAIN\$env:USERNAME).

.PARAMETER BazenIis
  Ime aplikacijskega bazena IIS; doda racun "IIS AppPool\<ime>".

.PARAMETER RacunStoritve
  Racun storitve gostitelja avtomatike (PIM.AutomationHost), npr. DOMENA\pim-avtomatika.

.PARAMETER SamoPreveri
  Nic ne spreminja: izpise ACL, preveri racune in poskusni zapis. Izhod 0 = vse v redu, 1 = manjka pravica.

.PARAMETER KorenRepozitorija
  Koren, od koder se bere appsettings.Local.json, kadar PIM_CONNECTION_STRING ni nastavljena in -Pot ni podana.

.EXAMPLE
  # kot administrator, pot iz registra, racun trenutnega uporabnika in bazen IIS:
  powershell -ExecutionPolicy Bypass -File scripts\Nastavi-pravice-izvozne-mape.ps1 -BazenIis PIM_dev_app

.EXAMPLE
  # samo preveri (brez skrbniskih pravic):
  powershell -ExecutionPolicy Bypass -File scripts\Nastavi-pravice-izvozne-mape.ps1 -SamoPreveri

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\Nastavi-pravice-izvozne-mape.ps1 -Pot D:\Izvozi\Magento -Racuni 'AD\david','AD\pim-avtomatika'
#>
[CmdletBinding()]
param(
  [string]$Pot = '',
  [string[]]$Racuni = @(),
  [string]$BazenIis = '',
  [string]$RacunStoritve = '',
  [switch]$SamoPreveri,
  [string]$KorenRepozitorija = ''
)

$ErrorActionPreference = 'Stop'
$mestoSkripte = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

# icacls pise opozorila na stderr (npr. "The trust relationship between this workstation and the primary
# domain failed", kadar SID-a ni mogoce prevesti v ime); pod 'Stop' bi to prekinilo skripto. Izhod je
# izhodna koda ($LASTEXITCODE), besedilo je samo za izpis.
function IcaclsIzpis([string[]]$argumenti) {
  $prej = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $izhod = & icacls @argumenti 2>&1 | ForEach-Object {
      if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
    }
  }
  finally { $ErrorActionPreference = $prej }
  return ,@($izhod)
}
if ([string]::IsNullOrWhiteSpace($KorenRepozitorija)) { $KorenRepozitorija = Split-Path -Parent $mestoSkripte }

# --- 1. pot ---------------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Pot)) {
  . (Join-Path $mestoSkripte 'Sql.ps1')
  $povezava = PimPovezava $KorenRepozitorija
  $izhod = PimUkaz $povezava "SET NOCOUNT ON; EXEC ops.ResolveSystemPath @PathKey = N'EXPORT_ROOT', @OrganizationId = NULL;"
  $vrstice = @($izhod | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[A-Za-z]:\\' -or $_ -like '\\\\*' })
  if ($vrstice.Count -eq 0) { throw 'Register ops.SystemPath nima nastavljene poti EXPORT_ROOT; podaj -Pot ali jo nastavi z Nastavi-izvozno-pot.ps1.' }
  $Pot = $vrstice[0]
  Write-Host "EXPORT_ROOT iz registra: $Pot"
}
if (-not [System.IO.Path]::IsPathRooted($Pot)) { throw "Pot mora biti absolutna, dobil: $Pot" }

# --- 2. racuni -----------------------------------------------------------------------------
$seznam = New-Object System.Collections.Generic.List[string]
foreach ($r in $Racuni) { if (-not [string]::IsNullOrWhiteSpace($r)) { $seznam.Add($r.Trim()) } }
if ($seznam.Count -eq 0) { $seznam.Add("$($env:USERDOMAIN)\$($env:USERNAME)") }
if (-not [string]::IsNullOrWhiteSpace($BazenIis)) { $seznam.Add("IIS AppPool\$BazenIis") }
if (-not [string]::IsNullOrWhiteSpace($RacunStoritve)) { $seznam.Add($RacunStoritve.Trim()) }
$seznam = @($seznam | Select-Object -Unique)

$identiteta = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$jeSkrbnik = $identiteta.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host ("Mapa: {0}; racuni: {1}; skrbnik: {2}" -f $Pot, ($seznam -join ', '), $(if ($jeSkrbnik) { 'da' } else { 'ne' }))

# --- 3. mapa in pravice --------------------------------------------------------------------
if (-not $SamoPreveri) {
  if (-not (Test-Path -LiteralPath $Pot)) {
    try { New-Item -ItemType Directory -Path $Pot -Force | Out-Null; Write-Host "Mapa ustvarjena: $Pot" }
    catch { throw "Mape $Pot ni mogoce ustvariti ($($_.Exception.Message)). Pozeni PowerShell kot administrator." }
  }
  foreach ($racun in $seznam) {
    $izpis = IcaclsIzpis @("$Pot", '/grant', "${racun}:(OI)(CI)M")
    if ($LASTEXITCODE -ne 0) {
      throw "icacls za racun $racun ni uspel (izhod $LASTEXITCODE): $($izpis -join ' '). Lastnik mape je verjetno skupina Administrators - pozeni skripto kot administrator."
    }
    Write-Host "Pravica spreminjanja dodeljena: $racun"
  }
}

# --- 4. preverba ACL -----------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Pot)) {
  Write-Host "Mapa $Pot ne obstaja." -ForegroundColor Red
  exit 1
}
$acl = IcaclsIzpis @("$Pot")
Write-Host ''
Write-Host 'Dejanski ACL:'
$acl | ForEach-Object { Write-Host "  $_" }

$manjka = @()
foreach ($racun in $seznam) {
  $kratko = $racun.Split('\')[-1]
  $vrstica = $acl | Where-Object { $_ -match [regex]::Escape($kratko) -and ($_ -match '\(M\)' -or $_ -match '\(F\)' -or $_ -match '\(OI\)\(CI\)\(?[^)]*\)?\(M\)' -or $_ -match '\(OI\)\(CI\)F' -or $_ -match '\(OI\)\(CI\)M') }
  if (-not $vrstica) { $manjka += $racun }
}

# --- 5. poskusni zapis kot trenutni racun (enako kot worker) --------------------------------
$poskus = Join-Path $Pot (".pim-probe-{0}" -f [guid]::NewGuid().ToString('N'))
$zapisljiva = $false
try { [System.IO.File]::WriteAllText($poskus, ''); [System.IO.File]::Delete($poskus); $zapisljiva = $true } catch { $zapisljiva = $false }

Write-Host ''
Write-Host ("Poskusni zapis kot {0}\{1}: {2}" -f $env:USERDOMAIN, $env:USERNAME, $(if ($zapisljiva) { 'USPEL' } else { 'NI USPEL' })) -ForegroundColor $(if ($zapisljiva) { 'Green' } else { 'Red' })
if ($manjka.Count -gt 0) {
  Write-Host ("Brez pravice spreminjanja (M) ali polnega dostopa (F): {0}" -f ($manjka -join ', ')) -ForegroundColor Red
  Write-Host 'Pozeni to skripto kot administrator brez -SamoPreveri.' -ForegroundColor Yellow
  exit 1
}
if (-not $zapisljiva) { exit 1 }
Write-Host 'Izhodna mapa je pripravljena; naslednji tek cikla "CSV za Magento" lahko pise vanjo.' -ForegroundColor Green
exit 0
