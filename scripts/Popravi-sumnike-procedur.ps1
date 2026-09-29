<#
.SYNOPSIS
  Popravi sumnike v shranjenih procedurah, pogledih in funkcijah, ki so nastale iz UTF-8 migracije,
  prebrane kot Windows-1250 (v intranetu vsak sumnik kot dva cudna znaka, npr. L z naglasom + dvojni naglas).

.DESCRIPTION
  Migracije so UTF-8 brez BOM. Ce jih kdo izvede brez sqlcmd -f 65001 (SSMS, stara kopija
  Invoke-PendingMigrations.ps1), SQL Server shrani vsak sumnik kot dva napacna znaka. Ta skripta:
    1. najde objekte, katerih definicija vsebuje znacilna napacna znaka (U+0139, U+00C4);
    2. definicijo pretvori nazaj: znaki -> bajti Windows-1250 -> besedilo UTF-8;
    3. preveri obratno pot (popravljeno -> UTF-8 -> Windows-1250 mora dati tocno staro definicijo);
       objekt, pri katerem preverjanje ne uspe, preskoci in izpise;
    4. brez -Izvedi samo zapise popravljene definicije v mapo in izpise seznam (suhi tek);
    5. z -Izvedi vse ponovno ustvari (CREATE OR ALTER, iste nastavitve ANSI_NULLS/QUOTED_IDENTIFIER)
       v eni transakciji - ob katerikoli napaki se ne spremeni nic.
  CREATE OR ALTER ohrani pravice (GRANT) na objektu. Samo ASCII v tej datoteki (PowerShell 5.1).

.PARAMETER Mapa
  Mapa intraneta (npr. C:\inetpub\wwwroot\PIM_prd_app); povezava iz appsettings.Local.json ali appsettings.json.

.PARAMETER ConnectionString
  Povezava neposredno (namesto -Mapa).

.PARAMETER Izvedi
  Brez tega samo suhi tek.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Popravi-sumnike-procedur.ps1 -Mapa C:\inetpub\wwwroot\PIM_prd_app
  powershell -ExecutionPolicy Bypass -File Popravi-sumnike-procedur.ps1 -Mapa C:\inetpub\wwwroot\PIM_prd_app -Izvedi
#>
param(
  [string]$Mapa = '',
  [string]$ConnectionString = '',
  [switch]$Izvedi
)
$ErrorActionPreference = 'Stop'

if (-not $ConnectionString) {
  if (-not $Mapa) { throw 'Podaj -Mapa (mapa intraneta) ali -ConnectionString.' }
  foreach ($f in 'appsettings.Local.json', 'appsettings.json') {
    $p = Join-Path $Mapa $f
    if (Test-Path $p) {
      $j = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($j.ConnectionStrings.Pim) { $ConnectionString = $j.ConnectionStrings.Pim; break }
    }
  }
  if (-not $ConnectionString) { throw "V $Mapa ni ConnectionStrings:Pim." }
}

$cp1250 = [System.Text.Encoding]::GetEncoding(1250)
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$createPattern = New-Object System.Text.RegularExpressions.Regex('\bCREATE\s+(?:OR\s+ALTER\s+)?(PROCEDURE|PROC|VIEW|FUNCTION|TRIGGER)\b', 'IgnoreCase')
$bad1 = [string][char]0x0139
$bad2 = [string][char]0x00C4

$out = Join-Path $env:TEMP ('pim-sumniki-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $out | Out-Null

$cn = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
$cn.Open()
try {
  $q = $cn.CreateCommand()
  $q.CommandText = @"
SELECT QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name), o.type_desc, m.definition,
       m.uses_ansi_nulls, m.uses_quoted_identifier
FROM sys.sql_modules m JOIN sys.objects o ON o.object_id = m.object_id
WHERE m.definition LIKE N'%' + NCHAR(313) + N'%' OR m.definition LIKE N'%' + NCHAR(196) + N'%'
ORDER BY 1;
"@
  $rows = @()
  $r = $q.ExecuteReader()
  while ($r.Read()) {
    $rows += [pscustomobject]@{ Name = $r.GetString(0); Type = $r.GetString(1); Definition = $r.GetString(2); AnsiNulls = $r.GetBoolean(3); QuotedId = $r.GetBoolean(4) }
  }
  $r.Close()

  $ok = @(); $skipped = @()
  foreach ($row in $rows) {
    $fixed = $null
    try { $fixed = $utf8Strict.GetString($cp1250.GetBytes($row.Definition)) } catch { $skipped += "$($row.Name): ni veljaven UTF-8 po pretvorbi"; continue }
    if ($cp1250.GetString($utf8.GetBytes($fixed)) -ne $row.Definition) { $skipped += "$($row.Name): obratna pot se ne ujema"; continue }
    if ($fixed.Contains($bad1)) { $skipped += "$($row.Name): po popravku se vedno vsebuje napacne znake (dvojna pretvorba?)"; continue }
    if (-not $createPattern.IsMatch($fixed)) { $skipped += "$($row.Name): ne najdem CREATE"; continue }
    $ddl = $createPattern.Replace($fixed, { param($m) 'CREATE OR ALTER ' + $m.Groups[1].Value.ToUpperInvariant() }, 1)
    $file = Join-Path $out (($row.Name -replace '[\[\]]', '') + '.sql')
    [System.IO.File]::WriteAllText($file, $ddl, (New-Object System.Text.UTF8Encoding($true)))
    $ok += [pscustomobject]@{ Name = $row.Name; Type = $row.Type; Ddl = $ddl; AnsiNulls = $row.AnsiNulls; QuotedId = $row.QuotedId; Shrinked = $row.Definition.Length - $fixed.Length }
  }

  Write-Host "Najdenih: $($rows.Count), za popravek: $($ok.Count), preskocenih: $($skipped.Count)"
  $ok | ForEach-Object { Write-Host ("  OK  {0,-55} {1,-22} znakov manj: {2}" -f $_.Name, $_.Type, $_.Shrinked) }
  $skipped | ForEach-Object { Write-Warning $_ }
  Write-Host "Popravljene definicije: $out"

  if (-not $Izvedi) { Write-Host 'Suhi tek - v bazi ni spremenjeno nic. Za popravek dodaj -Izvedi.'; return }
  if ($ok.Count -eq 0) { return }

  $tx = $cn.BeginTransaction()
  try {
    foreach ($o in $ok) {
      $c = $cn.CreateCommand(); $c.Transaction = $tx
      $c.CommandText = "SET ANSI_NULLS $(if ($o.AnsiNulls) {'ON'} else {'OFF'}); SET QUOTED_IDENTIFIER $(if ($o.QuotedId) {'ON'} else {'OFF'});"
      [void]$c.ExecuteNonQuery()
      $c = $cn.CreateCommand(); $c.Transaction = $tx; $c.CommandText = $o.Ddl; $c.CommandTimeout = 120
      [void]$c.ExecuteNonQuery()
      Write-Host "  popravljen $($o.Name)"
    }
    $tx.Commit()
    Write-Host "Popravljenih: $($ok.Count)."
  }
  catch { $tx.Rollback(); Write-Warning "Napaka pri $($o.Name) - nic ni spremenjeno: $($_.Exception.Message)"; throw }
}
finally { $cn.Close() }
