<#
.SYNOPSIS
  Glavni graf procesov PIM in opozorila o vplivu sprememb.

.DESCRIPTION
  Bere strojne glave (--- ... ---) vseh procesov v docs\procesi\NN-*\*.md.
  Procesi so povezani prek podatkov: kar en proces zapiše (pise), drug bere (bere).

  -Ukaz Graf    Sestavi docs\procesi\PIM-procesi.html (pregledovalnik z glavnim grafom,
                odvisnostmi in vplivom) iz predloge _pregledovalnik.html in vseh procesov.
  -Ukaz Vpliv   Iz git sprememb (delovna kopija proti -Od, privzeto HEAD) izračuna,
                katere procese sprememba zadane, na katere vpliva naprej in ali kaj
                PODRE (podatek, ki ga nekdo bere, nihče več ne piše) ali OBOGATI.
                Izhodna koda 2, če je kaj podrtega.
  -Ukaz Preveri Samo opozorila skladnosti (neznane oznake, zastarele poti kode,
                strani intraneta brez procesa). Izhodna koda 1, če so opozorila.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\Procesi.ps1 -Ukaz Graf
  powershell -ExecutionPolicy Bypass -File scripts\Procesi.ps1 -Ukaz Vpliv -Od origin/main
#>
param(
  [ValidateSet('Graf', 'Vpliv', 'Preveri')]
  [string]$Ukaz = 'Graf',
  [string]$Od = 'HEAD',
  [string[]]$Datoteke
)

$ErrorActionPreference = 'Stop'
$Koren = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$MapaProcesov = Join-Path $Koren 'docs\procesi'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8

function Invoke-Git {
  # git piše napake na stderr; v PS 5.1 bi to ob Stop sprožilo izjemo
  $ErrorActionPreference = 'Continue'
  $izhod = & git -C $Koren @args 2>$null
  $script:GitIzhod = $LASTEXITCODE
  return $izhod
}

# Zunanji sistemi: podatki s temi predponami niso povezave med procesi PIM.
$Zunanji = [ordered]@{
  'saop.'       = @{ Id = 'X_SAOP'; Naziv = 'SAOP ERP' }
  'dobavitelj.' = @{ Id = 'X_DOB';  Naziv = 'Dobavitelji XML' }
  'excel.'      = @{ Id = 'X_XLS';  Naziv = 'Excel uporabnika' }
  'splet.'      = @{ Id = 'X_WEB';  Naziv = 'Splet / Magento' }
  'obvestila'   = @{ Id = 'X_MAIL'; Naziv = 'E-pošta' }
}

function Get-Zunanji([string]$oznaka) {
  foreach ($k in $Zunanji.Keys) { if ($oznaka.StartsWith($k)) { return $Zunanji[$k] } }
  return $null
}

function ConvertFrom-Glava([string[]]$vrstice) {
  $g = @{}
  if ($vrstice.Count -lt 2 -or $vrstice[0].Trim() -ne '---') { return $null }
  for ($i = 1; $i -lt $vrstice.Count; $i++) {
    $v = $vrstice[$i]
    if ($v.Trim() -eq '---') { break }
    $v = ($v -replace '\s+#.*$', '').TrimEnd()
    if ($v -notmatch '^\s*([A-Za-z_]+)\s*:\s*(.*)$') { continue }
    $kljuc = $Matches[1]; $vr = $Matches[2].Trim()
    if ($vr.StartsWith('[')) {
      $notranje = $vr.Trim('[', ']').Trim()
      $g[$kljuc] = @(if ($notranje) { $notranje -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ } })
    } else {
      $g[$kljuc] = $vr.Trim('"', "'")
    }
  }
  foreach ($k in 'bere', 'pise', 'strani', 'posli', 'koda', 'migracije') { if (-not $g.ContainsKey($k)) { $g[$k] = @() } }
  return $g
}

function Read-Procesi([scriptblock]$beri) {
  # $beri: vrne vrstice datoteke (relativna pot) - omogoča branje stare različice iz gita
  $izid = [ordered]@{}
  $poti = Get-ChildItem $MapaProcesov -Directory | Where-Object { $_.Name -match '^\d\d-' } |
    ForEach-Object { Get-ChildItem $_.FullName -Filter *.md -Recurse } |
    Where-Object { -not $_.Name.StartsWith('_') }
  foreach ($f in $poti) {
    $rel = $f.FullName.Substring($Koren.Length + 1).Replace('\', '/')
    $vrstice = & $beri $rel
    if (-not $vrstice) { continue }
    $g = ConvertFrom-Glava $vrstice
    if (-not $g) { $g = @{ bere = @(); pise = @(); strani = @(); posli = @(); koda = @(); migracije = @(); BrezGlave = $true } }
    if (-not $g.id) { $g.id = [IO.Path]::GetFileNameWithoutExtension($f.Name) }
    if (-not $g.naslov) { $g.naslov = $g.id }
    $g.podrocje = $f.Directory.Name
    if ($f.Directory.Parent.FullName -ne $MapaProcesov) { $g.podrocje = $f.Directory.Parent.Name }
    $g.pot = $rel
    $izid[$g.id] = $g
  }
  return $izid
}

function Read-Trenutno([string]$rel) {
  $p = Join-Path $Koren $rel
  if (Test-Path $p) { return [IO.File]::ReadAllLines($p, $Utf8) }
}

function Read-Slovar {
  $p = Join-Path $MapaProcesov '_PODATKI.md'
  $s = @{}
  if (Test-Path $p) {
    foreach ($v in [IO.File]::ReadAllLines($p, $Utf8)) {
      if ($v -match '^\|\s*`([^`]+)`\s*\|\s*([^|]+)\|') { $s[$Matches[1]] = $Matches[2].Trim() }
    }
  }
  return $s
}

function Get-Indeks($procesi) {
  $pisci0 = @{}; $bere = @{}
  foreach ($p in $procesi.Values) {
    foreach ($o in $p.pise) { if (-not $pisci0[$o]) { $pisci0[$o] = New-Object System.Collections.ArrayList }; [void]$pisci0[$o].Add($p.id) }
    foreach ($o in $p.bere) { if (-not $bere[$o]) { $bere[$o] = New-Object System.Collections.ArrayList }; [void]$bere[$o].Add($p.id) }
  }
  return @{ Pise = $pisci0; Bere = $bere }
}

# Neposredne povezave proces -> proces prek skupnih podatkov (tudi prek zunanjih sistemov).
function Get-Nasledniki($procesi, $indeks, [string]$id) {
  $n = [ordered]@{}
  foreach ($o in $procesi[$id].pise) {
    foreach ($b in @($indeks.Bere[$o])) {
      if ($b -and $b -ne $id) { if (-not $n[$b]) { $n[$b] = New-Object System.Collections.ArrayList }; [void]$n[$b].Add($o) }
    }
  }
  return $n
}

function Get-Predhodniki($procesi, $indeks, [string]$id) {
  $n = [ordered]@{}
  foreach ($o in $procesi[$id].bere) {
    foreach ($w in @($indeks.Pise[$o])) {
      if ($w -and $w -ne $id) { if (-not $n[$w]) { $n[$w] = New-Object System.Collections.ArrayList }; [void]$n[$w].Add($o) }
    }
  }
  return $n
}

function Get-Vse-Datoteke-Repo {
  $izhod = Invoke-Git ls-files
  $izhod += Invoke-Git ls-files --others --exclude-standard
  return @($izhod | Where-Object { $_ })
}

function Test-KodaUjema([string]$vzorec, [string]$pot) {
  $vz = $vzorec.Replace('\', '/').TrimStart('/')
  if ($vz.EndsWith('/')) { return $pot.StartsWith($vz, [StringComparison]::OrdinalIgnoreCase) }
  return $pot -like $vz
}

function Get-Opozorila($procesi, $indeks, $slovar) {
  $op = New-Object System.Collections.ArrayList
  foreach ($p in $procesi.Values) {
    if ($p.BrezGlave) { [void]$op.Add("Proces ``$($p.pot)`` nima strojne glave.") }
    foreach ($o in @($p.bere + $p.pise)) {
      if ($slovar.Count -and -not $slovar.ContainsKey($o)) { [void]$op.Add("``$($p.id)``: oznaka ``$o`` ni v _PODATKI.md.") }
    }
  }
  foreach ($o in $indeks.Bere.Keys) {
    if (-not $indeks.Pise[$o] -and -not (Get-Zunanji $o)) {
      [void]$op.Add("Podatek ``$o`` berejo $(Format-Seznam $indeks.Bere[$o]), piše ga pa noben proces.")
    }
  }
  foreach ($o in $indeks.Pise.Keys) {
    if (-not $indeks.Bere[$o] -and -not (Get-Zunanji $o)) {
      [void]$op.Add("Podatek ``$o`` piše $(Format-Seznam $indeks.Pise[$o]), bere ga pa noben proces.")
    }
  }
  # Zastarele poti kode
  $repo = Get-Vse-Datoteke-Repo
  if ($repo.Count) {
    foreach ($p in $procesi.Values) {
      foreach ($k in $p.koda) {
        $vz = $k.Replace('\', '/').TrimStart('/'); if ($vz.EndsWith('/')) { $vz += '*' }
        if (-not @($repo -like $vz).Count) {
          [void]$op.Add("``$($p.id)``: pot kode ``$k`` ne ustreza nobeni datoteki (zastarelo?).")
        }
      }
    }
  }
  # Strani intraneta brez procesa
  $strani = @{}
  foreach ($p in $procesi.Values) { foreach ($s in $p.strani) { $strani[(Get-NormPot $s)] = $true } }
  $razor = Get-ChildItem (Join-Path $Koren 'PIM_Solution\src') -Filter *.razor -Recurse -ErrorAction SilentlyContinue
  $izpusti = @('/', '/error', '/prijava', '/brez-dostopa')
  foreach ($r in $razor) {
    foreach ($m in [regex]::Matches([IO.File]::ReadAllText($r.FullName, $Utf8), '@page\s+"([^"]+)"')) {
      $pot = Get-NormPot $m.Groups[1].Value
      if ($izpusti -contains $pot) { continue }
      if (-not $strani.ContainsKey($pot)) { [void]$op.Add("Stran ``$pot`` ($($r.Name)) ni opisana v nobenem procesu.") }
    }
  }
  return ($op | Sort-Object -Unique)
}

function Get-NormPot([string]$s) {
  $s = $s.Trim().ToLowerInvariant()
  $s = $s -replace '\{[^}]+\}', '{}'
  if (-not $s.StartsWith('/')) { $s = '/' + $s }
  return $s.TrimEnd('/') -replace '^$', '/'
}

function Format-Seznam($s) { return ((@($s) | Where-Object { $_ } | ForEach-Object { '`' + $_ + '`' }) -join ', ') }

function Write-Pregledovalnik($procesi) {
  # PIM-procesi.html = predloga _pregledovalnik.html + vgrajeni podatki; deluje z dvoklikom, brez strežnika.
  $datoteke = @(foreach ($p in $procesi.Values) {
    [ordered]@{ pot = $p.pot.Substring('docs/procesi/'.Length); vsebina = [IO.File]::ReadAllText((Join-Path $Koren $p.pot), $Utf8) }
  })
  $podatki = [ordered]@{
    ustvarjeno = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    slovar     = [IO.File]::ReadAllText((Join-Path $MapaProcesov '_PODATKI.md'), $Utf8)
    kopito     = [IO.File]::ReadAllText((Join-Path $MapaProcesov '_KOPITO.md'), $Utf8)
    datoteke   = $datoteke
  }
  # JSON znotraj <script>: '</' ne sme prekiniti oznake
  $json = (ConvertTo-Json -InputObject $podatki -Depth 5 -Compress).Replace('</', '<\/')
  $predloga = [IO.File]::ReadAllText((Join-Path $MapaProcesov '_pregledovalnik.html'), $Utf8)
  $vsebina = $predloga.Replace('/*PODATKI*/', 'window.PROCESI_PODATKI = ' + $json + ';')
  $cilj = Join-Path $MapaProcesov 'PIM-procesi.html'
  [IO.File]::WriteAllText($cilj, $vsebina, $Utf8)
  Write-Host "Zapisano: $cilj"
}

function Get-Spremenjene {
  if ($Datoteke) { return @($Datoteke | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().Replace('\', '/') } | Where-Object { $_ }) }
  $s = @(Invoke-Git diff --name-only $Od)
  $s += @(Invoke-Git ls-files --others --exclude-standard)
  return @($s | Where-Object { $_ } | Sort-Object -Unique)
}

function Invoke-Vpliv {
  $zdaj = Read-Procesi ${function:Read-Trenutno}
  $prej = Read-Procesi { param($rel) $t = Invoke-Git show "${Od}:$rel"; if ($script:GitIzhod -eq 0) { $t } }
  $iZdaj = Get-Indeks $zdaj
  $iPrej = Get-Indeks $prej
  $spremenjene = Get-Spremenjene

  $zadeti = [ordered]@{}   # id -> razlogi
  $nepokrito = New-Object System.Collections.ArrayList
  foreach ($d in $spremenjene) {
    if ($d -like 'docs/procesi/*') {
      $p = $zdaj.Values | Where-Object { $_.pot -eq $d } | Select-Object -First 1
      if ($p) { $zadeti[$p.id] = @($zadeti[$p.id]) + "spremenjen opis procesa" | Where-Object { $_ } }
      continue
    }
    $ujema = $false
    foreach ($p in $zdaj.Values) {
      $mig = if ($d -match 'sql/migrations/(\d+)_') { $Matches[1] } else { $null }
      $zadane = ($p.koda | Where-Object { Test-KodaUjema $_ $d } | Select-Object -First 1) -or ($mig -and ($p.migracije | Where-Object { [int]$_ -eq [int]$mig }))
      if ($zadane) { $ujema = $true; $zadeti[$p.id] = @($zadeti[$p.id]) + "koda: $d" | Where-Object { $_ } }
    }
    if (-not $ujema -and $d -match '\.(cs|razor|sql|ps1)$') { [void]$nepokrito.Add($d) }
  }

  $podre = New-Object System.Collections.ArrayList
  $obogati = New-Object System.Collections.ArrayList
  $pozor = New-Object System.Collections.ArrayList
  # Brez izhodišča (v -Od še ni opisov procesov) primerjava opisov nima smisla.
  $primerjaj = if ($prej.Count) { @($zdaj.Keys) + @($prej.Keys) | Sort-Object -Unique } else { @() }
  foreach ($id in $primerjaj) {
    $n = $zdaj[$id]; $s = $prej[$id]
    $nPise = if ($n) { @($n.pise) } else { @() }; $sPise = if ($s) { @($s.pise) } else { @() }
    $nBere = if ($n) { @($n.bere) } else { @() }; $sBere = if ($s) { @($s.bere) } else { @() }
    if ($n -and -not $s) {
      # Nov proces: ne primerjamo po oznakah, samo povemo, kaj prinese in česa mu manjka.
      $bralci = @($nPise | ForEach-Object { @($iZdaj.Bere[$_]) } | Where-Object { $_ -and $_ -ne $id } | Sort-Object -Unique)
      [void]$obogati.Add("NOV PROCES ``$id`` ($($n.naslov)): piše $(Format-Seznam $nPise)" + $(if ($bralci) { "; uporabljajo ga $(Format-Seznam $bralci)" } else { '' }))
      foreach ($ob in $nBere) {
        if (-not (Get-Zunanji $ob) -and -not @($iZdaj.Pise[$ob] | Where-Object { $_ -and $_ -ne $id }).Count) { [void]$pozor.Add("Nov proces ``$id`` bere ``$ob``, ki ga ne piše noben drug proces.") }
      }
      continue
    }
    if ($s -and -not $n) {
      foreach ($ob in $sPise) {
        $bralci = @($iZdaj.Bere[$ob]) | Where-Object { $_ }
        if ($bralci -and -not @($iZdaj.Pise[$ob] | Where-Object { $_ }).Count -and -not (Get-Zunanji $ob)) { [void]$podre.Add("Odstranjen proces ``$id`` je edini pisal ``$ob``, bere ga pa $(Format-Seznam $bralci).") }
      }
      [void]$pozor.Add("ODSTRANJEN PROCES ``$id``")
      continue
    }
    foreach ($ob in $sPise | Where-Object { $nPise -notcontains $_ }) {
      $bralci = @($iZdaj.Bere[$ob]) | Where-Object { $_ -and $_ -ne $id }
      $pisci = @($iZdaj.Pise[$ob]) | Where-Object { $_ }
      if ($bralci -and -not $pisci -and -not (Get-Zunanji $ob)) {
        [void]$podre.Add("``$id`` ne piše več ``$ob``, bere pa ga $(Format-Seznam $bralci) - nihče drug ga ne piše.")
      } elseif ($bralci) {
        [void]$pozor.Add("``$id`` ne piše več ``$ob``; še ga piše $(Format-Seznam $pisci); bere $(Format-Seznam $bralci).")
      }
    }
    foreach ($ob in $nPise | Where-Object { $sPise -notcontains $_ }) {
      $bralci = @($iZdaj.Bere[$ob]) | Where-Object { $_ -and $_ -ne $id }
      $txt = "``$id`` na novo piše ``$ob``"
      if ($bralci) { [void]$pozor.Add("$txt - spremeni vhod za $(Format-Seznam $bralci).") } else { [void]$obogati.Add("$txt (nihče ga še ne bere).") }
      if (-not (Get-Zunanji $ob) -and @($iPrej.Pise[$ob] | Where-Object { $_ }).Count) { [void]$pozor.Add("``$ob`` ima zdaj več piscev: $(Format-Seznam @($iZdaj.Pise[$ob])) - kdo ima prednost?") }
    }
    foreach ($ob in $nBere | Where-Object { $sBere -notcontains $_ }) {
      if (-not @($iZdaj.Pise[$ob] | Where-Object { $_ }).Count -and -not (Get-Zunanji $ob)) { [void]$podre.Add("``$id`` na novo bere ``$ob``, ki ga ne piše noben proces.") }
      else { [void]$obogati.Add("``$id`` na novo uporablja ``$ob``.") }
    }
    if ($n -and $s -and $n.stanje -ne $s.stanje) { [void]$pozor.Add("``$id``: stanje $($s.stanje) → $($n.stanje)") }
  }

  # Vpliv naprej (do 3 koraki)
  $naprej = [ordered]@{}
  foreach ($id in $zadeti.Keys) {
    $vrsta = New-Object System.Collections.Queue; $vrsta.Enqueue(@($id, 0)); $videno = @{ $id = $true }
    while ($vrsta.Count) {
      $x = $vrsta.Dequeue()
      if ($x[1] -ge 2) { continue }
      $nn = Get-Nasledniki $zdaj $iZdaj $x[0]
      foreach ($b in $nn.Keys) {
        if ($videno[$b]) { continue }; $videno[$b] = $true
        $naprej["$id|$b"] = "$($x[1] + 1)|$(($nn[$b] | Sort-Object -Unique) -join ', ')"
        $vrsta.Enqueue(@($b, ($x[1] + 1)))
      }
    }
  }

  Write-Host ''
  Write-Host "VPLIV SPREMEMB (proti $Od, $($spremenjene.Count) spremenjenih datotek)" -ForegroundColor Cyan
  Write-Host ''
  if (-not $prej.Count) { Write-Host "V $Od še ni opisov procesov - primerjam samo kodo s procesi." -ForegroundColor DarkGray; Write-Host '' }
  if ($podre.Count) { Write-Host 'PODRE:' -ForegroundColor Red; $podre | ForEach-Object { Write-Host "  ✖ $_" -ForegroundColor Red }; Write-Host '' }
  if ($pozor.Count) { Write-Host 'POZOR:' -ForegroundColor Yellow; $pozor | ForEach-Object { Write-Host "  ! $_" -ForegroundColor Yellow }; Write-Host '' }
  if ($obogati.Count) { Write-Host 'OBOGATI:' -ForegroundColor Green; $obogati | ForEach-Object { Write-Host "  + $_" -ForegroundColor Green }; Write-Host '' }
  if ($zadeti.Count) {
    Write-Host 'ZADETI PROCESI (preveri, ali je opis še resničen):' -ForegroundColor Cyan
    foreach ($id in $zadeti.Keys) {
      $naslov = if ($zdaj[$id]) { $zdaj[$id].naslov } else { $id }
      Write-Host "  • $naslov ($id)"
      $zadeti[$id] | Select-Object -Unique -First 5 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
      $posredni = New-Object System.Collections.ArrayList
      foreach ($k in $naprej.Keys | Where-Object { $_.StartsWith("$id|") }) {
        $b = $k.Split('|')[1]; $v = $naprej[$k].Split('|', 2)
        if ($v[0] -eq '1') { Write-Host "      → neposredno vpliva na $($zdaj[$b].naslov) ($b) prek $($v[1])" }
        else { [void]$posredni.Add($b) }
      }
      if ($posredni.Count) { Write-Host "      ⋯ posredno še $($posredni.Count): $($posredni -join ', ')" -ForegroundColor DarkGray }
    }
    Write-Host ''
  }
  if ($nepokrito.Count) {
    Write-Host 'NEPOKRITO (spremenjena koda, ki je ne opisuje noben proces):' -ForegroundColor Magenta
    $nepokrito | ForEach-Object { Write-Host "  ? $_" -ForegroundColor Magenta }
    Write-Host ''
  }
  if (-not ($podre.Count + $pozor.Count + $obogati.Count + $zadeti.Count + $nepokrito.Count)) { Write-Host 'Sprememba ne zadane nobenega procesa.' }
  if ($podre.Count) { exit 2 }
}

switch ($Ukaz) {
  'Graf' {
    $procesi = Read-Procesi ${function:Read-Trenutno}
    Write-Pregledovalnik $procesi
    $op = Get-Opozorila $procesi (Get-Indeks $procesi) (Read-Slovar)
    Write-Host "$($procesi.Count) procesov, $(@($op).Count) opozoril skladnosti (podrobno: -Ukaz Preveri)."
  }
  'Preveri' {
    $procesi = Read-Procesi ${function:Read-Trenutno}
    $op = Get-Opozorila $procesi (Get-Indeks $procesi) (Read-Slovar)
    if (@($op).Count) { $op | ForEach-Object { Write-Host "⚠ $_" -ForegroundColor Yellow }; exit 1 }
    Write-Host 'Ni opozoril.'
  }
  'Vpliv' { Invoke-Vpliv }
}
