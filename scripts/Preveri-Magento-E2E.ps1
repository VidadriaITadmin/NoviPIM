<#
.SYNOPSIS
  En ukaz, ki pove, ali katalog.csv/stranke.csv za Magento dejansko delujejo od baze do datoteke.

.DESCRIPTION
  scripts\Nocni-samotest.ps1 (PIM.SelfTest.Nightly) dokaze, da izvozna procedura vrne vrstice -
  pise pa v %TEMP% neposredno iz out.GetExportRows in nikoli ne gre skozi PIM.B2bWorker ali
  EXPORT_ROOT. Zato lahko javi "USPEL", tudi ce je prava izhodna mapa nezapisljiva in noben
  katalog.csv nikoli ne nastane. Ta skripta preveri natanko to vrzel: dejansko izhodno mapo,
  razporejevalnik, zadnji resnicni zagon in - kadar je varno - se en resnicni zagon v izolirano
  mapo, ki dokaze, da je cevovod sam pravilen, tudi kadar prava mapa (se) ni zapisljiva.

  Koraki:
    1. POVEZAVA            - baza je dosegljiva (Sql.ps1: okolje, sicer appsettings.Local.json).
    2. MIGRACIJE            - vse datoteke sql\migrations so uporabljene na tej bazi.
    3. RAZPOREJEVALNIK      - ops.SchedulerLease: kdo drzi najem in ali je ziv.
    4. CIKEL_MAGENTO        - ops.WorkerCycle 'magento-csv': vklopljen, razmik, teka, zadnji uspeh.
    5. IZHODNA_MAPA         - EXPORT_ROOT: obstaja, zapisljiva za TA racun (klice
                              Nastavi-pravice-izvozne-mape.ps1 -SamoPreveri, ne spreminja nicesar).
    6. ZADNJI_PRAVI_IZVOZ   - out.ExportRun: zadnje stanje MAGENTO_PRODUCTS/MAGENTO_CUSTOMERS.
    7. DOKAZ_CEVOVODA       - sveza zagon PIM.B2bWorker v izolirano mapo (ne v EXPORT_ROOT, ne
                              sock z zivim razporejevalnikom): marker, stevilo vrstic/stolpcev
                              proti registru, brez BOM, LF, ujemanje z novim out.ExportRun.
    8. ZIVA_APLIKACIJA      - ce na znanem portu (launch.json) tece intranet, preveri /health.

  Kar ta skripta NAMENOMA ne naredi:
    - ne registrira nacrtovanih nalog (AGENTS.md #4.7 - to naredi clovek, glej Namesti-opravila.ps1);
    - ne spreminja pravic mape (samo prebere stanje; popravek je Nastavi-pravice-izvozne-mape.ps1
      brez -SamoPreveri, zahteva administratorja);
    - ne pozene resnicnega izvoza v EXPORT_ROOT, kadar razporejevalnik v aplikaciji ze drzi najem -
      dva socasna zagona v isto mapo bi se le prerekala za kljucavnico (glej korak 4/6 namesto tega);
    - ne klice SAOP, Magento ali posilja e-poste;
    - ne zaganja scripts\run_tests.ps1 (traja >1 h in potrebuje mirno bazo) - to je locen korak.

  Izhodna koda: 0 = vse OK ali samo opozorila, 1 = vsaj en korak PADEL.

.PARAMETER Podjetje
  Podjetje za dokaz cevovoda. Privzeto 2 (IQLighting, edino s katalog.csv/stranke.csv).

.PARAMETER PrisiliResnicniIzvoz
  Tudi kadar razporejevalnik v aplikaciji ne drzi najem, vseeno ne pozeni resnicnega izvoza v
  EXPORT_ROOT - privzeto se korak 6 omeji na branje zadnjega zapisa. S to stikalo skripta poskusi
  en resnicen zagon v EXPORT_ROOT (uporabno na racunalniku brez razporejevalnika in brez Windows
  naloge, kjer drugace nihce ne bi nikoli poskusil).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\Preveri-Magento-E2E.ps1
#>
[CmdletBinding()]
param(
  [ValidateRange(1, 99)] [int]$Podjetje = 2,
  [switch]$PrisiliResnicniIzvoz
)

$ErrorActionPreference = 'Stop'
$mestoSkripte = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$koren = Split-Path -Parent $mestoSkripte
$resitev = Join-Path $koren 'PIM_Solution'

. (Join-Path $mestoSkripte 'Sql.ps1')

$koraki = New-Object System.Collections.Generic.List[object]
function Korak([string]$koda, [string]$naslov, [string]$status, [string]$podrobnost) {
  $koraki.Add([pscustomobject]@{ Koda = $koda; Naslov = $naslov; Status = $status; Podrobnost = $podrobnost })
  $oznaka = switch ($status) { 'OK' { 'OK      ' } 'OPOZ' { 'OPOZORI ' } 'PADEL' { 'PADEL   ' } default { 'PRESKOCI' } }
  $barva = switch ($status) { 'OK' { 'Green' } 'OPOZ' { 'Yellow' } 'PADEL' { 'Red' } default { 'DarkGray' } }
  Write-Host ("{0}  {1,-18} {2}" -f $oznaka, $koda, $naslov) -ForegroundColor $barva
  if ($podrobnost) { Write-Host ("           " + $podrobnost) }
}

Write-Host "Preverba E2E: PIM -> katalog.csv/stranke.csv (podjetje $Podjetje)" -ForegroundColor Cyan
Write-Host ('-' * 78)

# --- 1. POVEZAVA -------------------------------------------------------------
$povezava = $null
try {
  $povezava = PimPovezava $koren
  $env:PIM_CONNECTION_STRING = $povezava
  $strezDb = PimUkaz $povezava "SET NOCOUNT ON; SELECT @@SERVERNAME + N' / ' + DB_NAME();"
  Korak 'POVEZAVA' 'Baza je dosegljiva' 'OK' "$strezDb"
}
catch {
  Korak 'POVEZAVA' 'Baza je dosegljiva' 'PADEL' $_.Exception.Message
  Write-Host ('-' * 78)
  Write-Host "Brez povezave preostali koraki nimajo smisla - konec." -ForegroundColor Red
  exit 1
}

# --- 2. MIGRACIJE --------------------------------------------------------------
try {
  $datoteke = Get-ChildItem (Join-Path $resitev 'sql\migrations') -Filter '*.sql' | Select-Object -ExpandProperty Name
  $uveljavljene = @(PimUkaz $povezava "SET NOCOUNT ON; SELECT MigrationId FROM dbo.SchemaMigration;" |
    Where-Object { $_ -is [string] -and $_.Trim() -ne '' })
  $manjkajo = @($datoteke | Where-Object { $uveljavljene -notcontains $_ })
  if ($manjkajo.Count -eq 0) {
    Korak 'MIGRACIJE' 'Vse datoteke migracij so uveljavljene' 'OK' "$($datoteke.Count) datotek, $($uveljavljene.Count) uveljavljenih v bazi"
  } else {
    Korak 'MIGRACIJE' 'Vse datoteke migracij so uveljavljene' 'PADEL' ("Manjka: " + ($manjkajo -join ', ') + " - pozeni PIM.Migrator ali Invoke-PendingMigrations.ps1.")
  }
}
catch { Korak 'MIGRACIJE' 'Vse datoteke migracij so uveljavljene' 'PADEL' $_.Exception.Message }

# --- 3. RAZPOREJEVALNIK --------------------------------------------------------
$lastnikNajema = ''
try {
  $vrstica = PimUkaz $povezava "SET NOCOUNT ON; SELECT Owner + N'|' + Application + N'|' + CONVERT(nvarchar(30), ExpiresUtc, 126) + N'|' + CASE WHEN ExpiresUtc > SYSUTCDATETIME() THEN N'ziv' ELSE N'potekel' END FROM ops.SchedulerLease WHERE LeaseKey = N'PIM';"
  $vrstica = @($vrstica | Where-Object { $_ -is [string] -and $_.Trim() -ne '' } | Select-Object -First 1)
  if ($vrstica.Count -eq 0) {
    Korak 'RAZPOREJEVALNIK' 'Kdo drzi najem in ali je ziv' 'OPOZ' "Najema ni: noben intranet se ni nikoli zagnal na tej bazi."
  } else {
    $deli = $vrstica[0] -split '\|'
    $lastnikNajema = $deli[0]
    if ($deli[3] -eq 'ziv') {
      Korak 'RAZPOREJEVALNIK' 'Kdo drzi najem in ali je ziv' 'OK' "$($deli[0]) ($($deli[1])), poteka $($deli[2]) UTC"
    } else {
      Korak 'RAZPOREJEVALNIK' 'Kdo drzi najem in ali je ziv' 'OPOZ' "Zadnji lastnik $($deli[0]) ($($deli[1])), najem je POTEKEL $($deli[2]) UTC - noben proces ne poganja ciklov samodejno."
    }
  }
}
catch { Korak 'RAZPOREJEVALNIK' 'Kdo drzi najem in ali je ziv' 'PADEL' $_.Exception.Message }

# --- 4. CIKEL_MAGENTO -----------------------------------------------------------
$cikelTece = $false
try {
  $vrstica = PimUkaz $povezava @"
SET NOCOUNT ON;
SELECT CONVERT(varchar(1), IsEnabled) + N'|' + CONVERT(varchar(10), IntervalSeconds) + N'|'
  + CONVERT(varchar(1), CASE WHEN RunningRunId IS NULL THEN 0 ELSE 1 END) + N'|'
  + ISNULL(CONVERT(varchar(30), NextDueUtc, 126), N'-') + N'|'
  + ISNULL((SELECT CONVERT(varchar(30), MAX(EndedUtc), 126) FROM ops.WorkerCycleRun WHERE CycleKey = 'magento-csv' AND Status = N'Succeeded'), N'nikoli')
FROM ops.WorkerCycle WHERE CycleKey = N'magento-csv';
"@
  $vrstica = @($vrstica | Where-Object { $_ -is [string] -and $_.Trim() -ne '' } | Select-Object -First 1)
  if ($vrstica.Count -eq 0) {
    Korak 'CIKEL_MAGENTO' 'Cikel magento-csv obstaja in tece po urniku' 'PADEL' "Vrstice ni v ops.WorkerCycle - migracija 221/242 ni uveljavljena ali cikel ni bil nikoli usklajen (EnsureCyclesAsync tece ob zagonu intraneta)."
  } else {
    $deli = $vrstica[0] -split '\|'
    $vklopljen = $deli[0] -eq '1'; $razmik = $deli[1]; $cikelTece = $deli[2] -eq '1'; $naslednji = $deli[3]; $zadnjiUspeh = $deli[4]
    if (-not $vklopljen) {
      Korak 'CIKEL_MAGENTO' 'Cikel magento-csv obstaja in tece po urniku' 'PADEL' "Cikel je IZKLOPLJEN na /sistem/workerji - dokler ni vklopljen, se ne bo nikoli pognal sam."
    } elseif ($cikelTece) {
      Korak 'CIKEL_MAGENTO' 'Cikel magento-csv obstaja in tece po urniku' 'OPOZ' "Trenutno TECE (zagnan zdaj); razmik $razmik s; zadnji uspeh: $zadnjiUspeh UTC. Pocakaj in ponovi ta korak."
    } else {
      Korak 'CIKEL_MAGENTO' 'Cikel magento-csv obstaja in tece po urniku' 'OK' "vklopljen, razmik $razmik s, naslednji $naslednji UTC, zadnji uspeh: $zadnjiUspeh UTC"
    }
  }
}
catch { Korak 'CIKEL_MAGENTO' 'Cikel magento-csv obstaja in tece po urniku' 'PADEL' $_.Exception.Message }

# --- 5. IZHODNA_MAPA -------------------------------------------------------------
$mapaPot = $null
try {
  $mapaVrstica = PimUkaz $povezava "SET NOCOUNT ON; EXEC ops.ResolveSystemPath @PathKey = N'EXPORT_ROOT', @OrganizationId = NULL;"
  $mapaPot = @($mapaVrstica | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[A-Za-z]:\\' -or $_ -like '\\\\*' } | Select-Object -First 1)
  $preveriSkripta = Join-Path $mestoSkripte 'Nastavi-pravice-izvozne-mape.ps1'
  $izpisPreverbe = & powershell -NoProfile -ExecutionPolicy Bypass -File $preveriSkripta -SamoPreveri 2>&1
  $kodaPreverbe = $LASTEXITCODE
  $besediloPreverbe = ($izpisPreverbe | Out-String).Trim()
  if ($kodaPreverbe -eq 0) {
    Korak 'IZHODNA_MAPA' "EXPORT_ROOT ($mapaPot) je zapisljiv za ta racun" 'OK' "$env:USERDOMAIN\$env:USERNAME lahko pise"
  } else {
    $zadnjeVrsticePreverbe = ($besediloPreverbe -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 2) -join ' | '
    $sporocilo = "$zadnjeVrsticePreverbe  --> popravek (kot administrator): powershell -ExecutionPolicy Bypass -File scripts\Nastavi-pravice-izvozne-mape.ps1 -BazenIis <ime bazena IIS>"
    Korak 'IZHODNA_MAPA' "EXPORT_ROOT ($mapaPot) je zapisljiv za ta racun" 'PADEL' $sporocilo
  }
}
catch { Korak 'IZHODNA_MAPA' 'EXPORT_ROOT je zapisljiv za ta racun' 'PADEL' $_.Exception.Message }

# --- 6. ZADNJI_PRAVI_IZVOZ --------------------------------------------------------
try {
  $vrstica = PimUkaz $povezava "SET NOCOUNT ON; SELECT TOP 1 Status + N'|' + CONVERT(varchar(30), StartedUtc, 126) + N'|' + ISNULL(CONVERT(varchar(20), RowCountValue), N'-') + N'|' + ISNULL(LEFT(ErrorRedacted, 200), N'-') FROM out.ExportRun WHERE ProfileCode = N'MAGENTO_PRODUCTS' ORDER BY ExportRunId DESC;"
  $vrstica = @($vrstica | Where-Object { $_ -is [string] -and $_.Trim() -ne '' } | Select-Object -First 1)
  if ($vrstica.Count -eq 0) {
    Korak 'ZADNJI_PRAVI_IZVOZ' 'Zadnji zabelezen poskus katalog.csv' 'OPOZ' "V out.ExportRun se ni nobenega zapisa za MAGENTO_PRODUCTS - noben zagon se ni se poskusil."
  } else {
    $deli = $vrstica[0] -split '\|', 4
    $starostUre = [math]::Round(((Get-Date).ToUniversalTime() - [datetime]$deli[1]).TotalHours, 1)
    if ($deli[0] -eq 'Succeeded') {
      $status = if ($starostUre -le 24) { 'OK' } else { 'OPOZ' }
      Korak 'ZADNJI_PRAVI_IZVOZ' 'Zadnji zabelezen poskus katalog.csv' $status "Succeeded, $($deli[1]) UTC (star $starostUre h), $($deli[2]) vrstic"
    } else {
      Korak 'ZADNJI_PRAVI_IZVOZ' 'Zadnji zabelezen poskus katalog.csv' 'PADEL' "$($deli[0]), $($deli[1]) UTC (star $starostUre h): $($deli[3])"
    }
  }
}
catch { Korak 'ZADNJI_PRAVI_IZVOZ' 'Zadnji zabelezen poskus katalog.csv' 'PADEL' $_.Exception.Message }

# --- 7. DOKAZ_CEVOVODA --------------------------------------------------------------
# Neodvisno od EXPORT_ROOT in od zivega razporejevalnika: dokaze, da PIM.B2bWorker s trenutno
# kodo in trenutnimi podatki dejansko izdela pravilen par v poljubno mapo. Ne uporablja
# --osvezi-validacijo (hitro; validacija je locen korak in jo ze preverja cikel/samotest).
try {
  $scratch = Join-Path $env:TEMP ("pim-e2e-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
  New-Item -ItemType Directory -Path $scratch -Force | Out-Null
  $projekt = Join-Path $resitev 'workers\PIM.B2bWorker'
  $exe = Join-Path $projekt 'bin\Debug\net10.0\PIM.B2bWorker.exe'
  if (-not (Test-Path $exe)) {
    Write-Host "           (gradim PIM.B2bWorker, ker se ni zgrajen ...)" -ForegroundColor DarkGray
    & dotnet build $projekt --nologo -v q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Gradnja PIM.B2bWorker ni uspela (izhodna koda $LASTEXITCODE)." }
  }
  $env:PIM_TRIGGERED_BY = 'Human'
  $env:PIM_ACTOR = 'e2e-preverba'
  $ura = [Diagnostics.Stopwatch]::StartNew()
  # PowerShell 5.1 zavije stderr .NET procesa v ErrorRecord; pod ErrorActionPreference=Stop (glej
  # zacetek skripte) bi ze prva vrstica na stderr (npr. Console.Error.WriteLine v Program.cs)
  # prekinila celo skripto, se preden pridemo do preverbe izhodne kode (isti vzorec kot v
  # run_tests.ps1/Workerji.ps1). Zato tu zacasno na Continue.
  $prejsnjaObravnava = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $izhodDela = & $exe --export-magento --organization-id $Podjetje --output-dir $scratch 2>&1 }
  finally { $ErrorActionPreference = $prejsnjaObravnava }
  $kodaDela = $LASTEXITCODE
  $ura.Stop()

  if ($kodaDela -ne 0) {
    throw "Izhodna koda $kodaDela. Izpis: $(($izhodDela | Select-Object -Last 5) -join ' | ')"
  }

  $katalog = Join-Path $scratch 'katalog.csv'
  $stranke = Join-Path $scratch 'stranke.csv'
  $marker = Join-Path $scratch 'magento-export.complete'
  foreach ($pricakovana in @($katalog, $stranke, $marker)) {
    if (-not (Test-Path $pricakovana)) { throw "Manjka pricakovana datoteka: $pricakovana" }
  }

  $glavaKataloga = (Get-Content $katalog -TotalCount 1 -Encoding UTF8)
  $steviloStolpcevKataloga = ($glavaKataloga -split ',').Count
  $steviloVrsticKataloga = (Get-Content $katalog | Measure-Object -Line).Lines - 1
  $glavaStrank = (Get-Content $stranke -TotalCount 1 -Encoding UTF8)
  $steviloStolpcevStrank = ($glavaStrank -split ',').Count

  $registrskiStolpci = PimUkaz $povezava @"
SET NOCOUNT ON;
SELECT ProfileCode + N'=' + CONVERT(varchar(10), COUNT(*))
FROM out.ExportColumn c JOIN out.ExportProfile p ON p.ExportProfileId = c.ExportProfileId
WHERE p.ProfileCode IN (N'MAGENTO_PRODUCTS', N'MAGENTO_CUSTOMERS') AND c.IsActive = 1 AND p.IsActive = 1
GROUP BY p.ProfileCode;
"@
  $pricakovaniKatalog = 0; $pricakovaneStranke = 0
  foreach ($vrsta in $registrskiStolpci) {
    if ("$vrsta" -match 'MAGENTO_PRODUCTS=(\d+)') { $pricakovaniKatalog = [int]$Matches[1] }
    if ("$vrsta" -match 'MAGENTO_CUSTOMERS=(\d+)') { $pricakovaneStranke = [int]$Matches[1] }
  }

  $bajtiKataloga = [IO.File]::ReadAllBytes($katalog)
  $imaBom = $bajtiKataloga.Length -ge 3 -and $bajtiKataloga[0] -eq 0xEF -and $bajtiKataloga[1] -eq 0xBB -and $bajtiKataloga[2] -eq 0xBF
  $besediloKataloga = [IO.File]::ReadAllText($katalog)
  $imaCrLf = $besediloKataloga.Contains("`r`n")

  $napake = New-Object System.Collections.Generic.List[string]
  if ($steviloStolpcevKataloga -ne $pricakovaniKatalog) { $napake.Add("katalog.csv ima $steviloStolpcevKataloga stolpcev, register jih ima $pricakovaniKatalog aktivnih") }
  if ($steviloStolpcevStrank -ne $pricakovaneStranke) { $napake.Add("stranke.csv ima $steviloStolpcevStrank stolpcev, register jih ima $pricakovaneStranke aktivnih") }
  if ($imaBom) { $napake.Add("katalog.csv ima BOM (pogodba zahteva brez BOM)") }
  if ($imaCrLf) { $napake.Add("katalog.csv ima CRLF (pogodba zahteva LF)") }

  Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue

  if ($napake.Count -eq 0) {
    Korak 'DOKAZ_CEVOVODA' 'Svez zagon v izolirano mapo izdela pravilen par' 'OK' "$steviloVrsticKataloga vrstic x $steviloStolpcevKataloga stolpcev (katalog), $steviloStolpcevStrank stolpcev (stranke), $([int]$ura.Elapsed.TotalSeconds) s, brez BOM, LF"
  } else {
    Korak 'DOKAZ_CEVOVODA' 'Svez zagon v izolirano mapo izdela pravilen par' 'PADEL' ($napake -join '; ')
  }
}
catch {
  if (Test-Path $scratch) { Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue }
  Korak 'DOKAZ_CEVOVODA' 'Svez zagon v izolirano mapo izdela pravilen par' 'PADEL' $_.Exception.Message
}

# --- (izbirno) resnicen zagon v EXPORT_ROOT ------------------------------------------------
if ($PrisiliResnicniIzvoz) {
  if ($cikelTece -or ($lastnikNajema -and -not $PrisiliResnicniIzvoz)) {
    Korak 'RESNICNI_IZVOZ' 'Zagon neposredno v EXPORT_ROOT' 'PRESKOCI' 'Razporejevalnik ali cikel je ravno aktiven; socasen zagon bi se le prerekal za kljucavnico.'
  } else {
    try {
      $projekt = Join-Path $resitev 'workers\PIM.B2bWorker'
      $exe = Join-Path $projekt 'bin\Debug\net10.0\PIM.B2bWorker.exe'
      $ura = [Diagnostics.Stopwatch]::StartNew()
      $prejsnjaObravnava = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      try { $izhodDela = & $exe --export-magento --organization-id $Podjetje 2>&1 }
      finally { $ErrorActionPreference = $prejsnjaObravnava }
      $kodaDela = $LASTEXITCODE
      $ura.Stop()
      if ($kodaDela -eq 0) {
        Korak 'RESNICNI_IZVOZ' 'Zagon neposredno v EXPORT_ROOT' 'OK' "$([int]$ura.Elapsed.TotalSeconds) s - preveri /splet za potrditev."
      } else {
        Korak 'RESNICNI_IZVOZ' 'Zagon neposredno v EXPORT_ROOT' 'PADEL' (($izhodDela | Select-Object -Last 5) -join ' | ')
      }
    }
    catch { Korak 'RESNICNI_IZVOZ' 'Zagon neposredno v EXPORT_ROOT' 'PADEL' $_.Exception.Message }
  }
}

# --- 8. ZIVA_APLIKACIJA ----------------------------------------------------------
try {
  $najdenPort = $null
  foreach ($port in 5091, 5093, 5095, 5199) {
    try {
      $odziv = Invoke-WebRequest -Uri "http://localhost:$port/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
      if ($odziv.StatusCode -eq 200) { $najdenPort = $port; break }
    }
    catch { }
  }
  if ($najdenPort) {
    Korak 'ZIVA_APLIKACIJA' 'Lokalni intranet se odziva na /health' 'OK' "http://localhost:$najdenPort"
  } else {
    Korak 'ZIVA_APLIKACIJA' 'Lokalni intranet se odziva na /health' 'PRESKOCI' 'Na znanih razvojnih portih (5091/5093/5095/5199) se noben intranet ne odziva - ni nujno napaka.'
  }
}
catch { Korak 'ZIVA_APLIKACIJA' 'Lokalni intranet se odziva na /health' 'PRESKOCI' $_.Exception.Message }

# --- Povzetek -----------------------------------------------------------------
Write-Host ('-' * 78)
$padli = @($koraki | Where-Object { $_.Status -eq 'PADEL' })
$opozorila = @($koraki | Where-Object { $_.Status -eq 'OPOZ' })
if ($padli.Count -eq 0) {
  Write-Host ("REZULTAT: {0} - {1} korakov, {2} opozoril" -f $(if ($opozorila.Count -eq 0) { 'USPEL' } else { 'USPEL Z OPOZORILI' }), $koraki.Count, $opozorila.Count) -ForegroundColor $(if ($opozorila.Count -eq 0) { 'Green' } else { 'Yellow' })
} else {
  Write-Host ("REZULTAT: PADEL - {0} od {1} korakov" -f $padli.Count, $koraki.Count) -ForegroundColor Red
  Write-Host "Padli koraki:"
  foreach ($k in $padli) { Write-Host ("  - {0}: {1}" -f $k.Koda, $k.Podrobnost) -ForegroundColor Red }
}

exit ($(if ($padli.Count -eq 0) { 0 } else { 1 }))
