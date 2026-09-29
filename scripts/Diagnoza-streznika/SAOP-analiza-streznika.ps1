<#
.SYNOPSIS
  Analiza streznika IQ-SAOP v eni datoteki: KDO in KOLIKOKRAT klice SAOP API (IIS SaopApi / SaopApiTest)
  in OD KOD prihaja Python skripta, ki klice SAOP API (api/V2/Price ...).

.DESCRIPTION
  Zaganja se NA STREZNIKU IQ-SAOP, v PowerShellu "Run as administrator". Nicesar ne spreminja, samo bere.
  Navodila: NAVODILA.md (ista mapa).

  -Kaj Promet  (1. del) Prebere IIS dnevnike SAOP spletnih mest za zadnjih -Ure ur:
               klicatelji (IP + ime racunalnika + uporabnik + program), aplikacije (iCenterAPI, iCenterSync ...),
               najpogostejsi klici, statusi, napake, najpocasnejsi klici, promet po urah.
               Z -Zivo dodatno -Sekund sekund opazuje odprte povezave; za klice s tega streznika pove PROCES.
               Rezultat: porocilo_*.txt + zahteve_*.csv (vse vrstice, za Excel).
  -Kaj Python  (2. del) Namestitve Pythona, python procesi, opravila v Task Schedulerju, storitve,
               samodejni zagon, datoteke skript z omembo SAOP API, dnevniki dogodkov (kdo je kaj namestil).
               Z -Ujemi N caka N minut in ujame proces, ki odpre povezavo na port 81/82.
               Rezultat: python_izvor_*.txt
  -Kaj Vse     (privzeto) oba dela zapored.

  Vsi rezultati gredo v -Izhod (privzeto C:\Temp\SAOP-promet) in se na koncu odprejo v Notepadu.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File SAOP-analiza-streznika.ps1
  powershell -ExecutionPolicy Bypass -File SAOP-analiza-streznika.ps1 -Kaj Promet -Ure 2 -Zivo -Sekund 300
  powershell -ExecutionPolicy Bypass -File SAOP-analiza-streznika.ps1 -Kaj Promet -Spletna SaopApi -Ure 168
  powershell -ExecutionPolicy Bypass -File SAOP-analiza-streznika.ps1 -Kaj Python -Ujemi 10
#>
[CmdletBinding()]
param(
    [ValidateSet('Vse', 'Promet', 'Python')]
    [string]$Kaj = 'Vse',
    [string]$Izhod = 'C:\Temp\SAOP-promet',
    [switch]$NeOdpri,

    # --- Promet (IIS dnevniki)
    [string[]]$Spletna = @('SaopApi', 'SaopApiTest'),
    [double]$Ure = 24,
    [switch]$Zivo,
    [int]$Sekund = 120,
    [int]$Interval = 2,
    [int]$Top = 30,
    [int]$PocasiMs = 5000,
    [switch]$BrezDns,
    [switch]$BrezCsv,
    # Samo za preizkus: namesto IIS nastavitev beri dnevnike iz te mape (vsaka podmapa = eno mesto).
    [string]$MapaDnevnikov,

    # --- Python (izvor skripte)
    # Minute cakanja na zagon skripte (0 = ne cakaj). Zazeni npr. ob :54 z -Ujemi 10.
    [int]$Ujemi = 0,
    # Porti SAOP API (SaopApi = 81, SaopApiTest = 82).
    [int[]]$Porti = @(81, 82),
    # Kje iskati datoteke skript. Privzeto vsi lokalni diski.
    [string[]]$Poti,
    [string]$Vzorec = 'iCenterAPI|V2/Price|registeredviews|GetItemDeliveryDate|:81/|:82/|priceListID',
    [int]$DniDogodkov = 365
)

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

# =====================================================================================================
# 1. DEL - PROMET NA SAOP SPLETNIH MESTIH (kdo klice, kaj, kdaj, kako hitro)
# =====================================================================================================
function Analiza-Promet {
    $ErrorActionPreference = 'Stop'
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $stoparica = [Diagnostics.Stopwatch]::StartNew()

    function Get-Stat([hashtable]$tabela, [string]$kljuc) {
        $s = $tabela[$kljuc]
        if ($null -eq $s) { $s = [Stat]::new(); $tabela[$kljuc] = $s }
        return $s
    }

    # ------------------------------------------------------------ priprava
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

    # ------------------------------------------------------------ branje dnevnikov
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

    # ------------------------------------------------------------ imena racunalnikov
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

    # ------------------------------------------------------------ porocilo
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

    # ------------------------------------------------------------ zivo opazovanje povezav
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
                    Mesto                           = $d[0]
                    IP                              = $d[1]
                    Racunalnik                      = (Ime-Ip $d[1])
                    'Proces (ce klice ta streznik)' = $d[2]
                    Povezav                         = $_.Value.Porti.Count
                    'Videno x'                      = $_.Value.Vzorcev
                    Prvic                           = $_.Value.Prvic.ToString('HH:mm:ss')
                    Zadnjic                         = $_.Value.Zadnjic.ToString('HH:mm:ss')
                } })
        Pisi ''
        Pisi '=== ZIVO: ZAHTEVE, KI SO SE IZVAJALE MED OPAZOVANJEM (appcmd list requests; vidi samo daljse klice) ==='
        if ($zahteve.Count) { foreach ($v in ($zahteve.Values | Sort-Object)) { Pisi $v } } else { Pisi '(nobene - ali ni daljsih klicev ali IIS funkcija Request Monitor ni namescena)' }
    }

    Pisi ''
    Pisi ('Trajanje: {0:N0} s' -f $stoparica.Elapsed.TotalSeconds)
    $out | Out-File -FilePath $potPorocila -Encoding UTF8
    Write-Host ''
    Write-Host "Porocilo: $potPorocila" -ForegroundColor Green
    if (-not $BrezCsv) { Write-Host "Vse vrstice (Excel): $potCsv" -ForegroundColor Green }
    if (-not $NeOdpri) { Start-Process notepad.exe $potPorocila }
}

# =====================================================================================================
# 2. DEL - IZVOR PYTHON SKRIPTE, KI KLICE SAOP API (kje je, kdo jo je namestil, kdo jo zaganja)
# =====================================================================================================
function Analiza-Python {
    $ErrorActionPreference = 'Continue'
    $stoparica = [Diagnostics.Stopwatch]::StartNew()
    New-Item -ItemType Directory -Force -Path $Izhod | Out-Null
    $potPorocila = Join-Path $Izhod ("python_izvor_{0:yyyyMMdd_HHmm}.txt" -f (Get-Date))
    $out = New-Object System.Collections.Generic.List[string]
    function Pisi([string]$t = '') { $out.Add($t); Write-Host $t }
    function Naslov([string]$t) { Pisi ''; Pisi ('=' * 100); Pisi "== $t"; Pisi ('=' * 100) }
    function Tabela($vrstice) {
        if (-not $vrstice) { Pisi '(nic najdenega)'; return }
        $txt = ($vrstice | Format-List | Out-String -Width 400).Trim()
        foreach ($l in $txt -split "`r?`n") { Pisi $l }
    }
    function Lastnik([string]$pot) { try { (Get-Acl -LiteralPath $pot).Owner } catch { '?' } }

    $jeAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Pisi "IZVOR PYTHON SKRIPTE, KI KLICE SAOP API - $env:COMPUTERNAME"
    Pisi ("Ustvarjeno: {0:dd.MM.yyyy HH:mm}   Administrator: {1}" -f (Get-Date), $jeAdmin)
    if (-not $jeAdmin) { Pisi 'OPOZORILO: brez administratorja ne vidim opravil drugih uporabnikov, varnostnega dnevnika in tujih procesov.' }

    # ------------------------------------------------------------ procesi (skupno)
    $vsiProcesi = @{}
    try { Get-CimInstance Win32_Process | ForEach-Object { $vsiProcesi[[int]$_.ProcessId] = $_ } } catch { }
    function Opis-Procesa($p) {
        if (-not $p) { return $null }
        $up = ''
        try { $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop; if ($o.User) { $up = "$($o.Domain)\$($o.User)" } } catch { }
        [pscustomobject][ordered]@{
            PID         = $p.ProcessId
            Program     = $p.ExecutablePath
            Ukaz        = $p.CommandLine
            Uporabnik   = $up
            Zagnan      = $p.CreationDate
            'Zagnal ga' = (Veriga-Starsev $p)
        }
    }
    function Veriga-Starsev($p) {
        $veriga = @(); $trenutni = $p; $n = 0
        while ($trenutni -and $n -lt 8) {
            $st = $vsiProcesi[[int]$trenutni.ParentProcessId]
            if (-not $st -or $st.ProcessId -eq $trenutni.ProcessId) { break }
            $opis = "$($st.Name) (PID $($st.ProcessId))"
            if ($st.Name -eq 'svchost.exe' -and $st.CommandLine -match '-s (\w+)') { $opis += " storitev $($Matches[1])" }
            if ($st.Name -eq 'svchost.exe' -and $st.CommandLine -match 'netsvcs|Schedule') { $opis += ' [Task Scheduler?]' }
            $veriga += $opis; $trenutni = $st; $n++
        }
        if ($veriga) { return ($veriga -join '  <-  ') } else { return '(stars ne tece vec)' }
    }

    # ------------------------------------------------------------ 1. namestitve Pythona
    Naslov '1. NAMESTITVE PYTHONA'
    $pythoni = @{}
    foreach ($c in @(Get-Command python.exe, python3.exe, py.exe, pythonw.exe -All -ErrorAction SilentlyContinue)) { $pythoni[$c.Source] = 1 }
    foreach ($k in 'HKLM:\SOFTWARE\Python\PythonCore\*\InstallPath', 'HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore\*\InstallPath', 'Registry::HKEY_USERS\*\Software\Python\PythonCore\*\InstallPath') {
        foreach ($i in @(Get-ItemProperty $k -ErrorAction SilentlyContinue)) {
            $exe = if ($i.ExecutablePath) { $i.ExecutablePath } else { Join-Path $i.'(default)' 'python.exe' }
            if ($exe) { $pythoni[$exe] = 1 }
        }
    }
    foreach ($vz in 'C:\Python*\python.exe', 'C:\Program Files\Python*\python.exe', 'C:\Program Files (x86)\Python*\python.exe',
        'C:\Users\*\AppData\Local\Programs\Python\*\python.exe', 'C:\ProgramData\Anaconda*\python.exe', 'C:\ProgramData\miniconda*\python.exe',
        'C:\Users\*\Anaconda*\python.exe', 'C:\Users\*\miniconda*\python.exe', 'D:\Python*\python.exe') {
        foreach ($f in @(Get-ChildItem $vz -ErrorAction SilentlyContinue)) { $pythoni[$f.FullName] = 1 }
    }
    Tabela ($pythoni.Keys | Where-Object { $_ -and (Test-Path $_) -and $_ -notmatch 'WindowsApps' } | Sort-Object | ForEach-Object {
            $f = Get-Item $_
            [pscustomobject][ordered]@{ Python = $f.FullName; Verzija = $f.VersionInfo.ProductVersion; Namescen = $f.CreationTime; Lastnik = (Lastnik $f.FullName) }
        })
    Pisi ''
    Pisi '-- Vnosi v "Programi in funkcije":'
    Tabela (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'Registry::HKEY_USERS\*\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'Python|Anaconda|Miniconda' -and $_.DisplayName -notmatch 'Emscripten|Launcher|Documentation|Test Suite|Tcl|pip Bootstrap|Development Libraries|Add to Path|Utility Scripts|Standard Library|Executables|Core Interpreter' } |
        ForEach-Object { [pscustomobject][ordered]@{ Ime = $_.DisplayName; Verzija = $_.DisplayVersion; 'Datum namestitve' = $_.InstallDate; Mapa = $_.InstallLocation; Registrski = ($_.PSPath -replace '^.*::', '') } })

    # ------------------------------------------------------------ 2. procesi zdaj
    Naslov '2. PYTHON PROCESI, KI TECEJO ZDAJ'
    Tabela ($vsiProcesi.Values | Where-Object { $_.Name -match '^(python|pythonw|py)\d*(\.\d+)?\.exe$' -or $_.CommandLine -match '\.py(\s|"|$)' } | ForEach-Object { Opis-Procesa $_ })

    # ------------------------------------------------------------ 3. opravila
    Naslov '3. OPRAVILA V TASK SCHEDULERJU (python, .py, .bat, .cmd, .ps1, .vbs; brez Microsoftovih)'
    $opravila = @()
    try { $opravila = @(Get-ScheduledTask -ErrorAction Stop) } catch { Pisi "Get-ScheduledTask ni uspel: $_" }
    Tabela ($opravila | Where-Object {
            $_.TaskPath -notlike '\Microsoft\*' -and $_.TaskName -notmatch '^OneDrive|^MicrosoftEdgeUpdate|^GoogleUpdate' -and
            (($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments) $($_.WorkingDirectory)" }) -join ' ') -match 'python|\.py\b|\.bat\b|\.cmd\b|\.ps1\b|\.vbs\b|\.exe'
        } | ForEach-Object {
            $t = $_
            $info = $null; try { $info = Get-ScheduledTaskInfo -InputObject $t -ErrorAction Stop } catch { }
            $sprozilci = ($t.Triggers | ForEach-Object {
                    $o = $_.CimClass.CimClassName -replace 'MSFT_Task|Trigger', ''
                    if ($_.StartBoundary) { $o += " od $($_.StartBoundary)" }
                    if ($_.Repetition -and $_.Repetition.Interval) { $o += " ponovi vsakih $($_.Repetition.Interval)" }
                    if (-not $_.Enabled) { $o += ' (izklopljen)' }
                    $o }) -join ' | '
            [pscustomobject][ordered]@{
                Opravilo          = "$($t.TaskPath)$($t.TaskName)"
                Stanje            = $t.State
                Avtor             = $t.Author
                'Ustvarjeno'      = $t.Date
                Opis              = $t.Description
                'Tece kot'        = "$($t.Principal.UserId) $($t.Principal.GroupId) (RunLevel $($t.Principal.RunLevel), prijava $($t.Principal.LogonType))"
                Ukaz              = (($t.Actions | ForEach-Object { "[$($_.WorkingDirectory)] $($_.Execute) $($_.Arguments)" }) -join ' ; ')
                Sprozilci         = $sprozilci
                'Zadnji zagon'    = if ($info) { "$($info.LastRunTime)  rezultat $($info.LastTaskResult)" } else { '' }
                'Naslednji zagon' = if ($info) { $info.NextRunTime } else { '' }
            }
        })

    # ------------------------------------------------------------ 4. storitve
    Naslov '4. WINDOWS STORITVE S PYTHONOM ali OVOJEM (nssm, winsw, pythonservice ...)'
    Tabela (Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.PathName -match 'python|nssm|winsw|srvany|pythonservice|\.py\b' } | ForEach-Object {
            $s = $_
            $app = ''
            try {
                $par = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)\Parameters" -ErrorAction Stop
                $app = "$($par.Application) $($par.AppParameters)  [mapa $($par.AppDirectory)]"
            }
            catch { }
            [pscustomobject][ordered]@{ Storitev = $s.Name; Ime = $s.DisplayName; Stanje = $s.State; Zagon = $s.StartMode; 'Tece kot' = $s.StartName; Pot = $s.PathName; 'NSSM aplikacija' = $app; Opis = $s.Description }
        })

    # ------------------------------------------------------------ 5. samodejni zagon
    Naslov '5. SAMODEJNI ZAGON (Run v registru, mapa Startup)'
    $zagon = @()
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'Registry::HKEY_USERS\*\Software\Microsoft\Windows\CurrentVersion\Run') {
        foreach ($i in @(Get-Item $k -ErrorAction SilentlyContinue)) {
            foreach ($ime in $i.GetValueNames()) { $zagon += [pscustomobject][ordered]@{ Kje = ($i.Name); Ime = $ime; Ukaz = $i.GetValue($ime) } }
        }
    }
    foreach ($f in @(Get-ChildItem 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\*', 'C:\Users\*\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\*' -ErrorAction SilentlyContinue)) {
        $zagon += [pscustomobject][ordered]@{ Kje = $f.DirectoryName; Ime = $f.Name; Ukaz = "ustvarjeno $($f.CreationTime), lastnik $(Lastnik $f.FullName)" }
    }
    Tabela ($zagon | Where-Object { $_.Ukaz -match 'python|\.py|\.bat|\.cmd|\.ps1|\.vbs|ustvarjeno' })

    # ------------------------------------------------------------ 6. datoteke skript
    Naslov "6. DATOTEKE SKRIPT, KI OMENJAJO SAOP API (vzorec: $Vzorec)"
    $iskanePoti = $Poti
    if (-not $iskanePoti) { $iskanePoti = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $_.DeviceID + '\' }) }
    $izpusti = '\\Windows\\|\\WindowsApps\\|\\site-packages\\|\\node_modules\\|\\\$Recycle\.Bin\\|\\WinSxS\\|\\Lib\\test\\|\\inetpub\\logs\\|\\System Volume Information\\|\\Microsoft\.NET\\|\\assembly\\'
    $koncnice = @('.py', '.pyw', '.bat', '.cmd', '.ps1', '.vbs', '.ini', '.cfg', '.conf', '.env', '.json', '.yaml', '.yml', '.toml', '.txt')
    $najdeno = @()
    foreach ($koren in $iskanePoti) {
        Write-Host "Iscem skripte v $koren ..."
        $datoteke = Get-ChildItem -Path $koren -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $koncnice -contains $_.Extension.ToLower() -and $_.Length -lt 5MB -and $_.FullName -notmatch $izpusti }
        foreach ($f in $datoteke) {
            $zad = Select-String -LiteralPath $f.FullName -Pattern $Vzorec -ErrorAction SilentlyContinue | Select-Object -First 3
            if ($zad) {
                $najdeno += [pscustomobject][ordered]@{
                    Datoteka        = $f.FullName
                    Ustvarjena      = $f.CreationTime
                    Spremenjena     = $f.LastWriteTime
                    'Zadnji dostop' = $f.LastAccessTime
                    Lastnik         = (Lastnik $f.FullName)
                    Vrstice         = (($zad | ForEach-Object { "#$($_.LineNumber): $($_.Line.Trim())" }) -join "`n              ")
                }
            }
        }
    }
    Tabela ($najdeno | Sort-Object Spremenjena -Descending)
    # Mape najdenih .py: kaj je se zraven (requirements, config, log, venv)
    $mape = $najdeno | Where-Object { $_.Datoteka -match '\.pyw?$' } | ForEach-Object { Split-Path $_.Datoteka } | Sort-Object -Unique
    foreach ($m in $mape) {
        Pisi ''
        Pisi "-- Vsebina mape $m"
        Tabela (Get-ChildItem -LiteralPath $m -Force -ErrorAction SilentlyContinue | Select-Object -First 60 | ForEach-Object {
                [pscustomobject][ordered]@{ Ime = $_.Name; Velikost = $_.Length; Ustvarjeno = $_.CreationTime; Spremenjeno = $_.LastWriteTime; Lastnik = (Lastnik $_.FullName) } })
    }

    # ------------------------------------------------------------ 7. dnevniki dogodkov
    Naslov "7. DNEVNIKI DOGODKOV (zadnjih $DniDogodkov dni)"
    $od = (Get-Date).AddDays(-$DniDogodkov)
    function Sid-Ime($sid) { try { (New-Object Security.Principal.SecurityIdentifier($sid)).Translate([Security.Principal.NTAccount]).Value } catch { "$sid" } }

    Pisi '-- Namestitve Pythona (MsiInstaller):'
    Tabela (Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; StartTime = $od } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'Python|Anaconda' } | Select-Object -First 40 | ForEach-Object {
            [pscustomobject][ordered]@{ Cas = $_.TimeCreated; Uporabnik = (Sid-Ime $_.UserId); Dogodek = ($_.Message -split "`r?`n")[0] } })

    Pisi ''
    Pisi '-- Registracija / sprememba opravil (TaskScheduler Operational 106, 140, 141):'
    Tabela (Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-TaskScheduler/Operational'; Id = 106, 140, 141; StartTime = $od } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -notmatch '\\Microsoft\\|SoftLanding|OneDrive' } | Select-Object -First 60 | ForEach-Object {
            [pscustomobject][ordered]@{ Cas = $_.TimeCreated; Id = $_.Id; Dogodek = ($_.Message -replace '\s+', ' ') } })

    Pisi ''
    Pisi '-- Varnostni dnevnik: ustvarjena/spremenjena opravila (4698, 4702) in nove storitve (4697, 7045):'
    Tabela (@(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4698, 4702, 4697; StartTime = $od } -ErrorAction SilentlyContinue) +
        @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7045; StartTime = $od } -ErrorAction SilentlyContinue) |
        Where-Object { $_ -and $_.Message -notmatch '\\Microsoft\\Windows\\' } | Sort-Object TimeCreated -Descending | Select-Object -First 60 | ForEach-Object {
            $m = $_.Message
            $kdo = if ($m -match 'Account Name:\s+(\S+)') { $Matches[1] } else { '' }
            $kaj = if ($m -match 'Task Name:\s+(.+)') { $Matches[1].Trim() } elseif ($m -match 'Service Name:\s+(.+)') { $Matches[1].Trim() } else { '' }
            [pscustomobject][ordered]@{ Cas = $_.TimeCreated; Id = $_.Id; Kdo = $kdo; Kaj = $kaj; Ukaz = if ($m -match '<Command>(.+?)</Command>') { $Matches[1] } elseif ($m -match 'Service File Name:\s+(.+)') { $Matches[1].Trim() } else { '' } } })

    Pisi ''
    Pisi '-- Kdo se je prijavljal na streznik (oddaljeno namizje / interaktivno, zadnjih 30 dni):'
    Tabela (Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4624; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 20000 -ErrorAction SilentlyContinue |
        Where-Object { $_.Properties[8].Value -in 2, 10 } | ForEach-Object {
            [pscustomobject]@{ Uporabnik = "$($_.Properties[6].Value)\$($_.Properties[5].Value)"; Od = "$($_.Properties[18].Value)"; Cas = $_.TimeCreated } } |
        Group-Object Uporabnik | ForEach-Object {
            [pscustomobject][ordered]@{ Uporabnik = $_.Name; Prijav = $_.Count; Zadnja = ($_.Group | Sort-Object Cas -Descending | Select-Object -First 1).Cas; 'Iz naslovov' = (($_.Group.Od | Sort-Object -Unique) -join ', ') } })

    # ------------------------------------------------------------ 8. ujemi zagon
    if ($Ujemi -gt 0) {
        Naslov "8. CAKAM $Ujemi MIN NA KLIC SAOP API (port $($Porti -join ',')) IN UJAMEM PROCES"
        $ujeti = @{}
        $konec = (Get-Date).AddMinutes($Ujemi)
        while ((Get-Date) -lt $konec) {
            Write-Progress -Activity 'Cakam na klic SAOP API' -Status ("se {0:N0} s, ujetih procesov: {1}" -f ($konec - (Get-Date)).TotalSeconds, $ujeti.Count)
            foreach ($c in @(Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $Porti -contains $_.RemotePort -and $_.State -in 'Established', 'SynSent', 'TimeWait' -and $_.OwningProcess -gt 4 })) {
                $procId = [int]$c.OwningProcess
                if ($ujeti.ContainsKey($procId)) { $ujeti[$procId].Povezav++; continue }
                $p = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue
                if (-not $p) { continue }
                $vsiProcesi[$procId] = $p
                if (-not $vsiProcesi.ContainsKey([int]$p.ParentProcessId)) {
                    $st = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ParentProcessId)" -ErrorAction SilentlyContinue
                    if ($st) { $vsiProcesi[[int]$st.ProcessId] = $st; $g = Get-CimInstance Win32_Process -Filter "ProcessId=$($st.ParentProcessId)" -ErrorAction SilentlyContinue; if ($g) { $vsiProcesi[[int]$g.ProcessId] = $g } }
                }
                $o = Opis-Procesa $p
                $o | Add-Member -NotePropertyName 'Ujet ob' -NotePropertyValue (Get-Date -Format 'HH:mm:ss')
                $o | Add-Member -NotePropertyName 'Povezav' -NotePropertyValue 1
                $o | Add-Member -NotePropertyName 'Na' -NotePropertyValue "$($c.RemoteAddress):$($c.RemotePort)"
                $ujeti[$procId] = $o
                Write-Host ("Ujet: {0} {1}" -f $p.Name, $p.CommandLine) -ForegroundColor Yellow
            }
            Start-Sleep -Milliseconds 500
        }
        Write-Progress -Activity 'Cakam na klic SAOP API' -Completed
        Tabela ($ujeti.Values)
    }

    Pisi ''
    Pisi ('Trajanje: {0:N0} s' -f $stoparica.Elapsed.TotalSeconds)
    $out | Out-File -FilePath $potPorocila -Encoding UTF8
    Write-Host ''
    Write-Host "Porocilo: $potPorocila" -ForegroundColor Green
    if (-not $NeOdpri) { Start-Process notepad.exe $potPorocila }
}

# =====================================================================================================
# ZAGON
# =====================================================================================================
$uspeh = $true
if ($Kaj -in 'Vse', 'Promet') {
    Write-Host ''
    Write-Host '########## 1. DEL: PROMET NA SAOP API (kdo klice) ##########' -ForegroundColor Cyan
    try { Analiza-Promet } catch { $uspeh = $false; Write-Host "1. del ni uspel: $_" -ForegroundColor Red }
}
if ($Kaj -in 'Vse', 'Python') {
    Write-Host ''
    Write-Host '########## 2. DEL: IZVOR PYTHON SKRIPTE (od kod pride klic) ##########' -ForegroundColor Cyan
    try { Analiza-Python } catch { $uspeh = $false; Write-Host "2. del ni uspel: $_" -ForegroundColor Red }
}
Write-Host ''
Write-Host "Vsi rezultati so v mapi: $Izhod" -ForegroundColor Green
if (-not $uspeh) { exit 1 }
