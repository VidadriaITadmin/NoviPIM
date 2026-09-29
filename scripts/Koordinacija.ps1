<#
.SYNOPSIS
  Skupna tabla nalog za vse seje Claude na PIM: kdo dela kaj, zaklepi področij, rezervacija
  številk migracij, vrata preverjanja in pregledna stran za lastnika.

.DESCRIPTION
  Stanje je v skupni mapi git (<git-common-dir>\pim-koordinacija), zato ga vidijo vse seje in vse
  delovne kopije (worktree) hkrati, tudi preden je karkoli združeno v main.

  -Ukaz Stanje      Izpiše tablo in osveži pregledno stran PREGLED.html (odpre jo z -Odpri).
  -Ukaz Nova        Nova naloga: -Naslov, -Prednost V/S/N, -Vrsta, -Vir, -Obmocje, -Strani, -Testi, -Opis.
  -Ukaz Prevzemi    -Id -Seja: naloga gre v delo; zavrne, če se območje prekriva z nalogo v delu.
  -Ukaz Sprosti     -Id: naloga nazaj med pripravljene (npr. seja konča brez dokončanja).
  -Ukaz Sporocilo   -Id -Besedilo: zapis v dnevnik naloge (sporočilo drugim sejam).
  -Ukaz Odlocitev   -Id -Besedilo: vprašanje za lastnika (naloga čaka); -Odgovor: zapiše odgovor.
  -Ukaz Migracija   -Id -Ime: rezervira naslednjo številko migracije in ustvari prazno datoteko.
  -Ukaz Preveri     -Id: vrata — build Release, testi naloge, procesi (Vpliv/Preveri), klikalnik
                    na straneh naloge. Rezultat se zapiše v nalogo. Izhod 0 = vse OK.
  -Ukaz Koncaj      -Id: naloga gre v pregled (samo, če so zadnja vrata OK).
  -Ukaz Zdruzi      -Id: (samo v glavni kopiji) združi vejo naloge v main, če je main čist.
  -Ukaz Nastavi     -Id -Polje -Vrednost: spremeni polje naloge (stanje, prednost, obmocje ...).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\Koordinacija.ps1 -Ukaz Stanje -Odpri
  powershell -ExecutionPolicy Bypass -File scripts\Koordinacija.ps1 -Ukaz Prevzemi -Id 3 -Seja "Popravki strani"
#>
param(
  [ValidateSet('Stanje', 'Nova', 'Prevzemi', 'Sprosti', 'Sporocilo', 'Odlocitev', 'Migracija', 'Preveri', 'Koncaj', 'Zdruzi', 'Nastavi')]
  [string]$Ukaz = 'Stanje',
  [int]$Id,
  [string]$Seja = $env:USERNAME,
  [string]$Naslov,
  [ValidateSet('V', 'S', 'N')][string]$Prednost = 'S',
  [string]$Vrsta = 'napaka',
  [string]$Vir,
  [string[]]$Obmocje = @(),
  [string[]]$Strani = @(),
  [string[]]$Testi = @(),
  [int[]]$Odvisno = @(),
  [string]$Opis,
  [string]$Besedilo,
  [string]$Odgovor,
  [string]$Ime,
  [string]$Polje,
  [string]$Vrednost,
  [switch]$Kljub,
  [switch]$Odpri,
  [switch]$BrezKlikalnika
)

$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8
$Koren = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Invoke-Git {
  $ErrorActionPreference = 'Continue'
  $izhod = & git -C $Koren @args 2>$null
  $script:GitIzhod = $LASTEXITCODE
  return $izhod
}

$Skupna = (Invoke-Git rev-parse --path-format=absolute --git-common-dir | Select-Object -First 1)
if (-not $Skupna) { throw 'Ni git repozitorija.' }
$Mapa = Join-Path $Skupna 'pim-koordinacija'
$MapaNalog = Join-Path $Mapa 'naloge'
$MapaPreverjanj = Join-Path $Mapa 'preverjanja'
foreach ($m in $Mapa, $MapaNalog, $MapaPreverjanj) { if (-not (Test-Path $m)) { New-Item -ItemType Directory -Path $m | Out-Null } }
$DatotekaMigracij = Join-Path $Mapa 'migracije.txt'
$DatotekaDnevnika = Join-Path $Mapa 'dnevnik.log'
$DatotekaNastavitev = Join-Path $Mapa 'nastavitve.json'
if (-not (Test-Path $DatotekaNastavitev)) {
  [IO.File]::WriteAllText($DatotekaNastavitev, (@{ razvojniStreznik = 'DAVID\MSSQL19'; razvojnaBaza = 'PIM' } | ConvertTo-Json), $Utf8)
}
$Nastavitve = [IO.File]::ReadAllText($DatotekaNastavitev, $Utf8) | ConvertFrom-Json

$Stanja = @('predlog', 'pripravljena', 'v-delu', 'preverjanje', 'pregled', 'koncana', 'blokirana', 'opuscena')
$Aktivna = @('v-delu', 'preverjanje')
$Polja = @('id', 'naslov', 'stanje', 'prednost', 'vrsta', 'vir', 'obmocje', 'strani', 'testi', 'odvisno',
  'odlocitev', 'seja', 'veja', 'pot', 'preverjeno', 'ustvarjeno', 'posodobljeno')
$Seznami = @('obmocje', 'strani', 'testi', 'odvisno')

function Get-Cas { return (Get-Date).ToString('yyyy-MM-dd HH:mm') }

# Enostaven zaklep med procesi: datoteka, ki jo ustvari samo en proces naenkrat.
function Use-Zaklep([scriptblock]$delo) {
  $pot = Join-Path $Mapa '.zaklep'
  $rok = (Get-Date).AddSeconds(30)
  $tok = $null
  while (-not $tok) {
    try { $tok = [IO.File]::Open($pot, 'CreateNew', 'Write', 'None') }
    catch {
      if ((Get-Date) -gt $rok) {
        $star = (Get-Item $pot -ErrorAction SilentlyContinue)
        if ($star -and $star.LastWriteTime -lt (Get-Date).AddMinutes(-2)) { Remove-Item $pot -Force; continue }
        throw 'Tabla je zaklenjena (druga seja piše). Poskusi znova.'
      }
      Start-Sleep -Milliseconds 200
    }
  }
  try { & $delo } finally { $tok.Close(); Remove-Item $pot -Force -ErrorAction SilentlyContinue }
}

function Read-Naloga([string]$pot) {
  $vrstice = [IO.File]::ReadAllLines($pot, $Utf8)
  $n = [ordered]@{}
  foreach ($p in $Polja) { $n[$p] = '' }
  foreach ($p in $Seznami) { $n[$p] = @() }
  $i = 1
  for (; $i -lt $vrstice.Count; $i++) {
    $v = $vrstice[$i]
    if ($v.Trim() -eq '---') { break }
    if ($v -notmatch '^([a-z]+):\s?(.*)$') { continue }
    $k = $Matches[1]; $vr = $Matches[2].Trim()
    if ($Seznami -contains $k) {
      $n[$k] = @($vr.Trim('[', ']') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } else { $n[$k] = $vr }
  }
  $n['telo'] = ($vrstice[($i + 1)..($vrstice.Count - 1)] -join "`r`n")
  $n['datoteka'] = $pot
  return $n
}

function Write-Naloga($n) {
  $n.posodobljeno = Get-Cas
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('---')
  foreach ($p in $Polja) {
    $vr = $n[$p]
    if ($Seznami -contains $p) { $vr = '[' + (@($vr) -join ', ') + ']' }
    [void]$sb.AppendLine("${p}: $vr")
  }
  [void]$sb.AppendLine('---')
  [void]$sb.Append($n.telo)
  [IO.File]::WriteAllText($n.datoteka, $sb.ToString(), $Utf8)
}

function Get-Naloge {
  @(Get-ChildItem $MapaNalog -Filter *.md | Sort-Object Name | ForEach-Object { Read-Naloga $_.FullName })
}

function Get-Naloga([int]$id) {
  $pot = Join-Path $MapaNalog ('{0:D4}.md' -f $id)
  if (-not (Test-Path $pot)) { throw "Naloga $id ne obstaja." }
  return Read-Naloga $pot
}

function Add-Dnevnik($n, [string]$besedilo) {
  $n.telo = $n.telo.TrimEnd() + "`r`n- $(Get-Cas) · $Seja · $besedilo`r`n"
  [IO.File]::AppendAllText($DatotekaDnevnika, "$(Get-Cas)`t$Seja`t#$($n.id)`t$besedilo`r`n", $Utf8)
}

function ConvertTo-Pot([string]$p) { return $p.Replace('\', '/').Trim().TrimEnd('/').ToLowerInvariant() }

function Test-Prekrivanje([string[]]$a, [string[]]$b) {
  foreach ($x in $a) { foreach ($y in $b) {
    $px = ConvertTo-Pot $x; $py = ConvertTo-Pot $y
    if (-not $px -or -not $py) { continue }
    # Migracije niso zaklep področja: številke se rezervirajo z -Ukaz Migracija.
    if ($px -eq 'pim_solution/sql/migrations' -or $py -eq 'pim_solution/sql/migrations') { continue }
    if ($px -eq $py -or $px.StartsWith("$py/") -or $py.StartsWith("$px/")) { return "$x ↔ $y" }
  } }
  return $null
}

function Get-Delo {
  # Vse delovne kopije (glavna + worktree) z vejo in številom nepotrjenih sprememb.
  $izid = @(); $cur = $null
  foreach ($v in (Invoke-Git worktree list --porcelain)) {
    if ($v -like 'worktree *') { if ($cur) { $izid += $cur }; $cur = [ordered]@{ pot = $v.Substring(9); veja = '' } }
    elseif ($v -like 'branch *') { $cur.veja = $v.Substring(7) -replace '^refs/heads/', '' }
  }
  if ($cur) { $izid += $cur }
  foreach ($d in $izid) {
    $ErrorActionPreference = 'Continue'
    $d.spremembe = @(& git -C $d.pot status --porcelain 2>$null).Count
    $d.zadnji = (& git -C $d.pot log -1 --format='%cr · %s' 2>$null | Select-Object -First 1)
  }
  return $izid
}

# ---------------------------------------------------------------- pregledna stran
function Write-Pregled {
  $naloge = Get-Naloge
  $delo = Get-Delo
  $enc = { param($s) [Net.WebUtility]::HtmlEncode([string]$s) }
  $stolpci = [ordered]@{
    'Čaka tvojo odločitev' = @($naloge | Where-Object { $_.odlocitev -and $_.stanje -notin 'koncana', 'opuscena' })
    'V delu'               = @($naloge | Where-Object { $_.stanje -in $Aktivna })
    'Za pregled'           = @($naloge | Where-Object { $_.stanje -eq 'pregled' })
    'Pripravljene'         = @($naloge | Where-Object { $_.stanje -eq 'pripravljena' -and -not $_.odlocitev })
    'Predlogi'             = @($naloge | Where-Object { $_.stanje -eq 'predlog' -and -not $_.odlocitev })
    'Blokirane'            = @($naloge | Where-Object { $_.stanje -eq 'blokirana' })
    'Končane'              = @($naloge | Where-Object { $_.stanje -eq 'koncana' } | Select-Object -Last 15)
  }
  $red = @{ V = 0; S = 1; N = 2 }
  $html = New-Object System.Text.StringBuilder
  [void]$html.Append(@"
<!doctype html><html lang="sl"><head><meta charset="utf-8"><meta http-equiv="refresh" content="60">
<title>PIM naloge</title><style>
:root{--bg:#f6f7f9;--card:#fff;--ink:#1d2330;--mut:#5b6475;--line:#dde1e8;--v:#b42318;--s:#b54708;--n:#475467;--ok:#067647;--acc:#1849a9}
@media (prefers-color-scheme:dark){:root{--bg:#12151b;--card:#1b2029;--ink:#e7eaf0;--mut:#9aa3b2;--line:#2c3340;--v:#f97066;--s:#fdb022;--n:#98a2b3;--ok:#47cd89;--acc:#84adff}}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 "Segoe UI",system-ui,sans-serif}
header{padding:16px 20px;border-bottom:1px solid var(--line);display:flex;gap:24px;align-items:baseline;flex-wrap:wrap}
h1{font-size:18px;margin:0}.mut{color:var(--mut)}main{padding:16px 20px;display:grid;gap:16px}
.cols{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px}
section{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px 12px}
h2{font-size:13px;margin:0 0 8px;text-transform:uppercase;letter-spacing:.04em;color:var(--mut)}
.k{border-top:1px solid var(--line);padding:8px 0}.k:first-of-type{border-top:0}
.p{display:inline-block;min-width:18px;text-align:center;border-radius:4px;font-weight:600;font-size:12px;color:#fff;margin-right:6px}
.pV{background:var(--v)}.pS{background:var(--s)}.pN{background:var(--n)}
.q{margin-top:4px;padding:6px 8px;border-left:3px solid var(--acc);background:color-mix(in srgb,var(--acc) 8%,transparent)}
table{border-collapse:collapse;width:100%}td,th{border-bottom:1px solid var(--line);padding:4px 6px;text-align:left;font-size:13px}
.ok{color:var(--ok)}.bad{color:var(--v)}
</style></head><body><header><h1>PIM — naloge in seje</h1>
<span class="mut">osveženo $(Get-Cas) · stran se osveži vsako minuto · $($naloge.Count) nalog</span></header><main>
"@)
  [void]$html.Append('<div class="cols">')
  foreach ($ime in $stolpci.Keys) {
    $sez = @($stolpci[$ime] | Sort-Object @{ e = { $red[$_.prednost] } }, @{ e = { [int]$_.id } })
    [void]$html.Append("<section><h2>$(& $enc $ime) ($($sez.Count))</h2>")
    foreach ($n in $sez) {
      $pp = if ($n.prednost) { $n.prednost } else { 'S' }
      [void]$html.Append("<div class='k'><span class='p p$pp'>$pp</span><b>#$($n.id)</b> $(& $enc $n.naslov)")
      $meta = @()
      if ($n.seja -and $n.stanje -in $Aktivna) { $meta += "dela: $($n.seja)" }
      if ($n.vir) { $meta += $n.vir }
      if ($n.preverjeno) { $meta += "vrata: $($n.preverjeno)" }
      if ($meta) { [void]$html.Append("<div class='mut'>$(& $enc ($meta -join ' · '))</div>") }
      if ($n.odlocitev) { [void]$html.Append("<div class='q'>$(& $enc $n.odlocitev)</div>") }
      [void]$html.Append('</div>')
    }
    [void]$html.Append('</section>')
  }
  [void]$html.Append('</div>')
  [void]$html.Append('<section><h2>Delovne kopije</h2><table><tr><th>Mapa</th><th>Veja</th><th>Nepotrjenih sprememb</th><th>Zadnja potrditev</th></tr>')
  foreach ($d in $delo) {
    $cls = if ($d.spremembe -gt 0) { 'bad' } else { 'ok' }
    [void]$html.Append("<tr><td>$(& $enc $d.pot)</td><td>$(& $enc $d.veja)</td><td class='$cls'>$($d.spremembe)</td><td>$(& $enc $d.zadnji)</td></tr>")
  }
  [void]$html.Append('</table></section>')
  if (Test-Path $DatotekaMigracij) {
    [void]$html.Append('<section><h2>Rezervirane migracije</h2><table>')
    foreach ($v in ([IO.File]::ReadAllLines($DatotekaMigracij, $Utf8) | Select-Object -Last 12)) {
      [void]$html.Append('<tr>' + (($v -split "`t" | ForEach-Object { "<td>$(& $enc $_)</td>" }) -join '') + '</tr>')
    }
    [void]$html.Append('</table></section>')
  }
  if (Test-Path $DatotekaDnevnika) {
    [void]$html.Append('<section><h2>Zadnji dogodki</h2><table>')
    foreach ($v in ([IO.File]::ReadAllLines($DatotekaDnevnika, $Utf8) | Select-Object -Last 25 | Sort-Object -Descending)) {
      [void]$html.Append('<tr>' + (($v -split "`t" | ForEach-Object { "<td>$(& $enc $_)</td>" }) -join '') + '</tr>')
    }
    [void]$html.Append('</table></section>')
  }
  [void]$html.Append('</main></body></html>')
  $pot = Join-Path $Mapa 'PREGLED.html'
  [IO.File]::WriteAllText($pot, $html.ToString(), $Utf8)
  return $pot
}

# ---------------------------------------------------------------- vrata preverjanja
function Invoke-Korak([string]$ime, [string]$exe, [string[]]$argumenti, [int]$minut, [string]$log, [string]$mapa = $Koren) {
  Write-Host "  · $ime ..." -NoNewline
  $izhod = "$log.$($ime -replace '\W', '_').txt"
  $p = Start-Process -FilePath $exe -ArgumentList $argumenti -WorkingDirectory $mapa -NoNewWindow -PassThru `
    -RedirectStandardOutput $izhod -RedirectStandardError "$izhod.err"
  # Brez branja Handle takoj po zagonu PS 5.1 po WaitForExit(ms) vrne prazen ExitCode (naloga #38).
  $null = $p.Handle
  if (-not $p.WaitForExit($minut * 60 * 1000)) {
    & taskkill /PID $p.Id /T /F 2>$null | Out-Null
    Write-Host " PREKINJENO po $minut min" -ForegroundColor Red
    return @{ ok = $false; opis = "${ime}: prekinjeno po $minut min" }
  }
  $p.WaitForExit()
  $ok = ($p.ExitCode -eq 0)
  if ($ok) { Write-Host ' OK' -ForegroundColor Green } else { Write-Host " NAPAKA (izhod $($p.ExitCode), glej $izhod)" -ForegroundColor Red }
  return @{ ok = $ok; opis = "${ime}: " + $(if ($ok) { 'OK' } else { "napaka ($($p.ExitCode))" }); izhod = $izhod; koda = $p.ExitCode }
}

function Get-StraniIzSprememb {
  # Strani (@page) iz spremenjenih .razor datotek proti main.
  $spremenjene = @(Invoke-Git diff --name-only main) + @(Invoke-Git ls-files --others --exclude-standard)
  $strani = @()
  foreach ($f in ($spremenjene | Where-Object { $_ -like '*.razor' } | Select-Object -Unique)) {
    $pot = Join-Path $Koren $f
    if (-not (Test-Path $pot)) { continue }
    foreach ($m in [regex]::Matches([IO.File]::ReadAllText($pot, $Utf8), '(?m)^@page "([^"]+)"')) {
      $s = $m.Groups[1].Value
      if ($s -notmatch '\{') { $strani += $s.TrimStart('/') }
    }
  }
  return @($strani | Where-Object { $_ } | Select-Object -Unique)
}

function Invoke-Vrata($n) {
  $cas = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $log = Join-Path $MapaPreverjanj ("{0:D4}-$cas" -f [int]$n.id)
  $rez = @()
  # Nikoli proti produkciji: testi in klikalnik dobijo izrecno razvojno povezavo.
  $env:PIM_CONNECTION_STRING = "Server=$($Nastavitve.razvojniStreznik);Database=$($Nastavitve.razvojnaBaza);Integrated Security=True;Encrypt=True;TrustServerCertificate=True"
  Write-Host "Vrata za nalogo #$($n.id) v $Koren (baza $($Nastavitve.razvojniStreznik))"
  # Testni podatki (PIM_Solution/fixtures) niso v gitu; delovna kopija jih dobi iz glavne kopije.
  $glavna = Split-Path $Skupna -Parent
  $fix = Join-Path $Koren 'PIM_Solution/fixtures'
  $fixGlavna = Join-Path $glavna 'PIM_Solution/fixtures'
  if (-not (Test-Path $fix) -and (Test-Path $fixGlavna) -and ($fix -ne $fixGlavna)) {
    Copy-Item $fixGlavna $fix -Recurse
    Write-Host '  · testni podatki (fixtures) prekopirani iz glavne kopije'
  }

  $rez += Invoke-Korak 'build' 'dotnet' @('build', 'PIM_Solution\PIM.sln', '-c', 'Release', '-nologo', '-v', 'q') 20 $log

  foreach ($t in @($n.testi)) {
    if ($t -match 'ProductWorkbook' -and -not $Kljub) { $rez += @{ ok = $true; opis = "test ${t}: preskočen (DB del zamrzne SQL; -Kljub za zagon)" }; continue }
    $rez += Invoke-Korak "test $t" 'powershell' @('-ExecutionPolicy', 'Bypass', '-File', 'scripts\run_tests.ps1', '-Filter', $t) 25 $log
  }

  $vpliv = Invoke-Korak 'procesi-vpliv' 'powershell' @('-ExecutionPolicy', 'Bypass', '-File', 'scripts\Procesi.ps1', '-Ukaz', 'Vpliv', '-Od', 'main') 5 $log
  if ($vpliv.koda -eq 2) { $vpliv.opis = 'procesi-vpliv: sprememba PODRE podatek, ki ga nekdo bere' } elseif ($vpliv.koda -ne 0) { $vpliv.ok = $true; $vpliv.opis = 'procesi-vpliv: opozorila' }
  $rez += $vpliv
  $prev = Invoke-Korak 'procesi-preveri' 'powershell' @('-ExecutionPolicy', 'Bypass', '-File', 'scripts\Procesi.ps1', '-Ukaz', 'Preveri') 5 $log
  if (-not $prev.ok) { $prev.ok = $true; $prev.opis = 'procesi-preveri: opozorila (glej dnevnik)' }
  $rez += $prev

  $strani = @($n.strani) + @(Get-StraniIzSprememb) | Where-Object { $_ } | Select-Object -Unique
  if ($strani.Count -and -not $BrezKlikalnika -and ($rez | Where-Object { $_.opis -like 'build*' }).ok) {
    $rez += Invoke-Klikalnik $strani $log
  } elseif ($strani.Count) { $rez += @{ ok = $true; opis = 'klikalnik: preskočen' } }

  $ok = -not ($rez | Where-Object { -not $_.ok })
  $povzetek = ($rez | ForEach-Object { $_.opis }) -join '; '
  return @{ ok = $ok; povzetek = $povzetek; log = $log }
}

function Invoke-Klikalnik([string[]]$strani, [string]$log) {
  # Klikalnik uporablja vrata 5000 — naenkrat samo en, zato ima svoj zaklep.
  $zaklep = Join-Path $Mapa '.klikalnik'
  if ((Test-Path $zaklep) -and (Get-Item $zaklep).LastWriteTime -gt (Get-Date).AddMinutes(-40)) {
    return @{ ok = $false; opis = "klikalnik: zaseden (druga seja, $([IO.File]::ReadAllText($zaklep)))" }
  }
  [IO.File]::WriteAllText($zaklep, "$Seja #$($n.id) $(Get-Cas)")
  $mapaK = Join-Path $Koren 'PIM_Solution\tools\PIM.Klikalnik'
  $gostitelj = $null
  try {
    $b = Invoke-Korak 'klikalnik-build' 'dotnet' @('build', '-c', 'Release', '-nologo', '-v', 'q') 15 $log $mapaK
    if (-not $b.ok) { return $b }
    $gostitelj = Start-Process dotnet -ArgumentList @('bin\Release\net10.0\PIM.Klikalnik.dll') -WorkingDirectory $mapaK -PassThru -WindowStyle Hidden `
      -RedirectStandardOutput "$log.gostitelj.txt" -RedirectStandardError "$log.gostitelj.err"
    $rok = (Get-Date).AddMinutes(4); $gor = $false
    while (-not $gor -and (Get-Date) -lt $rok) {
      try { $r = Invoke-WebRequest 'http://localhost:5000/brez-dostopa' -UseBasicParsing -TimeoutSec 20; $gor = ($r.StatusCode -eq 200) } catch { Start-Sleep 3 }
    }
    if (-not $gor) { return @{ ok = $false; opis = 'klikalnik: testni intranet se ni zagnal v 4 min' } }
    $k = Invoke-Korak 'klikalnik' 'node' @('klikalnik.mjs', 'http://localhost:5000/', ($strani -join ',')) 30 $log $mapaK
    $json = Join-Path $mapaK 'porocilo\klikalnik.json'
    if (Test-Path $json) {
      $najdbe = @(([IO.File]::ReadAllText($json, $Utf8) | ConvertFrom-Json) | ForEach-Object { $_.najdbe })
      $visoke = @($najdbe | Where-Object { $_.resnost -eq 'VISOKA' -and $_.vrsta -ne 'hitrost' })
      $srednje = @($najdbe | Where-Object { $_.resnost -eq 'SREDNJA' })
      Copy-Item (Join-Path $mapaK 'porocilo\klikalnik.md') "$log.klikalnik.md" -Force
      return @{ ok = ($visoke.Count -eq 0); opis = "klikalnik: $($strani.Count) strani, visokih $($visoke.Count), srednjih $($srednje.Count)" }
    }
    return @{ ok = $false; opis = "klikalnik: ni poročila ($($k.opis))" }
  } finally {
    if ($gostitelj -and -not $gostitelj.HasExited) { & taskkill /PID $gostitelj.Id /T /F 2>$null | Out-Null }
    Remove-Item $zaklep -Force -ErrorAction SilentlyContinue
  }
}

# ---------------------------------------------------------------- migracije
function Get-NaslednjaMigracija {
  $max = 0
  foreach ($d in (Get-Delo)) {
    $m = Join-Path $d.pot 'PIM_Solution\sql\migrations'
    if (Test-Path $m) {
      foreach ($f in Get-ChildItem $m -Filter *.sql) { if ($f.Name -match '^(\d{3,4})_') { $max = [Math]::Max($max, [int]$Matches[1]) } }
    }
  }
  foreach ($v in (Invoke-Git ls-tree --name-only -r main -- PIM_Solution/sql/migrations)) {
    if ((Split-Path $v -Leaf) -match '^(\d{3,4})_') { $max = [Math]::Max($max, [int]$Matches[1]) }
  }
  if (Test-Path $DatotekaMigracij) {
    foreach ($v in [IO.File]::ReadAllLines($DatotekaMigracij, $Utf8)) { if ($v -match '^(\d+)\t') { $max = [Math]::Max($max, [int]$Matches[1]) } }
  }
  return $max + 1
}

# ---------------------------------------------------------------- ukazi
switch ($Ukaz) {
  'Stanje' {
    $naloge = Get-Naloge
    foreach ($s in $Stanja) {
      $sez = @($naloge | Where-Object { $_.stanje -eq $s })
      if (-not $sez.Count -or $s -in 'koncana', 'opuscena') { continue }
      Write-Host "`n$($s.ToUpper()) ($($sez.Count))" -ForegroundColor Cyan
      foreach ($n in ($sez | Sort-Object @{ e = { @{ V = 0; S = 1; N = 2 }[$_.prednost] } }, @{ e = { [int]$_.id } })) {
        $dod = @()
        if ($n.seja -and $n.stanje -in $Aktivna) { $dod += "dela: $($n.seja)" }
        if ($n.odlocitev) { $dod += 'ČAKA ODLOČITEV' }
        if ($n.obmocje.Count) { $dod += "območje: $($n.obmocje -join ', ')" }
        Write-Host ("  #{0,-4} [{1}] {2}  {3}" -f $n.id, $n.prednost, $n.naslov, ($dod -join ' · '))
      }
    }
    $pot = Write-Pregled
    Write-Host "`nPregledna stran: $pot"
    if ($Odpri) { Start-Process $pot }
  }
  'Nova' {
    if (-not $Naslov) { throw 'Manjka -Naslov.' }
    Use-Zaklep {
      $zadnji = @(Get-ChildItem $MapaNalog -Filter *.md | ForEach-Object { [int]$_.BaseName }) | Sort-Object | Select-Object -Last 1
      $novId = [int]$zadnji + 1
      $n = [ordered]@{}
      foreach ($p in $Polja) { $n[$p] = '' }
      $n.id = $novId; $n.naslov = $Naslov; $n.stanje = 'predlog'; $n.prednost = $Prednost; $n.vrsta = $Vrsta; $n.vir = $Vir
      $n.obmocje = @($Obmocje | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }); $n.strani = @($Strani | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }); $n.testi = @($Testi | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }); $n.odvisno = $Odvisno; $n.ustvarjeno = Get-Cas
      $n.telo = "`r`n## Opis`r`n$Opis`r`n`r`n## Kriteriji sprejema`r`n- `r`n`r`n## Dnevnik`r`n"
      $n.datoteka = Join-Path $MapaNalog ('{0:D4}.md' -f $novId)
      Add-Dnevnik $n 'ustvarjena'
      Write-Naloga $n
      Write-Host "Naloga #${novId}: $($n.datoteka)"
    }
  }
  'Prevzemi' {
    Use-Zaklep {
      $n = Get-Naloga $Id
      if ($n.stanje -in $Aktivna -and $n.seja -and $n.seja -ne $Seja -and -not $Kljub) { throw "Naloga #$Id je že v delu: $($n.seja)." }
      if ($n.odlocitev -and -not $Kljub) { throw "Naloga #$Id čaka odločitev lastnika: $($n.odlocitev)" }
      foreach ($o in (Get-Naloge | Where-Object { $_.stanje -in $Aktivna -and $_.id -ne $n.id })) {
        $x = Test-Prekrivanje $n.obmocje $o.obmocje
        if ($x -and -not $Kljub) { throw "Območje se prekriva z nalogo #$($o.id) ($($o.seja)): $x. Počakaj ali se dogovori (Sporocilo)." }
      }
      foreach ($d in @($n.odvisno)) {
        $od = Get-Naloga ([int]$d)
        if ($od.stanje -notin 'pregled', 'koncana' -and -not $Kljub) { throw "Naloga #$Id je odvisna od #$d ($($od.stanje))." }
      }
      $n.stanje = 'v-delu'; $n.seja = $Seja; $n.pot = $Koren
      $n.veja = (Invoke-Git rev-parse --abbrev-ref HEAD | Select-Object -First 1)
      Add-Dnevnik $n "prevzeta v $($n.pot) (veja $($n.veja))"
      Write-Naloga $n
      if ($n.veja -eq 'main') { Write-Host 'OPOZORILO: delaš v glavni kopiji (main). Priporočeno: lastna delovna kopija (worktree).' -ForegroundColor Yellow }
      Write-Host "Prevzeta #$Id. Območje: $($n.obmocje -join ', ')"
    }
  }
  'Sprosti' {
    Use-Zaklep { $n = Get-Naloga $Id; $n.stanje = 'pripravljena'; Add-Dnevnik $n "sproščena$(if ($Besedilo) { ': ' + $Besedilo })"; Write-Naloga $n }
  }
  'Sporocilo' {
    if (-not $Besedilo) { throw 'Manjka -Besedilo.' }
    Use-Zaklep { $n = Get-Naloga $Id; Add-Dnevnik $n $Besedilo; Write-Naloga $n }
  }
  'Odlocitev' {
    Use-Zaklep {
      $n = Get-Naloga $Id
      if ($Odgovor) { Add-Dnevnik $n "ODLOČITEV: $($n.odlocitev) → $Odgovor"; $n.odlocitev = '' }
      elseif ($Besedilo) { $n.odlocitev = $Besedilo; Add-Dnevnik $n "vprašanje za lastnika: $Besedilo" }
      else { throw 'Podaj -Besedilo (vprašanje) ali -Odgovor.' }
      Write-Naloga $n
    }
  }
  'Nastavi' {
    if ($Polja -notcontains $Polje) { throw "Neznano polje $Polje." }
    Use-Zaklep {
      $n = Get-Naloga $Id
      if ($Polje -eq 'stanje' -and $Stanja -notcontains $Vrednost) { throw "Stanje mora biti eno od: $($Stanja -join ', ')" }
      if ($Seznami -contains $Polje) { $n[$Polje] = @($Vrednost -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { $n[$Polje] = $Vrednost }
      Add-Dnevnik $n "$Polje = $Vrednost"; Write-Naloga $n
    }
  }
  'Migracija' {
    if (-not $Ime) { throw 'Manjka -Ime (npr. SpletDoRazprodaje).' }
    Use-Zaklep {
      $st = Get-NaslednjaMigracija
      $datoteka = Join-Path $Koren ("PIM_Solution\sql\migrations\{0}_{1}.sql" -f $st, $Ime)
      [IO.File]::AppendAllText($DatotekaMigracij, "$st`t$Ime`t#$Id`t$Seja`t$(Get-Cas)`r`n", $Utf8)
      if (-not (Test-Path $datoteka)) { [IO.File]::WriteAllText($datoteka, "/* ${st}_$Ime — rezervirano za nalogo #$Id ($Seja, $(Get-Cas)). */`r`n", $Utf8) }
      if ($Id) { $n = Get-Naloga $Id; Add-Dnevnik $n "migracija $st rezervirana"; Write-Naloga $n }
      Write-Host "Migracija $st rezervirana: $datoteka"
    }
  }
  'Preveri' {
    Use-Zaklep { $n = Get-Naloga $Id; $n.stanje = 'preverjanje'; Add-Dnevnik $n 'vrata zagnana'; Write-Naloga $n }
    $n = Get-Naloga $Id
    try { $v = Invoke-Vrata $n }
    catch { $v = @{ ok = $false; povzetek = "vrata so se ustavila: $($_.Exception.Message)"; log = '' } }
    Use-Zaklep {
      $n = Get-Naloga $Id
      $n.stanje = 'v-delu'
      $n.preverjeno = "$(if ($v.ok) { 'OK' } else { 'NAPAKA' }) $(Get-Cas)"
      Add-Dnevnik $n "vrata $(if ($v.ok) { 'OK' } else { 'NAPAKA' }): $($v.povzetek) (dnevnik $($v.log)*)"
      Write-Naloga $n
    }
    Write-Host "`n$(if ($v.ok) { 'VRATA OK' } else { 'VRATA NISO ŠLA SKOZI' }): $($v.povzetek)" -ForegroundColor $(if ($v.ok) { 'Green' } else { 'Red' })
    if (-not $v.ok) { exit 1 }
  }
  'Koncaj' {
    Use-Zaklep {
      $n = Get-Naloga $Id
      if ($n.preverjeno -notlike 'OK*' -and -not $Kljub) { throw "Naloga #$Id nima uspešnih vrat (Preveri). Zadnje: '$($n.preverjeno)'." }
      $n.stanje = 'pregled'; Add-Dnevnik $n "oddana v pregled$(if ($Besedilo) { ': ' + $Besedilo })"; Write-Naloga $n
      Write-Host "Naloga #$Id je v pregledu."
    }
  }
  'Zdruzi' {
    $n = Get-Naloga $Id
    if ((Invoke-Git rev-parse --abbrev-ref HEAD) -ne 'main') { throw 'Združuje se samo v glavni kopiji na veji main.' }
    if (@(Invoke-Git status --porcelain).Count -and -not $Kljub) { throw 'Glavna kopija ima nepotrjene spremembe; najprej jih potrdi ali umakni.' }
    if (-not $n.veja -or $n.veja -eq 'main') { throw "Naloga #$Id nima lastne veje." }
    if ($n.preverjeno -notlike 'OK*') { throw "Naloga #$Id nima uspešnih vrat." }
    Invoke-Git merge --no-ff $n.veja -m "Združi nalogo #${Id}: $($n.naslov)" | Write-Host
    if ($GitIzhod -ne 0) { throw "Združevanje ni uspelo (konflikt?). Razreši ročno: git merge $($n.veja)." }
    Use-Zaklep { $n = Get-Naloga $Id; $n.stanje = 'koncana'; Add-Dnevnik $n "združena v main"; Write-Naloga $n }
  }
}
if ($Ukaz -ne 'Stanje') { [void](Write-Pregled) }
