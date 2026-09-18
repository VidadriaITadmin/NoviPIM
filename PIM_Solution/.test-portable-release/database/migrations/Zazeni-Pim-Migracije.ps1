[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateScript({ Test-Path $_ -PathType Leaf })][string]$ConfigFile,
  [ValidateScript({ Test-Path $_ -PathType Leaf })][string]$MigratorPath,
  [switch]$StatusOnly
)

# Skripto kopiraj V MAPO z .sql migracijami. Ne uporablja sqlcmd: PIM.Migrator vodi dbo.SchemaMigration,
# preveri hash vsake ze uporabljene datoteke in v eni transakciji uporabi samo manjkajoce migracije.
$ErrorActionPreference = 'Stop'
$migrationPath = $PSScriptRoot

if (-not $MigratorPath) {
  $candidates = @(
    (Join-Path $migrationPath 'PIM.Migrator.exe'),
    (Join-Path (Split-Path $migrationPath -Parent) 'PIM.Migrator.exe'),
    (Join-Path (Split-Path $migrationPath -Parent) 'database\PIM.Migrator.exe')
  )
  $MigratorPath = $candidates | Where-Object { Test-Path $_ -PathType Leaf } | Select-Object -First 1
}
if (-not $MigratorPath) {
  throw 'PIM.Migrator.exe ni najden. Dodaj -MigratorPath D:\pot\do\PIM.Migrator.exe.'
}

$config = Get-Content -Raw (Resolve-Path $ConfigFile).Path | ConvertFrom-Json
$connectionString = [string]$config.ConnectionStrings.Pim
if ([string]::IsNullOrWhiteSpace($connectionString)) {
  throw 'V ConfigFile manjka ConnectionStrings:Pim.'
}

$env:PIM_CONNECTION_STRING = $connectionString
try {
  # 1. Celotna preglednica: Applied / Pending / CHANGED - STOP / MISSING FILE - STOP.
  # "ALLOWED" pomeni samo, da je paket varen za namestitev; Pending je normalen.
  Write-Host '[1/4] Pregledujem migracije in evidenco dbo.SchemaMigration ...'
  & $MigratorPath --status --migrations $migrationPath
  if ($LASTEXITCODE -ne 0) { throw 'Pregled je nasel spremenjeno ali manjkajoco ze uporabljeno migracijo. Nic ni bilo namesceno.' }
  if ($StatusOnly) { return }

  # 2. Migrator uporabi samo Pending datoteke. Ze uporabljene preskoci po hash-u.
  Write-Host '[2/4] Namescam samo Pending migracije ...'
  & $MigratorPath --create-database --migrations $migrationPath
  if ($LASTEXITCODE -ne 0) { throw 'Namestitev migracij ni uspela.' }

  # 3. Po namestitvi ne sme ostati nobena Pending migracija.
  Write-Host '[3/4] Ponovno preverjam evidenco migracij ...'
  & $MigratorPath --status --migrations $migrationPath
  if ($LASTEXITCODE -ne 0) { throw 'Stanje migracij po namestitvi ni skladno.' }

  # 4. Koncna preverba objektov in pravil PIM-a.
  Write-Host '[4/4] Preverjam bazo in pogodbe PIM-a ...'
  & $MigratorPath --verify --migrations $migrationPath
  if ($LASTEXITCODE -ne 0) { throw 'Migracije so se izvedle, vendar preverjanje baze ni uspelo.' }
  Write-Host 'ALLOWED: vse migracije so namescene in baza je preverjena.'
}
finally {
  Remove-Item Env:PIM_CONNECTION_STRING -ErrorAction SilentlyContinue
}
