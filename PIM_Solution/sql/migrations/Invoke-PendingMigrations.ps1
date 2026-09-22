<#
  Invoke-PendingMigrations.ps1

  Pregleda mapo z migracijami (NNN_Opis.sql) in dbo.SchemaMigration na ciljni bazi,
  nato izvede SAMO tiste datoteke, ki jih v tabeli se ni. Tabela in nacin racunanja
  hasha sta namerno identicna PIM.Migratorju (PIM_Solution\src\PIM.Migrator\Program.cs),
  da se sledi ne podvajata/sprejo, ce kdaj kasneje na isti bazi pozenes se pravi
  `dotnet run --project src\PIM.Migrator`.

  Razlike proti pravemu migratorju (zavedaj se ju):
    - vsaka datoteka se izvede v SVOJI sqlcmd seji, ne v eni skupni transakciji
      cez vse datoteke - ce datoteka #5 pade, #1-4 iz tega zagona OSTANEJO uveljavljene.
    - ne klice --verify preverb (F0-F10); po koncu zazeni se pravi migrator z --verify,
      ce je na voljo.

  Vsaka datoteka gre skozi `sqlcmd -I` (QUOTED_IDENTIFIER ON) - BREZ tega nekatere
  procedure v tem repozitoriju padejo z napako 1934 pri UPDATE. Ne odstranjuj -I.

  UPORABA
  -------
  # samo preveri stanje (nic ne spremeni bazo):
  .\Invoke-PendingMigrations.ps1 -ConnectionString $env:PIM_CONNECTION_STRING -Status

  # predogled, kaj bi se izvedlo:
  .\Invoke-PendingMigrations.ps1 -ConnectionString "Server=...;Database=PIM_TEST;Integrated Security=True;Encrypt=True;TrustServerCertificate=True" -WhatIf

  # dejansko izvede manjkajoce migracije:
  .\Invoke-PendingMigrations.ps1 -ConnectionString "Server=...;Database=PIM_TEST;Integrated Security=True;Encrypt=True;TrustServerCertificate=True"

  Connection string lahko namesto parametra prides tudi iz okoljske spremenljivke
  PIM_CONNECTION_STRING (ista spremenljivka, ki jo bere PIM.Migrator in workerji).
#>
[CmdletBinding()]
param(
  [string]$ConnectionString = $env:PIM_CONNECTION_STRING,

  [string]$MigrationsPath = $PSScriptRoot,

  # Samo izpise stanje (Pending / Applied / CHANGED) in nic ne izvede.
  [switch]$Status,

  # Izpise, kaj bi izvedel, brez dejanskega izvajanja proti bazi.
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

function ConvertFrom-ConnString {
  param([Parameter(Mandatory)][string]$ConnectionString)
  $map = @{}
  foreach ($pair in $ConnectionString -split ';') {
    if ([string]::IsNullOrWhiteSpace($pair)) { continue }
    $idx = $pair.IndexOf('=')
    if ($idx -lt 0) { continue }
    $key = $pair.Substring(0, $idx).Trim().ToLowerInvariant()
    $val = $pair.Substring($idx + 1).Trim()
    $map[$key] = $val
  }
  return $map
}

function Get-MigrationHash {
  param([Parameter(Mandatory)][string]$Path)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $bytes = $bytes[3..($bytes.Length - 1)]
  }
  $text = [System.Text.Encoding]::UTF8.GetString($bytes)
  # Isto kot NormalizeLineEndings v Program.cs: konci vrstic -> LF, sele nato hash.
  $normalized = $text -replace "`r`n", "`n" -replace "`r", "`n"
  $normalizedBytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hashBytes = $sha.ComputeHash($normalizedBytes)
  } finally {
    $sha.Dispose()
  }
  return ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
}

function Invoke-Sqlcmd2 {
  # Tanka ovojnica okoli sqlcmd.exe - vedno z -I, vrne (ExitCode, StdOut).
  param(
    [Parameter(Mandatory)][string[]]$ConnArgs,
    [string]$Query,
    [string]$InputFile
  )
  # -f 65001: brez tega sqlcmd -i bere datoteko v OS codepage namesto UTF-8, kar Ĺˇumnike
  # (Ĺľivljenjska, DolĹľina ...) v N'...' literalih podvojeno napacno prekodira.
  $args = @($ConnArgs) + @('-I', '-b', '-f', '65001')
  if ($InputFile) { $args += @('-i', $InputFile) }
  elseif ($Query) { $args += @('-Q', $Query) }
  else { throw "Invoke-Sqlcmd2 rabi -Query ali -InputFile." }

  $output = & sqlcmd @args 2>&1
  [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
  throw "sqlcmd ni najden v PATH. Namesti 'sqlcmd Utility' (del SQL Server ali mssql-tools/mssql-tools18) ali dodaj njegovo mapo v PATH."
}

if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
  throw "Manjka -ConnectionString (ali okoljska spremenljivka PIM_CONNECTION_STRING)."
}

if (-not (Test-Path $MigrationsPath)) {
  throw "Mapa z migracijami ne obstaja: $MigrationsPath"
}

$cs = ConvertFrom-ConnString -ConnectionString $ConnectionString
$server = $cs['server']; if (-not $server) { $server = $cs['data source'] }
$database = $cs['database']; if (-not $database) { $database = $cs['initial catalog'] }
if (-not $server -or -not $database) {
  throw "Connection string mora vsebovati Server (Data Source) in Database (Initial Catalog)."
}
$userId = $cs['user id']; if (-not $userId) { $userId = $cs['uid'] }
$password = $cs['password']; if (-not $password) { $password = $cs['pwd'] }

$connArgs = @('-S', $server, '-d', $database)
if ($userId) {
  $connArgs += @('-U', $userId, '-P', $password)
} else {
  $connArgs += '-E'   # Windows/integrirana prijava
}
if ($cs['encrypt'] -and $cs['encrypt'].ToLowerInvariant() -in @('true', 'yes', 'mandatory')) { $connArgs += '-N' }
if ($cs['trustservercertificate'] -and $cs['trustservercertificate'].ToLowerInvariant() -in @('true', 'yes')) { $connArgs += '-C' }

Write-Host "Streznik: $server | Baza: $database" -ForegroundColor Cyan

# 1. Poskrbi, da tabela sledi obstaja - shema identicna PIM.Migratorju.
$ensureLedgerSql = @"
SET NOCOUNT ON;
IF OBJECT_ID(N'dbo.SchemaMigration', N'U') IS NULL
BEGIN
  CREATE TABLE dbo.SchemaMigration
  (
    MigrationId nvarchar(255) NOT NULL,
    ScriptHash char(64) NOT NULL,
    AppliedUtc datetime2(3) NOT NULL CONSTRAINT DF_SchemaMigration_AppliedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_SchemaMigration PRIMARY KEY CLUSTERED (MigrationId)
  );
END;
"@
$ensureResult = Invoke-Sqlcmd2 -ConnArgs $connArgs -Query $ensureLedgerSql
if ($ensureResult.ExitCode -ne 0) {
  throw "Povezava z bazo ali priprava dbo.SchemaMigration ni uspela:`n$($ensureResult.Output)"
}

# 2. Preberi obstojece zapise (MigrationId|ScriptHash).
$readLedgerSql = "SET NOCOUNT ON; SELECT MigrationId + '|' + ScriptHash FROM dbo.SchemaMigration;"
$ledgerResult = Invoke-Sqlcmd2 -ConnArgs $connArgs -Query $readLedgerSql
if ($ledgerResult.ExitCode -ne 0) {
  throw "Branje dbo.SchemaMigration ni uspelo:`n$($ledgerResult.Output)"
}

$applied = @{}
foreach ($line in ($ledgerResult.Output -split "`n")) {
  $trim = $line.Trim()
  if ($trim -eq '' -or $trim -notmatch '\|') { continue }
  $parts = $trim -split '\|', 2
  $applied[$parts[0].Trim()] = $parts[1].Trim()
}
Write-Host "V dbo.SchemaMigration je ze $($applied.Count) vnosov." -ForegroundColor Cyan

# 3. Preberi datoteke, isti vrstni red kot PIM.Migrator (Ordinal po imenu).
$files = Get-ChildItem -Path $MigrationsPath -Filter '*.sql' -File |
  Where-Object { $_.Name -match '^\d{3}_[A-Za-z0-9][A-Za-z0-9_-]*\.sql$' } |
  Sort-Object Name -CaseSensitive

if ($files.Count -eq 0) {
  Write-Warning "V $MigrationsPath ni najdene nobene datoteke oblike NNN_Opis.sql."
  return
}

$pending = New-Object System.Collections.Generic.List[object]
$changed = New-Object System.Collections.Generic.List[string]

foreach ($file in $files) {
  $hash = Get-MigrationHash -Path $file.FullName
  if ($applied.ContainsKey($file.Name)) {
    if ($applied[$file.Name] -eq $hash) {
      Write-Host "Ze uveljavljena: $($file.Name)" -ForegroundColor DarkGray
    } else {
      Write-Warning "SPREMENJENA vsebina ze uveljavljene migracije: $($file.Name) - PRESKOCENA, ne dotikam se je."
      $changed.Add($file.Name)
    }
  } else {
    $pending.Add([pscustomobject]@{ File = $file; Hash = $hash })
  }
}

Write-Host ""
Write-Host "Novih (Pending): $($pending.Count) | Ze uveljavljenih: $($applied.Count - $changed.Count) | Spremenjenih (STOP): $($changed.Count)" -ForegroundColor Yellow

if ($changed.Count -gt 0) {
  Write-Warning "Najprej razcisti spremenjene migracije zgoraj (vsebina v datoteki se ne sme spreminjati za ze uveljavljeno migracijo). Nadaljujem samo z novimi."
}

if ($Status) {
  $pending | ForEach-Object { Write-Host "Pending: $($_.File.Name)" -ForegroundColor Green }
  return
}

if ($pending.Count -eq 0) {
  Write-Host "Nic za narediti - baza je na tekocem." -ForegroundColor Green
  return
}

foreach ($item in $pending) {
  $name = $item.File.Name
  if ($WhatIf) {
    Write-Host "BI IZVEDEL: $name" -ForegroundColor Green
    continue
  }

  Write-Host "Izvajam: $name ..." -ForegroundColor White
  $execResult = Invoke-Sqlcmd2 -ConnArgs $connArgs -InputFile $item.File.FullName
  if ($execResult.ExitCode -ne 0) {
    Write-Host $execResult.Output
    throw "Migracija $name NI uspela (izhodna koda $($execResult.ExitCode)). Ustavljam se tukaj - vse pred njo v tem zagonu je ze uveljavljeno, $name in vse za njo NISO."
  }

  $escapedName = $name.Replace("'", "''")
  $insertSql = "SET NOCOUNT ON; INSERT dbo.SchemaMigration (MigrationId, ScriptHash) VALUES (N'$escapedName', '$($item.Hash)');"
  $insertResult = Invoke-Sqlcmd2 -ConnArgs $connArgs -Query $insertSql
  if ($insertResult.ExitCode -ne 0) {
    throw "Migracija $name se JE izvedla, a zapis v dbo.SchemaMigration ni uspel:`n$($insertResult.Output)`nPOZOR: pred ponovnim zagonom rocno preveri/dodaj vrstico, sicer se bo poskusila izvesti se enkrat."
  }

  Write-Host "Uveljavljena: $name" -ForegroundColor Green
}

Write-Host ""
Write-Host "Konec. Izvedenih $($pending.Count) novih migracij." -ForegroundColor Cyan
