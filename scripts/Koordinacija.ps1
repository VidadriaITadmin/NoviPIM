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
  -Ukaz Zdruzi      -Id: vejo naloge najprej posodobi z integracijsko vejo in jo zgradi v delovni kopiji
                    naloge, nato jo združi v integracijsko vejo glavne kopije (nastavitve.json: glavnaVeja).
  -Ukaz Nastavi     -Id -Polje -Vrednost: spremeni polje naloge (stanje, prednost, obmocje ...).
  -Ukaz Utrip       -Seja -Vloga -Id -Besedilo: agent javi, da je živ in kaj dela (nadzorna plošča).
  -Ukaz Odjava      -Seja: agent je končal (izgine s plošče agentov).
  -Ukaz Json        Stanje table kot JSON (za tokove in orodja).

  Vrata (build, testi, klikalnik) tečejo največ vrataHkrati naenkrat (privzeto 3); ostali čakajo v vrsti.
  Vsako mesto ima svoja vrata testnega intraneta (5071, 5072, ...), zato več preverjanj teče vzporedno.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\Koordinacija.ps1 -Ukaz Stanje -Odpri
  powershell -ExecutionPolicy Bypass -File scripts\Koordinacija.ps1 -Ukaz Prevzemi -Id 3 -Seja "Popravki strani"
#>
param(
  [ValidateSet('Stanje', 'Nova', 'Prevzemi', 'Sprosti', 'Sporocilo', 'Odlocitev', 'Migracija', 'Preveri', 'Koncaj', 'Zdruzi', 'Nastavi', 'Utrip', 'Odjava', 'Json', 'Kopija')]
  [string]$Ukaz = 'Stanje',
  [int]$Id,
  [string]$Seja = $env:USERNAME,
  [string]$Vloga,
  [ValidateSet('', 'predlog', 'pripravljena')][string]$Zacetno = '',
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
  # Razvojni strežnik je odvisen od računalnika (DAVID\MSSQL19, DESKTOP-TONVQHJ\MSSQLSERVER3 ...): prva
  # namestitev vzame lokalno SQL storitev; nastavitve.json je v .git, torej za vsak računalnik posebej.
  $sql = Get-Service -Name 'MSSQL$*' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running' | Select-Object -First 1
  $privzet = if ($sql) { "$env:COMPUTERNAME\$($sql.Name.Substring(6))" } else { 'DAVID\MSSQL19' }
  [IO.File]::WriteAllText($DatotekaNastavitev, (@{ razvojniStreznik = $privzet; razvojnaBaza = 'PIM' } | ConvertTo-Json), $Utf8)
}
$Nastavitve = [IO.File]::ReadAllText($DatotekaNastavitev, $Utf8) | ConvertFrom-Json
$MapaAgentov = Join-Path $Mapa 'agenti'
if (-not (Test-Path $MapaAgentov)) { New-Item -ItemType Directory -Path $MapaAgentov | Out-Null }
# Glavna kopija = mapa, v kateri je skupni .git; integracijska veja je veja, na kateri je glavna kopija
# (ali nastavitve.json: glavnaVeja). Vanjo se združujejo naloge; iz nje nastajajo delovne kopije agentov.
$Glavna = (Resolve-Path (Split-Path $Skupna -Parent)).Path
$GlavnaVeja = if ($Nastavitve.glavnaVeja) { [string]$Nastavitve.glavnaVeja } else { (& git -C $Glavna rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1) }
$VrataHkrati = if ($Nastavitve.vrataHkrati) { [int]$Nastavitve.vrataHkrati } else { 3 }

$Stanja = @('predlog', 'pripravljena', 'v-delu', 'preverjanje', 'pregled', 'koncana', 'blokirana', 'opuscena')
$Aktivna = @('v-delu', 'preverjanje')
$Polja = @('id', 'naslov', 'stanje', 'prednost', 'vrsta', 'vir', 'obmocje', 'strani', 'testi', 'odvisno',
  'odlocitev', 'seja', 'veja', 'pot', 'preverjeno', 'zdruzeno', 'ustvarjeno', 'posodobljeno')
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
    # Ustvarjen graf procesov in dnevnik baze (union merge) nista zaklep: konflikt reši Zdruzi.
    $skupne = 'docs/procesi/pim-procesi.html', 'docs/database.md', 'pim_solution/pim.sln'
    if ($skupne -contains $px -or $skupne -contains $py) { continue }
    if ($px.StartsWith('pim_solution/sql/migrations/') -or $py.StartsWith('pim_solution/sql/migrations/')) { continue }
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
# Mesto za vrata: največ $VrataHkrati hkratnih buildov/testov/klikalnikov (sicer 10 agentov zamrzne
# računalnik in SQL). Mesto K ima svoja vrata testnega intraneta 5070+K. Kdor ne dobi mesta, čaka v vrsti.
function Enter-MestoVrat([int]$minut = 45) {
  $rok = (Get-Date).AddMinutes($minut); $javljeno = $false
  while ((Get-Date) -lt $rok) {
    for ($k = 1; $k -le $VrataHkrati; $k++) {
      $pot = Join-Path $Mapa ".vrata-$k"
      if ((Test-Path $pot) -and (Get-Item $pot).LastWriteTime -lt (Get-Date).AddMinutes(-90)) { Remove-Item $pot -Force -ErrorAction SilentlyContinue }
      try {
        $tok = [IO.File]::Open($pot, 'CreateNew', 'Write', 'None')
        $b = $Utf8.GetBytes((@{ mesto = $k; seja = $Seja; id = [int]$Id; korak = 'začetek'; od = (Get-Date).ToString('s'); pot = $Koren } | ConvertTo-Json -Compress))
        $tok.Write($b, 0, $b.Length); $tok.Close()
        $script:MestoVrat = $k; $script:PotMesta = $pot
        return $k
      } catch { }
    }
    if (-not $javljeno) {
      Write-Host "  · vsa mesta za vrata ($VrataHkrati) so zasedena — čakam v vrsti ..." -ForegroundColor Yellow
      Set-Utrip "čaka v vrsti za vrata (zasedena vsa $VrataHkrati mesta)" 'čaka'
      $javljeno = $true
    }
    Start-Sleep -Seconds 10
  }
  throw "Ni prostega mesta za vrata v $minut min."
}

function Set-KorakMesta([string]$korak) {
  if (-not $script:PotMesta -or -not (Test-Path $script:PotMesta)) { return }
  $d = [IO.File]::ReadAllText($script:PotMesta, $Utf8) | ConvertFrom-Json
  $d.korak = $korak
  [IO.File]::WriteAllText($script:PotMesta, ($d | ConvertTo-Json -Compress), $Utf8)
}

function Exit-MestoVrat {
  if ($script:PotMesta) { Remove-Item $script:PotMesta -Force -ErrorAction SilentlyContinue; $script:PotMesta = $null }
}

function Get-ImeDatotekeSeje([string]$s) { return (($s -replace '[^\p{L}\p{N}]+', '-').Trim('-').ToLowerInvariant()) + '.json' }

# Utrip agenta: kdo je živ, katera naloga, katera vloga, kaj dela zdaj. Plošča ga pokaže kot »zastal«,
# če se dolgo ne oglasi. Sprememba koraka gre tudi v dnevnik (časovnica), ponovljen utrip ne.
function Set-Utrip([string]$besedilo, [string]$stanjeAgenta = 'dela') {
  $pot = Join-Path $MapaAgentov (Get-ImeDatotekeSeje $Seja)
  $prej = if (Test-Path $pot) { try { [IO.File]::ReadAllText($pot, $Utf8) | ConvertFrom-Json } catch { $null } } else { $null }
  $zacetek = if ($prej -and $prej.zacetek) { $prej.zacetek } else { (Get-Date).ToString('s') }
  $vloga = if ($Vloga) { $Vloga } elseif ($prej) { $prej.vloga } else { '' }
  $id = if ($Id) { [int]$Id } elseif ($prej) { $prej.id } else { 0 }
  $d = [ordered]@{ seja = $Seja; vloga = $vloga; id = $id; korak = $besedilo; stanje = $stanjeAgenta
    zacetek = $zacetek; utrip = (Get-Date).ToString('s'); pot = $Koren
    veja = (Invoke-Git rev-parse --abbrev-ref HEAD | Select-Object -First 1); pid = $PID }
  [IO.File]::WriteAllText($pot, ($d | ConvertTo-Json -Compress), $Utf8)
  if (-not $prej -or $prej.korak -ne $besedilo) {
    [IO.File]::AppendAllText($DatotekaDnevnika, "$(Get-Cas)`t$Seja`t#$id`t[$vloga] $besedilo`r`n", $Utf8)
  }
}


function Invoke-Korak([string]$ime, [string]$exe, [string[]]$argumenti, [int]$minut, [string]$log, [string]$mapa = $Koren) {
  Write-Host "  · $ime ..." -NoNewline
  Set-KorakMesta $ime
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
  # Strani (@page) iz spremenjenih .razor datotek proti integracijski veji.
  $spremenjene = @(Invoke-Git diff --name-only "$GlavnaVeja...HEAD") + @(Invoke-Git diff --name-only) + @(Invoke-Git ls-files --others --exclude-standard)
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
  $mesto = Enter-MestoVrat
  Write-Host "  · mesto za vrata $mesto/$VrataHkrati (testni intranet na vratih $(5070 + $mesto))"
  Set-Utrip "vrata: mesto $mesto" 'vrata'
  try { return Invoke-VrataNaMestu $n $log $mesto } finally { Exit-MestoVrat }
}

function Invoke-VrataNaMestu($n, [string]$log, [int]$mesto) {
  $rez = @()
  # Testni podatki, ki niso v gitu (fixtures, ceniki v pdf_datoteke — .gitignore), delovna kopija dobi iz glavne.
  foreach ($podmapa in 'PIM_Solution/fixtures', 'PIM_Solution/pdf_datoteke') {
    $fix = Join-Path $Koren $podmapa
    $fixGlavna = Join-Path $Glavna $podmapa
    if (-not (Test-Path $fix) -and (Test-Path $fixGlavna) -and ($fix -ne $fixGlavna)) {
      Copy-Item $fixGlavna $fix -Recurse
      Write-Host "  · $podmapa prekopirano iz glavne kopije (ni v gitu)"
    }
  }

  $rez += Invoke-Korak 'build' 'dotnet' @('build', 'PIM_Solution\PIM.sln', '-c', 'Release', '-nologo', '-v', 'q', '-nodeReuse:false') 20 $log

  foreach ($t in @($n.testi)) {
    if ($t -match 'ProductWorkbook' -and -not $Kljub) { $rez += @{ ok = $true; opis = "test ${t}: preskočen (DB del zamrzne SQL; -Kljub za zagon)" }; continue }
    $rez += Invoke-Korak "test $t" 'powershell' @('-ExecutionPolicy', 'Bypass', '-File', 'scripts\run_tests.ps1', '-Filter', $t) 25 $log
  }

  $vpliv = Invoke-Korak 'procesi-vpliv' 'powershell' @('-ExecutionPolicy', 'Bypass', '-File', 'scripts\Procesi.ps1', '-Ukaz', 'Vpliv', '-Od', $GlavnaVeja) 5 $log
  if ($vpliv.koda -eq 2) { $vpliv.opis = 'procesi-vpliv: sprememba PODRE podatek, ki ga nekdo bere' } elseif ($vpliv.koda -ne 0) { $vpliv.ok = $true; $vpliv.opis = 'procesi-vpliv: opozorila' }
  $rez += $vpliv
  $prev = Invoke-Korak 'procesi-preveri' 'powershell' @('-ExecutionPolicy', 'Bypass', '-File', 'scripts\Procesi.ps1', '-Ukaz', 'Preveri') 5 $log
  if (-not $prev.ok) { $prev.ok = $true; $prev.opis = 'procesi-preveri: opozorila (glej dnevnik)' }
  $rez += $prev

  $strani = @($n.strani) + @(Get-StraniIzSprememb) | Where-Object { $_ } | Select-Object -Unique
  if ($strani.Count -and -not $BrezKlikalnika -and ($rez | Where-Object { $_.opis -like 'build*' }).ok) {
    $rez += Invoke-Klikalnik $strani $log (5070 + $mesto)
  } elseif ($strani.Count) { $rez += @{ ok = $true; opis = 'klikalnik: preskočen' } }

  $ok = -not ($rez | Where-Object { -not $_.ok })
  $povzetek = ($rez | ForEach-Object { $_.opis }) -join '; '
  # Strojno berljiv izid za nadzorno ploščo (koraki, dnevniki, posnetki).
  $izid = [ordered]@{ id = [int]$n.id; seja = $Seja; ok = $ok; cas = (Get-Date).ToString('s'); pot = $Koren; mesto = $mesto
    koraki = @($rez | ForEach-Object { [ordered]@{ ok = [bool]$_.ok; opis = $_.opis; izhod = $_.izhod } }) }
  [IO.File]::WriteAllText("$log.json", ($izid | ConvertTo-Json -Depth 5), $Utf8)
  return @{ ok = $ok; povzetek = $povzetek; log = $log }
}

function Get-KlikalnikPovzetek($pregledane) {
  # Povzetek poročila klikalnika za vrata. Počasne strani (najdbe vrste 'hitrost', nad 15 s) se štejejo
  # posebej in izpišejo z imenom strani in časom; vrat ne zaprejo, ker je počasnost lahko od druge naloge
  # (PRIVZETO ZA NOČ #64, odločitev lastnika v ločeni nalogi). Vrata zapre samo visoka najdba druge vrste.
  $pregledane = @($pregledane | ForEach-Object { $_ } | Where-Object { $_ })
  $najdbe = @($pregledane | ForEach-Object { @($_.najdbe) } | Where-Object { $_ })
  $visoke = @($najdbe | Where-Object { $_.resnost -eq 'VISOKA' -and $_.vrsta -ne 'hitrost' })
  $srednje = @($najdbe | Where-Object { $_.resnost -eq 'SREDNJA' -and $_.vrsta -ne 'hitrost' })
  $pocasne = @($pregledane | Where-Object { @(@($_.najdbe) | Where-Object { $_ -and $_.vrsta -eq 'hitrost' }).Count -gt 0 } | ForEach-Object {
    $ms = 0; if ($_.cas -and $_.cas.nalaganjeMs) { $ms = [double]$_.cas.nalaganjeMs }
    $zelo = @(@($_.najdbe) | Where-Object { $_ -and $_.vrsta -eq 'hitrost' -and $_.resnost -eq 'VISOKA' }).Count -gt 0
    "$($_.pot) $([Math]::Round($ms / 1000)) s$(if ($zelo) { ', zelo počasna' })"
  })
  $opis = "klikalnik: $($pregledane.Count) strani, visokih $($visoke.Count), srednjih $($srednje.Count)"
  if ($pocasne.Count -gt 0) { $opis += ", počasnih $($pocasne.Count) ($($pocasne -join '; '))" }
  return @{ ok = ($visoke.Count -eq 0); opis = $opis; visokih = $visoke.Count; srednjih = $srednje.Count; pocasnih = $pocasne.Count }
}

function Invoke-Klikalnik([string[]]$strani, [string]$log, [int]$vrata) {
  # Vsako mesto za vrata ima svoja vrata testnega intraneta, zato klikalnikov teče več hkrati.
  $mapaK = Join-Path $Koren 'PIM_Solution\tools\PIM.Klikalnik'
  $izhodK = "$log-klikalnik"
  $gostitelj = $null
  $env:KLIKALNIK_PORT = "$vrata"
  $env:KLIKALNIK_STREZNIK = [string]$Nastavitve.razvojniStreznik
  $env:KLIKALNIK_IZHOD = $izhodK
  try {
    $b = Invoke-Korak 'klikalnik-build' 'dotnet' @('build', '-c', 'Release', '-nologo', '-v', 'q', '-nodeReuse:false') 15 $log $mapaK
    if (-not $b.ok) { return $b }
    Set-KorakMesta 'klikalnik-zagon'
    $gostitelj = Start-Process dotnet -ArgumentList @('bin\Release\net10.0\PIM.Klikalnik.dll') -WorkingDirectory $mapaK -PassThru -WindowStyle Hidden `
      -RedirectStandardOutput "$log.gostitelj.txt" -RedirectStandardError "$log.gostitelj.err"
    $rok = (Get-Date).AddMinutes(4); $gor = $false
    while (-not $gor -and (Get-Date) -lt $rok) {
      try { $r = Invoke-WebRequest "http://localhost:$vrata/brez-dostopa" -UseBasicParsing -TimeoutSec 20; $gor = ($r.StatusCode -eq 200) } catch { Start-Sleep 3 }
    }
    if (-not $gor) { return @{ ok = $false; opis = "klikalnik: testni intranet se ni zagnal v 4 min (vrata $vrata)" } }
    $k = Invoke-Korak 'klikalnik' 'node' @('klikalnik.mjs', "http://localhost:$vrata/", ($strani -join ',')) 30 $log $mapaK
    $json = Join-Path $izhodK 'klikalnik.json'
    if (Test-Path $json) {
      # PS5: ConvertFrom-Json da seznam kot EN objekt; ForEach ga razgrne (sicer je Count vedno 1, tudi pri []).
      $pregledane = @([IO.File]::ReadAllText($json, $Utf8) | ConvertFrom-Json | ForEach-Object { $_ })
      # Brez tega so vrata rekla OK, čeprav klikalnik ni odprl niti ene strani (ime strani ne ustreza @page).
      if ($pregledane.Count -eq 0) {
        return @{ ok = $false; opis = "klikalnik: pregledal 0 strani — nobena od '$($strani -join ', ')' ne ustreza @page v intranetu"; izhod = "$log.klikalnik.txt" }
      }
      $pov = Get-KlikalnikPovzetek $pregledane
      Copy-Item (Join-Path $izhodK 'klikalnik.md') "$log.klikalnik.md" -Force
      return @{ ok = $pov.ok; opis = $pov.opis; izhod = "$log.klikalnik.md" }
    }
    return @{ ok = $false; opis = "klikalnik: ni poročila ($($k.opis))" }
  } finally {
    if ($gostitelj -and -not $gostitelj.HasExited) { & taskkill /PID $gostitelj.Id /T /F 2>$null | Out-Null }
    Remove-Item Env:KLIKALNIK_PORT, Env:KLIKALNIK_IZHOD, Env:KLIKALNIK_STREZNIK -ErrorAction SilentlyContinue
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
  foreach ($v in (Invoke-Git ls-tree --name-only -r $GlavnaVeja -- PIM_Solution/sql/migrations)) {
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
      $n.id = $novId; $n.naslov = $Naslov; $n.stanje = $(if ($Zacetno) { $Zacetno } else { 'predlog' }); $n.prednost = $Prednost; $n.vrsta = $Vrsta; $n.vir = $Vir
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
      if ($Koren -eq $Glavna) { Write-Host 'OPOZORILO: delaš v glavni kopiji. Priporočeno: lastna delovna kopija (worktree).' -ForegroundColor Yellow }
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
    Set-Utrip "vrata $(if ($v.ok) { 'OK' } else { 'NAPAKA' }): $($v.povzetek)" 'dela'
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
    if (-not $n.veja -or $n.veja -eq $GlavnaVeja) { throw "Naloga #$Id nima lastne veje (veja '$($n.veja)')." }
    if ($n.preverjeno -notlike 'OK*' -and -not $Kljub) { throw "Naloga #$Id nima uspešnih vrat." }
    if ($n.stanje -ne 'pregled' -and -not $Kljub) { throw "Naloga #$Id ni sprejeta (stanje $($n.stanje)); združi se po Koncaj." }
    $potNaloge = if ($n.pot -and (Test-Path $n.pot)) { (Resolve-Path $n.pot).Path } else { $null }
    if (-not $potNaloge) { throw "Delovna kopija naloge #$Id ne obstaja več ($($n.pot))." }
    if ((& git -C $Glavna rev-parse --abbrev-ref HEAD 2>$null) -ne $GlavnaVeja) { throw "Glavna kopija ni na integracijski veji $GlavnaVeja." }

    # Naenkrat se združuje samo ena naloga (vrsta združevanja).
    $zaklepZ = Join-Path $Mapa '.zdruzevanje'
    $rok = (Get-Date).AddMinutes(30); $tok = $null
    while (-not $tok) {
      try { $tok = [IO.File]::Open($zaklepZ, 'CreateNew', 'Write', 'None'); $tok.Close() }
      catch {
        if ((Get-Item $zaklepZ -ErrorAction SilentlyContinue).LastWriteTime -lt (Get-Date).AddMinutes(-60)) { Remove-Item $zaklepZ -Force; continue }
        if ((Get-Date) -gt $rok) { throw 'Vrsta združevanja je zasedena več kot 30 min.' }
        Set-Utrip "čaka v vrsti za združevanje #$Id" 'čaka'; Start-Sleep -Seconds 10
      }
    }
    $Koren = $potNaloge
    try {
      Set-Utrip "združujem #$Id v $GlavnaVeja" 'zdruzuje'
      # Testni podatki, ki jih je prepisala starejša Kopija, niso delo naloge: vrni jih na stanje iz gita.
      & git -C $potNaloge checkout -- PIM_Solution/fixtures 2>$null
      if (@(& git -C $potNaloge status --porcelain --untracked-files=no 2>$null).Count) { throw "Naloga #$Id ima nepotrjene spremembe v $potNaloge — najprej commit." }
      # 1) Veja naloge dobi vse, kar je medtem prišlo v integracijsko vejo, in se ponovno zgradi.
      $pred = & git -C $potNaloge rev-parse HEAD
      $ErrorActionPreference = 'Continue'
      & git -C $potNaloge merge --no-edit $GlavnaVeja 2>&1 | Write-Host
      $izhodMerge = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
      if ($izhodMerge -ne 0) {
        $konf = @(& git -C $potNaloge diff --name-only --diff-filter=U 2>$null)
        # Graf procesov je ustvarjen iz docs/procesi/*.md: konflikt v njem se reši s ponovnim Graf, ne ročno.
        if ($konf.Count -eq 1 -and $konf[0] -eq 'docs/procesi/PIM-procesi.html') {
          $ErrorActionPreference = 'Continue'
          & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $potNaloge 'scripts\Procesi.ps1') -Ukaz Graf 2>&1 | Out-Null
          & git -C $potNaloge add -- docs/procesi/PIM-procesi.html 2>&1 | Out-Null
          & git -C $potNaloge commit --no-edit 2>&1 | Write-Host
          $izhodMerge = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
          if ($izhodMerge -eq 0) { Use-Zaklep { $n = Get-Naloga $Id; Add-Dnevnik $n "združevanje: konflikt v grafu procesov rešen s ponovnim Procesi.ps1 -Ukaz Graf"; Write-Naloga $n }; $konf = @() }
        }
      }
      if ($izhodMerge -ne 0) {
        & git -C $potNaloge merge --abort 2>$null
        Use-Zaklep { $n = Get-Naloga $Id; $n.stanje = 'blokirana'; Add-Dnevnik $n "združevanje: konflikt z $GlavnaVeja v $($konf -join ', ') — razvijalec mora vejo posodobiti ročno"; Write-Naloga $n }
        throw "Konflikt z $GlavnaVeja ($($konf -join ', '))."
      }
      if ((& git -C $potNaloge rev-parse HEAD) -ne $pred) {
        $log = Join-Path $MapaPreverjanj ("{0:D4}-{1}-zdruzi" -f [int]$Id, (Get-Date).ToString('yyyyMMdd-HHmmss'))
        [void](Enter-MestoVrat)
        try { $b = Invoke-Korak 'build po posodobitvi' 'dotnet' @('build', 'PIM_Solution\PIM.sln', '-c', 'Release', '-nologo', '-v', 'q', '-nodeReuse:false') 20 $log $potNaloge }
        finally { Exit-MestoVrat }
        if (-not $b.ok) {
          Use-Zaklep { $n = Get-Naloga $Id; $n.stanje = 'blokirana'; Add-Dnevnik $n "združevanje: po posodobitvi z $GlavnaVeja build ne gre skozi ($($b.izhod))"; Write-Naloga $n }
          throw 'Build po posodobitvi ni uspel.'
        }
      }
      # 2) Združitev v glavno kopijo (git zavrne, če so iste datoteke tam nepotrjeno spremenjene).
      $ErrorActionPreference = 'Continue'
      & git -C $Glavna merge --no-ff $n.veja -m "Združi nalogo #${Id}: $($n.naslov)" 2>&1 | Write-Host
      $izhodMerge = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
      if ($izhodMerge -ne 0) {
        & git -C $Glavna merge --abort 2>$null
        Use-Zaklep { $n = Get-Naloga $Id; Add-Dnevnik $n "združevanje v glavno kopijo ni uspelo (nepotrjene spremembe v istih datotekah?) — poskusi znova"; Write-Naloga $n }
        throw 'Združevanje v glavno kopijo ni uspelo.'
      }
      $commit = (& git -C $Glavna rev-parse --short HEAD)
      Use-Zaklep { $n = Get-Naloga $Id; $n.stanje = 'koncana'; $n.zdruzeno = "$commit $(Get-Cas)"; Add-Dnevnik $n "združena v $GlavnaVeja ($commit)"; Write-Naloga $n }
      Set-Utrip "#$Id združena v $GlavnaVeja ($commit)" 'končal'
      # Kopija, ki jo je naredila tabla (-Ukaz Kopija), po združitvi ni več potrebna.
      $mapaKopij = Join-Path $Glavna '.claude\worktrees'
      if ($potNaloge -ne $Glavna -and $potNaloge.StartsWith($mapaKopij, [StringComparison]::OrdinalIgnoreCase) -and
          -not @(& git -C $potNaloge status --porcelain 2>$null).Count) {
        # Pospravljanje ni del združitve: kopija je lahko v rabi (odprta mapa, tekoč proces) — takrat ostane.
        $ErrorActionPreference = 'Continue'
        & git -C $Glavna worktree remove $potNaloge 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "Delovna kopija $potNaloge pospravljena." } else { Write-Host "Delovna kopija $potNaloge ostane (v rabi)." }
        $ErrorActionPreference = 'Stop'
      }
      Write-Host "Naloga #$Id združena v $GlavnaVeja ($commit)." -ForegroundColor Green
    } finally { Remove-Item $zaklepZ -Force -ErrorAction SilentlyContinue }
  }
  'Kopija' {
    # Delovna kopija naloge iz INTEGRACIJSKE veje (ne iz main, ki je lahko prazen GitHub začetek).
    # Agenti delajo v njej prek cd; varovalka samodejnih kopij bi jim prepovedala zagon table.
    $pot = Join-Path $Glavna ".claude\worktrees\naloga-$Id"
    if (Test-Path (Join-Path $pot '.git')) { Write-Host "Kopija že obstaja."; Write-Output $pot; return }
    $veja = "naloga/$Id"
    & git -C $Glavna show-ref --verify --quiet "refs/heads/$veja"
    if ($LASTEXITCODE -eq 0) {
      # Obstoječa veja brez skupnega prednika z integracijsko vejo (npr. iz praznega main) ni uporabna.
      $mb = & git -C $Glavna merge-base $GlavnaVeja $veja 2>$null
      if (-not $mb) {
        $k = 2
        while ($true) { & git -C $Glavna show-ref --verify --quiet "refs/heads/$veja-$k"; if ($LASTEXITCODE -ne 0) { break }; $k++ }
        $veja = "$veja-$k"
      }
    }
    $ErrorActionPreference = 'Continue'
    & git -C $Glavna show-ref --verify --quiet "refs/heads/$veja"
    if ($LASTEXITCODE -eq 0) { & git -C $Glavna worktree add $pot $veja 2>&1 | Write-Host }
    else { & git -C $Glavna worktree add -b $veja $pot $GlavnaVeja 2>&1 | Write-Host }
    $ErrorActionPreference = 'Stop'
    if (-not (Test-Path (Join-Path $pot '.git'))) { throw "Kopije $pot ni bilo mogoče ustvariti." }
    foreach ($podmapa in 'PIM_Solution/fixtures', 'PIM_Solution/pdf_datoteke') {
      $fixGlavna = Join-Path $Glavna $podmapa
      # Samo, če je v kopiji ni: fixtures so (od 4f73b7b) v gitu; prepis bi kopijo »umazal« (konci vrstic) in Zdruzi bi jo zavrnil.
      if ((Test-Path $fixGlavna) -and -not (Test-Path (Join-Path $pot $podmapa))) { Copy-Item $fixGlavna (Split-Path (Join-Path $pot $podmapa) -Parent) -Recurse }
    }
    $potKopije = $pot  # Use-Zaklep ima svoj $pot (datoteka zaklepa)
    if ($Id) { Use-Zaklep { $n = Get-Naloga $Id; Add-Dnevnik $n "delovna kopija $potKopije (veja $veja iz $GlavnaVeja)"; Write-Naloga $n } }
    Write-Output $pot
    return
  }
  'Utrip' {
    if (-not $Besedilo) { throw 'Manjka -Besedilo (kaj agent dela zdaj).' }
    Set-Utrip $Besedilo 'dela'
    return
  }
  'Odjava' {
    $pot = Join-Path $MapaAgentov (Get-ImeDatotekeSeje $Seja)
    if (Test-Path $pot) {
      $d = [IO.File]::ReadAllText($pot, $Utf8) | ConvertFrom-Json
      [IO.File]::AppendAllText($DatotekaDnevnika, "$(Get-Cas)`t$Seja`t#$($d.id)`t[$($d.vloga)] odjava$(if ($Besedilo) { ': ' + $Besedilo })`r`n", $Utf8)
      Remove-Item $pot -Force
    }
    return
  }
  'Json' {
    $izid = [ordered]@{ glavna = $Glavna; glavnaVeja = $GlavnaVeja; vrataHkrati = $VrataHkrati
      naloge = @(Get-Naloge | ForEach-Object { $o = [ordered]@{}; foreach ($k in $_.Keys) { if ($k -ne 'telo') { $o[$k] = $_[$k] } }; $o }) }
    [Console]::Out.Write(($izid | ConvertTo-Json -Depth 5))
    return
  }
}
if ($Ukaz -notin 'Stanje', 'Utrip', 'Odjava', 'Json') { [void](Write-Pregled) }
