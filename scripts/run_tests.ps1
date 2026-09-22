<#
.SYNOPSIS
  Edini merodajni testni zagon za NoviPIM. Izhod 0 = vse OK, 1 = napaka.

.DESCRIPTION
  Zakaj obstaja: `dotnet test PIM_Solution\PIM.sln` zazene samo projekte s
  test-sdk. V tej resitvi je tak en sam (PIM.ChangeTracking.Integration);
  preostalih 42 testnih projektov so konzolne aplikacije (OutputType Exe), ki
  jih `dotnet test` samo prevede, nikoli pa ne pozene. Zato je `dotnet test`
  vracal 0, tudi ce ni izvedel prakticno nicesar.

  Ta skripta pozene vse: najprej build, nato vsak konzolni testni projekt prek
  `dotnet run`, na koncu se `dotnet test` za xUnit projekte.

.PARAMETER Filter
  Zazene samo projekte, katerih ime ustreza vzorcu, npr. -Filter "F5".

.PARAMETER Verbose_
  Ob napaki izpise cel izhod projekta, ne samo zadnjih vrstic.

.EXAMPLE
  scripts\run_tests.ps1
  scripts\run_tests.ps1 -Filter F3
#>
[CmdletBinding()]
param(
  [string]$Filter = "",
  [switch]$Verbose_
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$sln = Join-Path $repo "PIM_Solution\PIM.sln"
$testsDir = Join-Path $repo "PIM_Solution\tests"

function Zapisi($barva, $besedilo) { Write-Host $besedilo -ForegroundColor $barva }

# --- 0. Ali je povezava do razvojne baze na voljo? -------------------------
$imaPovezavo = $false
if ($env:PIM_CONNECTION_STRING) { $imaPovezavo = $true }
else {
  # Testi tecejo iz svoje mape (rabijo relativne poti do workers\), zato ne
  # najdejo appsettings.Local.json v korenu. Povezavo zato podamo prek okoljske
  # spremenljivke, ki od delovne mape ni odvisna. Vrednosti nikoli ne izpisemo.
  $local = Join-Path $repo "appsettings.Local.json"
  if (Test-Path $local) {
    try {
      $j = Get-Content $local -Raw | ConvertFrom-Json
      if ($j.ConnectionStrings.Pim) {
        $env:PIM_CONNECTION_STRING = $j.ConnectionStrings.Pim
        $imaPovezavo = $true
        Zapisi Cyan "Povezava do razvojne baze prevzeta iz appsettings.Local.json."
      }
    } catch { }
  }
}

if (-not $imaPovezavo) {
  Zapisi Yellow "OPOZORILO: PIM_CONNECTION_STRING ni nastavljen in appsettings.Local.json nima ConnectionStrings:Pim."
  Zapisi Yellow "           Integracijski testi se bodo PRESKOCILI. Izhod 0 v tem primeru NE dokazuje, da sistem dela."
  Zapisi Yellow ""
}

# --- 1. Build --------------------------------------------------------------
Zapisi Cyan "=== Build ==="
$intranet = Get-Process PIM.Intranet -ErrorAction SilentlyContinue
if ($intranet) {
  Zapisi Yellow "Intranet tece (PID $($intranet.Id)) in drzi PIM.Intranet.exe zaklenjen - ustavljam."
  $intranet | Stop-Process -Force -Confirm:$false
  Start-Sleep -Seconds 2
}

& dotnet build $sln --nologo -m:1 | Out-Null
if ($LASTEXITCODE -ne 0) {
  Zapisi Red "BUILD NEUSPESEN. Pozeni 'dotnet build PIM_Solution\PIM.sln' za podrobnosti."
  exit 1
}
Zapisi Green "Build OK"
Zapisi Cyan ""

# --- 2. Konzolni testni projekti ------------------------------------------
$projekti = Get-ChildItem $testsDir -Directory | Sort-Object Name

# Nocni samotest ni test kode, ampak test namescenega sistema: pade, kadar delavec molci ali
# je SAOP nedosegljiv. To sta operativni stanji in ne napaki v kodi, zato ne smeta pobarvati
# regresijskega zagona rdece. Zaganja ga scripts\Nocni-samotest.ps1 oziroma nacrtovano opravilo.
$izkljuceni = @('PIM.SelfTest.Nightly')
$projekti = $projekti | Where-Object { $izkljuceni -notcontains $_.Name }

if ($Filter) { $projekti = $projekti | Where-Object { $_.Name -like "*$Filter*" } }

$padli = @()
$preskoceni = @()
$uspeli = @()

Zapisi Cyan "=== Testni projekti ($($projekti.Count)) ==="
foreach ($p in $projekti) {
  $csproj = Join-Path $p.FullName "$($p.Name).csproj"
  if (-not (Test-Path $csproj)) { continue }

  # xUnit projekte pozene 'dotnet test' spodaj, ne tukaj
  if (Select-String -Path $csproj -Pattern "Microsoft.NET.Test.Sdk" -Quiet) { continue }

  # Testi racunajo relativne poti od trenutne mape, zato jih je treba pognati
  # iz njihove lastne mape - drugace iscejo npr. ..\..\workers\ na napacnem mestu.
  # PowerShell 5.1 zavije stderr native ukaza v ErrorRecord in ob
  # ErrorActionPreference=Stop prekine celo skripto. Zato stderr peljemo v
  # datoteko in preference zacasno spustimo na Continue.
  Push-Location $p.FullName
  $tmpOut = [System.IO.Path]::GetTempFileName()
  $tmpErr = [System.IO.Path]::GetTempFileName()
  try {
    $prej = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $proc = Start-Process -FilePath "dotnet" `
      -ArgumentList @("run", "--project", $csproj, "--no-build") `
      -NoNewWindow -Wait -PassThru `
      -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
    $koda = $proc.ExitCode
    $ErrorActionPreference = $prej
    $izhod = (Get-Content $tmpOut -Raw -ErrorAction SilentlyContinue) + "`n" +
             (Get-Content $tmpErr -Raw -ErrorAction SilentlyContinue)
  } finally {
    Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    Pop-Location
  }

  if ($koda -ne 0) {
    $padli += $p.Name
    Zapisi Red ("  FAIL  {0}  (izhod {1})" -f $p.Name, $koda)
    $vrstice = if ($Verbose_) { $izhod } else { ($izhod -split "`n" | Select-Object -Last 6) -join "`n" }
    Write-Host $vrstice
  }
  elseif ($izhod -match "presko") {
    $preskoceni += $p.Name
    Zapisi Yellow ("  PRESK {0}" -f $p.Name)
  }
  else {
    $uspeli += $p.Name
    Zapisi Green ("  OK    {0}" -f $p.Name)
  }
}

# --- 3. xUnit projekti -----------------------------------------------------
Zapisi Cyan ""
Zapisi Cyan "=== xUnit (dotnet test) ==="
$xpreskok = 0
$xizhod = & dotnet test $sln --no-build --nologo 2>&1 | Out-String
$xkoda = $LASTEXITCODE
if ($xkoda -ne 0) {
  $padli += "dotnet test (xUnit)"
  Zapisi Red "  FAIL  dotnet test"
  Write-Host (($xizhod -split "`n" | Select-Object -Last 15) -join "`n")
} else {
  $xpreskok = ([regex]::Matches($xizhod, "Skipped:\s+(\d+)") | ForEach-Object { [int]$_.Groups[1].Value } | Measure-Object -Sum).Sum
  if ($xpreskok -gt 0) { Zapisi Yellow "  OK    dotnet test ($xpreskok preskocenih)" }
  else { Zapisi Green "  OK    dotnet test" }
}

# --- 4. Povzetek -----------------------------------------------------------
Zapisi Cyan ""
Zapisi Cyan "=== Povzetek ==="
Write-Host ("  uspeli:     {0}" -f $uspeli.Count)
Write-Host ("  preskoceni: {0}" -f $preskoceni.Count)
Write-Host ("  padli:      {0}" -f $padli.Count)

if ($preskoceni.Count -gt 0) {
  Zapisi Yellow ""
  Zapisi Yellow "Preskoceni projekti (niso dokaz, da kaj dela):"
  $preskoceni | ForEach-Object { Write-Host "  - $_" }
}

if ($padli.Count -gt 0) {
  Zapisi Red ""
  Zapisi Red "PADLI:"
  $padli | ForEach-Object { Write-Host "  - $_" }
  Zapisi Red ""
  Zapisi Red "REZULTAT: NEUSPESNO"
  exit 1
}

if (-not $imaPovezavo) {
  Zapisi Yellow ""
  Zapisi Yellow "REZULTAT: nic ni padlo, VENDAR brez povezave do baze. To ni polni dokaz."
  Zapisi Yellow "Za polni dokaz nastavi PIM_CONNECTION_STRING ali ConnectionStrings:Pim in ponovi."
  exit 0
}

if ($preskoceni.Count -gt 0 -or $xpreskok -gt 0) {
  Zapisi Yellow ""
  Zapisi Yellow "REZULTAT: nic ni padlo, VENDAR so se testi preskocili, CEPRAV je povezava nastavljena."
  Zapisi Yellow "To pomeni, da testi ne najdejo konfiguracije iz svoje delovne mape."
  Zapisi Yellow "Testi berejo appsettings.Local.json relativno na trenutno mapo, poti do"
  Zapisi Yellow "workers\ pa relativno na svojo lokacijo - ti dve izhodisci si nasprotujeta."
  Zapisi Yellow "Dokler to ni popravljeno, izhod 0 NI polni dokaz."
  exit 0
}

Zapisi Green ""
Zapisi Green "REZULTAT: VSE OK"
exit 0
