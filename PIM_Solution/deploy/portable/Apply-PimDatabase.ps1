[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateScript({ Test-Path $_ -PathType Leaf })][string]$ConfigFile,
  [switch]$VerifyOnly
)

# Ta skripta je del prenosljivega release paketa v mapi database.
# ConfigFile je lokalna datoteka cilja; nikoli ne podajaj povezave kot argument ukaza.
$ErrorActionPreference = 'Stop'
$configPath = (Resolve-Path $ConfigFile).Path
$config = Get-Content -Raw $configPath | ConvertFrom-Json
$connectionString = [string]$config.ConnectionStrings.Pim
if ([string]::IsNullOrWhiteSpace($connectionString)) {
  throw "V $configPath manjka ConnectionStrings:Pim."
}

$migrator = Join-Path $PSScriptRoot 'PIM.Migrator.exe'
$migrations = Join-Path $PSScriptRoot 'migrations'
if (-not (Test-Path $migrator -PathType Leaf)) { throw "Migrator ne obstaja: $migrator" }
if (-not (Test-Path $migrations -PathType Container)) { throw "Mapa migracij ne obstaja: $migrations" }

$env:PIM_CONNECTION_STRING = $connectionString
try {
  # Tudi centralni release postopek zacne s primerjavo vseh datotek in evidence v bazi.
  & $migrator --status --migrations $migrations
  if ($LASTEXITCODE -ne 0) { throw 'Paket migracij ni skladen z evidenco baze. Nic ni bilo namesceno.' }

  if ($VerifyOnly) {
    & $migrator --verify --migrations $migrations
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Host 'ALLOWED: baza je preverjena.'
    return
  }

  & $migrator --create-database --migrations $migrations
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & $migrator --status --migrations $migrations
  if ($LASTEXITCODE -ne 0) { throw 'Stanje migracij po namestitvi ni skladno.' }
  & $migrator --verify --migrations $migrations
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Write-Host 'ALLOWED: vse migracije so namescene in baza je preverjena.'
}
finally {
  Remove-Item Env:PIM_CONNECTION_STRING -ErrorAction SilentlyContinue
}
