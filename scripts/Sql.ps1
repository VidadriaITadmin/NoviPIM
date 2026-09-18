<#
.SYNOPSIS
  Skupna pot do PIM_CONNECTION_STRING in do izvajanja SQL prek sqlcmd.

.DESCRIPTION
  Ista logika (branje povezave, razstavljanje povezovalnega niza, klic sqlcmd) je ze v
  Nocno-vse.ps1 kot lokalna funkcija Poizvedba. Ko jo je poleg nje potreboval se
  Zaloga-cikel.ps1 (val.RunValidation / val.Promote pred hitrim izvozom cen) in
  Katalog-cikel.ps1 (isto pred urnim izvozom kataloga), bi tretja kopija pomenila, da
  popravek v eni razide od drugih dveh — zato je tu, na enem mestu.

  Ni namenjena zagonu; skripta jo vkljuci z zapisom:  . (Join-Path $PSScriptRoot 'Sql.ps1')

  sqlcmd namesto ADO.NET iz istega razloga kot v Nocno-vse.ps1: Microsoft.Data.SqlClient je
  paket NuGet in ne del PowerShella, ob rocnem nalaganju iz izhoda gradnje pa potrebuje se
  domorodni Microsoft.Data.SqlClient.SNI.dll, ki ga Add-Type ne najde. sqlcmd je standardno
  orodje SQL Serverja, je na tem racunalniku in nima teh tezav.
#>

# Prebere PIM_CONNECTION_STRING; ce ni nastavljena, jo vzame iz appsettings.Local.json (razvojni
# racunalnik) ali appsettings.json (streznik - tam .Local.json obicajno ni objavljen) v korenu.
function PimPovezava([string]$KorenRepozitorija) {
  $povezava = $env:PIM_CONNECTION_STRING
  if (-not [string]::IsNullOrWhiteSpace($povezava)) { return $povezava }

  foreach ($ime in 'appsettings.Local.json', 'appsettings.json') {
    $datoteka = Join-Path $KorenRepozitorija $ime
    if (-not (Test-Path $datoteka)) { continue }
    $niz = (Get-Content $datoteka -Raw | ConvertFrom-Json).ConnectionStrings.Pim
    if (-not [string]::IsNullOrWhiteSpace($niz)) { return $niz }
  }
  throw "Ni PIM_CONNECTION_STRING in v '$KorenRepozitorija' ni najti ne appsettings.Local.json ne appsettings.json s ConnectionStrings.Pim."
}

# Pozene en SQL ukaz (npr. EXEC) prek sqlcmd in vrne njegov izpis. Ukaz gre v datoteko in v
# sqlcmd z -i, ne z -Q: vecvrsticni -Q se pri prehodu iz PowerShella v domoroden proces razbije
# in sqlcmd potem javi "' ': Unknown Option" — datoteka te poti nima (enak vzorec kot v
# Nocno-vse.ps1).
function PimUkaz([string]$Povezava, [string]$Sql) {
  $sqlcmdUkaz = Get-Command sqlcmd -ErrorAction SilentlyContinue
  if (-not $sqlcmdUkaz) { throw 'sqlcmd ni na voljo. Namesti "SQL Server Command Line Utilities" ali dodaj sqlcmd v PATH.' }

  function VrednostIzPovezave([string]$Imena) {
    foreach ($del in $Povezava -split ';') {
      $par = $del -split '=', 2
      if ($par.Count -eq 2 -and ($Imena -split '\|') -contains $par[0].Trim()) { return $par[1].Trim() }
    }
    return ''
  }
  $streznik = VrednostIzPovezave 'Server|Data Source|Address|Addr'
  $baza = VrednostIzPovezave 'Database|Initial Catalog'
  $uporabnik = VrednostIzPovezave 'User ID|UID|User'
  $geslo = VrednostIzPovezave 'Password|PWD'
  if ([string]::IsNullOrWhiteSpace($streznik) -or [string]::IsNullOrWhiteSpace($baza)) {
    throw 'Iz povezovalnega niza ni mogoce prebrati streznika in baze.'
  }

  $zacasna = [System.IO.Path]::GetTempFileName()
  try {
    Set-Content -Path $zacasna -Value $Sql -Encoding UTF8
    # -b izhodna koda ob napaki SQL, -h -1 brez glave, -W brez odvecnih presledkov,
    # -I dvojni narekovaj kot oznaka imena, -t meja v sekundah (validacija+promote lahko traja).
    $argumenti = @('-S', $streznik, '-d', $baza, '-C', '-I', '-b', '-h', '-1', '-W', '-t', '1800', '-i', $zacasna)
    $argumenti = if ([string]::IsNullOrWhiteSpace($uporabnik)) { @('-E') + $argumenti }
                 else { @('-U', $uporabnik, '-P', $geslo) + $argumenti }

    # Deadlock (Msg 1205) je v SQL Serverju pricakovan dogodek, ne okvara: streznik namenoma
    # izbere eno stran za zrtev, da druga lahko stece dalje. Najdeno 2026-09-15: val.RunValidation
    # je zaradi souporabe baze z drugimi teki vsakic padel na prvi deadlock in cel korak je bil
    # prestet kot padel, ceprav bi drugi poskus skoraj zagotovo uspel. Do 3 poskusi z narascajocim
    # in nakljucnim pocitkom (da se dve zaporedni zrtvi ne zaletita spet skupaj), preden obupamo.
    $najvecPoskusov = 3
    for ($poskus = 1; $poskus -le $najvecPoskusov; $poskus++) {
      $izhod = & $sqlcmdUkaz.Source @argumenti 2>&1
      if ($LASTEXITCODE -eq 0) { return $izhod }

      $besedilo = $izhod -join ' '
      $jeDeadlock = $besedilo -match 'Msg 1205'
      if (-not $jeDeadlock -or $poskus -eq $najvecPoskusov) {
        throw "sqlcmd je vrnil $LASTEXITCODE`: $besedilo"
      }
      Start-Sleep -Milliseconds (500 * $poskus + (Get-Random -Maximum 500))
    }
  }
  finally { Remove-Item $zacasna -Force -ErrorAction SilentlyContinue }
}

# Kam prevzemnik odlozi dobaviteljeve datoteke — ista pot in isti vrstni red kot v
# PIM.SourceFetchWorker (Program.cs): okolje PIM_FETCH_ROOT, register ops.SystemPath LANDING_ROOT,
# sicer <PIM_Solution>\data\prevzem. Skripta jo prevzemniku poda z --target in iz nje bere naprej,
# zato se obe strani ne moreta raziti. Do 2026-09-16 je skripta brala iz <PIM_Solution>\data\prevzem
# ne glede na register; na strezniku brez PIM_Solution bi prevzemnik pisal ob svoj .exe, skripta
# pa "preskoceno: mape ni" — zaloga dobaviteljev bi tiho ostala neprebrana.
function PimPotPrevzema([string]$Povezava, [string]$Resitev) {
  if (-not [string]::IsNullOrWhiteSpace($env:PIM_FETCH_ROOT)) { return $env:PIM_FETCH_ROOT }

  $izhod = PimUkaz $Povezava "EXEC ops.ResolveSystemPath @PathKey = N'LANDING_ROOT';"
  $vrstica = @($izhod | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
  if ($vrstica.Count -gt 0) { return $vrstica[0].Trim() }

  return Join-Path $Resitev 'data\prevzem'
}

# Razporejevalnik v aplikaciji (migracija 221): lastnik zivega najema v ops.SchedulerLease ali prazen
# niz. Cikli se ob njem umaknejo, da isti cikel ne tece dvakrat (glej Zaloga-cikel.ps1 -Vseeno). Napaka
# pri branju (stara baza brez tabele, nedosegljiv streznik) pomeni "ni razporejevalnika": skripta tece naprej.
function PimRazporejevalnikVAplikaciji([string]$Povezava) {
  try {
    $izhod = PimUkaz $Povezava "SET NOCOUNT ON; IF OBJECT_ID(N'ops.SchedulerLease', N'U') IS NOT NULL SELECT Owner + N' / ' + Application FROM ops.SchedulerLease WHERE LeaseKey = N'PIM' AND ExpiresUtc > SYSUTCDATETIME();"
    $vrstica = @($izhod | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    if ($vrstica.Count -gt 0) { return $vrstica[0].Trim() }
  }
  catch { }
  return ''
}
