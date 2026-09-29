<#
.SYNOPSIS
  Promet na SAOP spletnih mestih v IIS (SaopApi, SaopApiTest): kdo klice, kaj, kdaj in kako hitro.

.DESCRIPTION
  Zaganja se NA STREZNIKU IQ-SAOP, kot administrator.

  1. Prebere IIS dnevnike (W3C) izbranih spletnih mest za zadnjih -Ure ur in napise porocilo:
     klicatelji (IP + ime racunalnika + uporabnik + program), aplikacije (iCenterAPI, iCenterSync ...),
     najpogostejsi klici, statusi, napake, najpocasnejsi klici, promet po urah.
  2. Z -Zivo dodatno -Sekund sekund opazuje odprte povezave na portih teh mest. Za klice s tega
     istega streznika pove tudi, KATERI PROCES klice (npr. w3wp PIM_prd_pool, PIM worker, SAOP servis).

  Rezultat: C:\Temp\SAOP-promet\porocilo_*.txt (+ zahteve_*.csv z vsemi vrsticami za Excel).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File SAOP-promet.ps1
  powershell -ExecutionPolicy Bypass -File SAOP-promet.ps1 -Ure 2 -Zivo -Sekund 300
  powershell -ExecutionPolicy Bypass -File SAOP-promet.ps1 -Spletna SaopApi -Ure 168
#>
[CmdletBinding()]
param(
    [string[]]$Spletna = @('SaopApi', 'SaopApiTest'),
    [double]$Ure = 24,
    [string]$Izhod = 'C:\Temp\SAOP-promet',
    [switch]$Zivo,
    [int]$Sekund = 120,
    [int]$Interval = 2,
    [int]$Top = 30,
    [int]$PocasiMs = 5000,
    [switch]$BrezDns,
    [switch]$BrezCsv,
    [switch]$NeOdpri,
    # Samo za preizkus: namesto IIS nastavitev beri dnevnike iz te mape (vsaka podmapa = eno mesto).
    [string]$MapaDnevnikov
)

$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture
$stoparica = [Diagnostics.Stopwatch]::StartNew()

class Stat {
    [long]$N = 0
    [long]$Napake = 0
    [double]$SumMs = 0
    [long]$MaxMs = 0
    [long]$Bajti = 0
    [datetime]$Prva = [datetime]::MaxValue
    [datetime]$Zadnja = [datetime]::MinValue
    [hashtable]$Poti = @{}
    [hashtable]$Mesta = @{}

    [void] Dodaj([datetime]$t, [long]$ms, [bool]$napaka, [long]$bajti, [string]$pot, [string]$mesto) {
        $this.N++
        if ($napaka) { $this.Napake++ }
        $this.SumMs += $ms
        if ($ms -gt $this.MaxMs) { $this.MaxMs = $ms }
        $this.Bajti += $bajti
        if ($t -lt $this.Prva) { $this.Prva = $t }
        if ($t -gt $this.Zadnja) { $this.Zadnja = $t }
        if ($pot) { $this.Poti[$pot] = 1 + [long]$this.Poti[$pot] }
        if ($mesto) { $this.Mesta[$mesto] = 1 + [long]$this.Mesta[$mesto] }
    }
}

function Get-Stat([hashtable]$tabela, [string]$kljuc) {
    $s = $tabela[$kljuc]
    if ($null -eq $s) { $s = [Stat]::new(); $tabela[$kljuc] = $s }
    return $s
}

# ---------------------------------------------------------------- priprava
$jeAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $jeAdmin) { Write-Warning 'Skripta ni zagnana kot administrator - dnevnikov IIS morda ne bo mogoce brati.' }

New-Item -ItemType Directory -Force -Path $Izhod | Out-Null
$zig = Get-Date -Format 'yyyyMMdd_HHmm'
$potPorocila = Join-Path $Izhod "porocilo_$zig.txt"
$potCsv = Join-Path $Izhod "zahteve_$zig.csv"
$out = New-Object System.Collections.Generic.List[string]
$opozorila = New-Object System.Collections.Generic.List[string]
function Pisi([string]$t = '') { $out.Add($t); Write-Host $t }
function Tabela([string]$naslov, $vrstice) {
    Pisi ''
    Pisi "=== $naslov ==="
    if (-not $vrstice) { Pisi '(ni podatkov)'; return }
    $txt = ($vrstice | Format-Table -AutoSize | Out-String -Width 400).TrimEnd()
    foreach ($l in $txt -split "`r?`n") { Pisi $l }
}

# Lastni IP naslovi - klici z njih prihajajo s tega streznika.
$lastniIp = @{ '127.0.0.1' = 1; '::1' = 1 }
try { Get-NetIPAddress -ErrorAction Stop | ForEach-Object { $lastniIp[($_.IPAddress -replace '%\d+$', '')] = 1 } } catch { }

# Spletna mesta: ime, id, porti, mape dnevnikov.
$mesta = @()
if ($MapaDnevnikov) {
    foreach ($d in Get-ChildItem -Path $MapaDnevnikov -Directory) {
        $mesta += [pscustomobject]@{ Ime = $d.Name; Id = 0; Porti = @(); Mape = @($d.FullName); Centralno = $false }
    }
}
else {
    Import-Module WebAdministration
    foreach ($ime in $Spletna) {
        $s = Get-Website -Name $ime
        if (-not $s) { $opozorila.Add("Spletnega mesta '$ime' ni v IIS."); continue }
        $porti = @($s.bindings.Collection | ForEach-Object { [int](($_.bindingInformation -split ':')[1]) } | Sort-Object -Unique)
        $koren = [Environment]::ExpandEnvironmentVariables($s.logFile.directory)
        $mapa = Join-Path $koren "W3SVC$($s.id)"
        $centralno = $false
        if (-not (Test-Path $mapa)) {
            # Centralno W3C belezenje: vsa mesta v eni mapi, loci jih polje s-sitename.
            $mapa = Join-Path $koren 'W3SVC'
            $centralno = $true
        }
        if ($s.logFile.enabled -eq $false) { $opozorila.Add("Mesto '$ime': belezenje v IIS je IZKLOPLJENO (IIS Manager > $ime > Logging > Enable).") }
        $mesta += [pscustomobject]@{ Ime = $ime; Id = [int]$s.id; Porti = $porti; Mape = @($mapa); Centralno = $centralno }
    }
    # IIS pise dnevnike z zamikom do 1 min - izprazni medpomnilnik, da so zraven tudi zadnji klici.
    try { & netsh http flush logbuffer | Out-Null } catch { }
}
if (-not $mesta) { throw 'Ni nobenega spletnega mesta za pregled.' }

Pisi "PROMET NA SAOP SPLETNIH MESTIH - $env:COMPUTERNAME"
Pisi ("Ustvarjeno: {0:dd.MM.yyyy HH:mm}   Obdobje: zadnjih {1} ur   Mesta: {2}" -f (Get-Date), $Ure, (($mesta | ForEach-Object { "$($_.Ime) (port $($_.Porti -join ','))" }) -join ', '))

# ---------------------------------------------------------------- branje dnevnikov
$odUtc = (Get-Date).ToUniversalTime().AddHours(-$Ure)
$poKlicatelju = @{}; $poIp = @{}; $poAplikaciji = @{}; $poKlicu = @{}; $poStatusu = @{}; $poUri = @{}; $poUporabniku = @{}
$napake = New-Object System.Collections.Generic.List[object]
$pocasni = New-Object System.Collections.Generic.List[object]
$manjkajocaPolja = @{}
$skupaj = 0
$reGuid = [regex]'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$reSt = [regex]'/\d+(?=/|$)'

$csv = $null
if (-not $BrezCsv) {
    $csv = New-Object System.IO.StreamWriter($potCsv, $false, (New-Object System.Text.UTF8Encoding($true)))
    $csv.WriteLine('Cas;Mesto;IP;Uporabnik;Metoda;Pot;Poizvedba;Status;Ms;Bajti;Program')
}
function CsvPolje([string]$v) { if ($v -match '[;"]') { return '"' + $v.Replace('"', '""') + '"' } return $v }

foreach ($m in $mesta) {
    $datoteke = @()
    foreach ($mapa in $m.Mape) {
        if (Test-Path $mapa) { $datoteke += Get-ChildItem -Path $mapa -Filter '*.log' -File | Where-Object { $_.LastWriteTimeUtc -ge $odUtc } }
        else { $opozorila.Add("Mesto '$($m.Ime)': mape z dnevniki ni ($mapa).") }
    }
    Write-Host ("Berem {0}: {1} datotek ..." -f $m.Ime, $datoteke.Count)
    $siteKoda = "W3SVC$($m.Id)"

    foreach ($f in ($datoteke | Sort-Object Name)) {
        $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')   # IIS ima datoteko odprto
        $sr = New-Object System.IO.StreamReader($fs)
        $idx = $null
        try {
            while ($null -ne ($vr = $sr.ReadLine())) {
                if ($vr.Length -eq 0) { continue }
                if ($vr[0] -eq '#') {
                    if ($vr.StartsWith('#Fields:')) {
                        $polja = $vr.Substring(8).Trim().Split(' ')
                        $idx = @{}
                        for ($i = 0; $i -lt $polja.Count; $i++) { $idx[$polja[$i]] = $i }
                        $nPolj = $polja.Count
                        foreach ($p in 'c-ip', 'cs-username', 'cs(User-Agent)', 'time-taken', 'sc-bytes', 'cs-uri-query') {
                            if (-not $idx.ContainsKey($p)) { $manjkajocaPolja["$($m.Ime): $p"] = 1 }
                        }
                        $iD = $idx['date']; $iT = $idx['time']
                        $iIp = if ($idx.ContainsKey('c-ip')) { $idx['c-ip'] } else { -1 }
                        $iUp = if ($idx.ContainsKey('cs-username')) { $idx['cs-username'] } else { -1 }
                        $iUa = if ($idx.ContainsKey('cs(User-Agent)')) { $idx['cs(User-Agent)'] } else { -1 }
                        $iMs = if ($idx.ContainsKey('time-taken')) { $idx['time-taken'] } else { -1 }
                        $iB = if ($idx.ContainsKey('sc-bytes')) { $idx['sc-bytes'] } else { -1 }
                        $iQ = if ($idx.ContainsKey('cs-uri-query')) { $idx['cs-uri-query'] } else { -1 }
                        $iSub = if ($idx.ContainsKey('sc-substatus')) { $idx['sc-substatus'] } else { -1 }
                        $iSite = if ($idx.ContainsKey('s-sitename')) { $idx['s-sitename'] } else { -1 }
                        $iMet = $idx['cs-method']; $iStem = $idx['cs-uri-stem']; $iSt = $idx['sc-status']
                    }
                    continue
                }
                if ($null -eq $idx) { continue }
                $p = $vr.Split(' ')
                if ($p.Count -ne $nPolj) { continue }
                if ($m.Centralno -and $iSite -ge 0 -and $p[$iSite] -ne $siteKoda) { continue }

                $tUtc = [datetime]::ParseExact($p[$iD] + ' ' + $p[$iT], 'yyyy-MM-dd HH:mm:ss', $inv,
                    [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
                if ($tUtc -lt $odUtc) { continue }
                $t = $tUtc.ToLocalTime()

                $ip = if ($iIp -ge 0) { $p[$iIp] } else { '?' }
                $up = if ($iUp -ge 0) { $p[$iUp] } else { '-' }
                $ua = if ($iUa -ge 0) { $p[$iUa].Replace('+', ' ') } else { '-' }
                $ms = if ($iMs -ge 0) { [long]$p[$iMs] } else { 0 }
                $b = if ($iB -ge 0) { [long]$p[$iB] } else { 0 }
                $q = if ($iQ -ge 0) { $p[$iQ] } else { '-' }
                $status = $p[$iSt]
                if ($iSub -ge 0 -and $p[$iSub] -ne '0') { $status = "$status.$($p[$iSub])" }
                $napaka = ([int]$p[$iSt]) -ge 400
                $stem = $p[$iStem]
                $seg = $stem.Split('/')
                $apl = if ($seg.Count -gt 2) { '/' + $seg[1] } else { '/' }
                $norm = $reSt.Replace($reGuid.Replace($stem, '{guid}'), '/{st}')
                $klic = "$($p[$iMet]) $norm"

                (Get-Stat $poKlicatelju "$ip`t$up`t$ua").Dodaj($t, $ms, $napaka, $b, $klic, $m.Ime)
                (Get-Stat $poIp $ip).Dodaj($t, $ms, $napaka, $b, $null, $m.Ime)
                (Get-Stat $poUporabniku $up).Dodaj($t, $ms, $napaka, $b, $null, $m.Ime)
                (Get-Stat $poAplikaciji "$($m.Ime) $apl").Dodaj($t, $ms, $napaka, $b, $null, $null)
                (Get-Stat $poKlicu "$($m.Ime)`t$klic").Dodaj($t, $ms, $napaka, $b, $ip, $null)
                (Get-Stat $poStatusu $status).Dodaj($t, $ms, $napaka, $b, $null, $m.Ime)
                (Get-Stat $poUri $t.ToString('yyyy-MM-dd HH')).Dodaj($t, $ms, $napaka, $b, $null, $m.Ime)
                $skupaj++

                if ($napaka -or $ms -ge $PocasiMs) {
                    $o = [pscustomobject]@{ Cas = $t.ToString('dd.MM. HH:mm:ss'); Mesto = $m.Ime; IP = $ip; Uporabnik = $up; Status = $status; Ms = $ms; Klic = "$($p[$iMet]) $stem"; Poizvedba = $q }
                    if ($napaka) { $napake.Add($o); if ($napake.Count -gt 2000) { $napake.RemoveAt(0) } }
                    if ($ms -ge $PocasiMs) { $pocasni.Add($o) }
                }
                if ($csv) {
                    $csv.WriteLine(($t.ToString('yyyy-MM-dd HH:mm:ss'), $m.Ime, $ip, $up, $p[$iMet], (CsvPolje $stem), (CsvPolje $q), $status, $ms, $b, (CsvPolje $ua)) -join ';')
                }
            }
        }
        finally { $sr.Dispose() }
    }
}
if ($csv) { $csv.Dispose() }

# ---------------------------------------------------------------- imena racunalnikov
$dnsIme = @{}
function Ime-Ip([string]$ip) {
    if ($dnsIme.ContainsKey($ip)) { return $dnsIme[$ip] }
    $ime = ''
    if ($lastniIp.ContainsKey($ip)) { $ime = "TA STREZNIK ($env:COMPUTERNAME)" }
    elseif (-not $BrezDns -and $ip -ne '?') {
        try { $ime = [System.Net.Dns]::GetHostEntry($ip).HostName } catch { $ime = '(ime ni znano)' }
    }
    $dnsIme[$ip] = $ime
    return $ime
}

function Vrstice([hashtable]$tabela, [scriptblock]$kljuc, [int]$n = $Top) {
    $tabela.GetEnumerator() | Sort-Object { $_.Value.N } -Descending | Select-Object -First $n | ForEach-Object {
        $s = $_.Value
        $o = & $kljuc $_.Key $s
        $o | Add-Member -NotePropertyMembers ([ordered]@{
                Zahtev    = $s.N
                Napak     = $s.Napake
                'Povp ms' = [math]::Round($s.SumMs / [math]::Max($s.N, 1))
                'Max ms'  = $s.MaxMs
                MB        = [math]::Round($s.Bajti / 1MB, 1)
                Prva      = $s.Prva.ToString('dd.MM. HH:mm')
                Zadnja    = $s.Zadnja.ToString('dd.MM. HH:mm')
            }) -PassThru
    }
}
function Kratko([string]$v, [int]$n) { if ($v.Length -gt $n) { return $v.Substring(0, $n - 3) + '...' } return $v }

# ---------------------------------------------------------------- porocilo
Pisi ''
Pisi ("Skupaj zahtev: {0:N0}" -f $skupaj)
if ($manjkajocaPolja.Count) {
    $opozorila.Add('V dnevnikih manjkajo polja: ' + (($manjkajocaPolja.Keys | Sort-Object) -join ', ') +
        '. Vklop: IIS Manager > mesto > Logging > Select Fields (Client IP, User Name, User Agent, Time Taken, Bytes Sent, URI Query).')
}
foreach ($o in $opozorila) { Pisi "OPOZORILO: $o" }

Tabela 'KDO KLICE - racunalniki (IP)' (Vrstice $poIp { param($k, $s) [pscustomobject][ordered]@{ IP = $k; Racunalnik = (Ime-Ip $k); Mesta = (($s.Mesta.Keys | Sort-Object) -join ',') } })
Tabela 'KDO KLICE - uporabniki (prijava v API)' (Vrstice $poUporabniku { param($k, $s) [pscustomobject][ordered]@{ Uporabnik = $k; Mesta = (($s.Mesta.Keys | Sort-Object) -join ',') } })
Tabela 'APLIKACIJE (iCenterAPI, iCenterSync ...)' (Vrstice $poAplikaciji { param($k, $s) [pscustomobject][ordered]@{ Aplikacija = $k } } 100)
Tabela 'NAJPOGOSTEJSI KLICI (stevilke v poti zamenjane z {st})' (Vrstice $poKlicu { param($k, $s)
        $d = $k -split "`t"
        $ipji = ($s.Poti.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { $_.Key }) -join ','
        [pscustomobject][ordered]@{ Mesto = $d[0]; Klic = (Kratko $d[1] 90); 'Glavni IP' = $ipji } })
Tabela 'STATUSI (2xx ok, 401/403 prijava, 404 ni najdeno, 5xx napaka streznika)' (Vrstice $poStatusu { param($k, $s) [pscustomobject][ordered]@{ Status = $k } } 100)

Pisi ''
Pisi '=== KLICATELJI PODROBNO (IP + uporabnik + program) in njihovi klici ==='
foreach ($e in ($poKlicatelju.GetEnumerator() | Sort-Object { $_.Value.N } -Descending | Select-Object -First $Top)) {
    $d = $e.Key -split "`t"; $s = $e.Value
    Pisi ''
    Pisi ("--- {0} [{1}]  uporabnik: {2}" -f $d[0], (Ime-Ip $d[0]), $d[1])
    Pisi ("    program: {0}" -f (Kratko $d[2] 150))
    Pisi ("    zahtev: {0:N0}  napak: {1:N0}  povp: {2} ms  max: {3} ms  od {4:dd.MM. HH:mm} do {5:dd.MM. HH:mm}  mesta: {6}" -f `
            $s.N, $s.Napake, [math]::Round($s.SumMs / [math]::Max($s.N, 1)), $s.MaxMs, $s.Prva, $s.Zadnja, (($s.Mesta.Keys | Sort-Object) -join ','))
    foreach ($k in ($s.Poti.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10)) {
        Pisi ("      {0,8:N0} x  {1}" -f $k.Value, (Kratko $k.Key 120))
    }
}

Pisi ''
Pisi '=== PROMET PO URAH ==='
$maxUra = ($poUri.Values | Measure-Object -Property N -Maximum).Maximum
foreach ($e in ($poUri.GetEnumerator() | Sort-Object Key)) {
    $dol = if ($maxUra) { [int][math]::Ceiling(50 * $e.Value.N / $maxUra) } else { 0 }
    Pisi ("{0}h  {1,8:N0}  napak {2,6:N0}  {3}" -f $e.Key, $e.Value.N, $e.Value.Napake, ('#' * $dol))
}

Tabela "NAJPOCASNEJSI KLICI (>= $PocasiMs ms)" ($pocasni | Sort-Object Ms -Descending | Select-Object -First $Top Cas, Mesto, IP, Uporabnik, Status, Ms, @{ n = 'Klic'; e = { Kratko $_.Klic 80 } }, @{ n = 'Poizvedba'; e = { Kratko $_.Poizvedba 60 } })
Tabela 'ZADNJE NAPAKE (status >= 400)' ($napake | Select-Object -Last 50 Cas, Mesto, IP, Uporabnik, Status, Ms, @{ n = 'Klic'; e = { Kratko $_.Klic 80 } }, @{ n = 'Poizvedba'; e = { Kratko $_.Poizvedba 60 } })

# ---------------------------------------------------------------- zivo opazovanje povezav
if ($Zivo) {
    $portMesto = @{}
    foreach ($m in $mesta) { foreach ($pt in $m.Porti) { $portMesto[$pt] = $m.Ime } }
    $procOpis = @{}
    function Opis-Procesa([int]$procId) {
        if ($procOpis.ContainsKey($procId)) { return $procOpis[$procId] }
        $opis = "PID $procId"
        try {
            $pr = Get-CimInstance Win32_Process -Filter "ProcessId=$procId"
            if ($pr) {
                $opis = $pr.Name
                if ($pr.Name -eq 'w3wp.exe' -and $pr.CommandLine -match '-ap "([^"]+)"') { $opis = "w3wp (IIS pool $($Matches[1]))" }
                elseif ($pr.CommandLine) { $opis = "$($pr.Name)  $(Kratko ($pr.CommandLine -replace '^"[^"]+"\s*|^\S+\s*', '') 80)" }
                try { $own = Invoke-CimMethod -InputObject $pr -MethodName GetOwner; if ($own.User) { $opis += "  [kot $($own.Domain)\$($own.User)]" } } catch { }
            }
        }
        catch { }
        $procOpis[$procId] = $opis
        return $opis
    }

    $appcmd = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'
    $povezave = @{}; $zahteve = @{}
    $konec = (Get-Date).AddSeconds($Sekund)
    $vzorcev = 0
    while ((Get-Date) -lt $konec) {
        $vzorcev++
        Write-Progress -Activity 'Opazujem povezave na SAOP mesta' -Status ("se {0:N0} s" -f ($konec - (Get-Date)).TotalSeconds) -PercentComplete ([math]::Min(100, 100 * $vzorcev * $Interval / [math]::Max($Sekund, 1)))
        $vse = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue)
        foreach ($c in $vse) {
            if (-not $portMesto.ContainsKey([int]$c.LocalPort)) { continue }
            $rip = $c.RemoteAddress -replace '^::ffff:', ''
            $proces = ''
            if ($lastniIp.ContainsKey($rip)) {
                # Klic s tega streznika: poisci drugo stran povezave in njen proces.
                $druga = $vse | Where-Object { $_.LocalPort -eq $c.RemotePort -and $_.RemotePort -eq $c.LocalPort } | Select-Object -First 1
                if ($druga) { $proces = Opis-Procesa $druga.OwningProcess }
            }
            $k = "$($portMesto[[int]$c.LocalPort])`t$rip`t$proces"
            $z = $povezave[$k]
            if (-not $z) { $z = @{ Prvic = Get-Date; Zadnjic = Get-Date; Vzorcev = 0; Porti = @{} }; $povezave[$k] = $z }
            $z.Zadnjic = Get-Date; $z.Vzorcev++; $z.Porti[$c.RemotePort] = 1
        }
        if (Test-Path $appcmd) {
            foreach ($m in $mesta) {
                try {
                    foreach ($l in (& $appcmd list requests "/site.name:$($m.Ime)" 2>$null)) {
                        if ($l -match '^REQUEST "([^"]+)" \((.*)\)$' -and -not $zahteve.ContainsKey($Matches[1])) {
                            $zahteve[$Matches[1]] = "{0:HH:mm:ss}  {1,-12} {2}" -f (Get-Date), $m.Ime, $Matches[2]
                        }
                    }
                }
                catch { }
            }
        }
        Start-Sleep -Seconds $Interval
    }
    Write-Progress -Activity 'Opazujem povezave na SAOP mesta' -Completed

    Tabela "ZIVO: ODPRTE POVEZAVE v $Sekund s (vzorec vsakih $Interval s)" ($povezave.GetEnumerator() | Sort-Object { $_.Value.Vzorcev } -Descending | ForEach-Object {
            $d = $_.Key -split "`t"
            [pscustomobject][ordered]@{
                Mesto       = $d[0]
                IP          = $d[1]
                Racunalnik  = (Ime-Ip $d[1])
                'Proces (ce klice ta streznik)' = $d[2]
                Povezav     = $_.Value.Porti.Count
                'Videno x'  = $_.Value.Vzorcev
                Prvic       = $_.Value.Prvic.ToString('HH:mm:ss')
                Zadnjic     = $_.Value.Zadnjic.ToString('HH:mm:ss')
            } })
    Pisi ''
    Pisi '=== ZIVO: ZAHTEVE, KI SO SE IZVAJALE MED OPAZOVANJEM (appcmd list requests; vidi samo daljse klice) ==='
    if ($zahteve.Count) { foreach ($v in ($zahteve.Values | Sort-Object)) { Pisi $v } } else { Pisi '(nobene - ali ni daljsih klicev ali IIS funkcija Request Monitor ni namescena)' }
}

Pisi ''
Pisi ('Trajanje skripte: {0:N0} s' -f $stoparica.Elapsed.TotalSeconds)
$out | Out-File -FilePath $potPorocila -Encoding UTF8
Write-Host ''
Write-Host "Porocilo: $potPorocila" -ForegroundColor Green
if (-not $BrezCsv) { Write-Host "Vse vrstice (Excel): $potCsv" -ForegroundColor Green }
if (-not $NeOdpri) { Start-Process notepad.exe $potPorocila }
