<#
.SYNOPSIS
  Poraba PIM workerjev na strezniku: koliko CPU in pomnilnika porabijo, koliko bremenijo SQL,
  koliko klicev SAOP API naredijo - in ZAKAJ (kateri posel, korak, poizvedba je takrat tekla).

.DESCRIPTION
  Zaganja se NA STREZNIKU, kjer tecejo PIM workerji (PowerShell "Run as administrator").
  Nicesar ne spreminja, samo bere. Navodila: NAVODILA.md (ista mapa).

  1. ZGODOVINA (zadnjih -Ure ur, iz baze ops.JobRun / ops.JobStepRun):
     - po workerju in poslu: zagonov, minut dela, povprecno, najdlje, padlih;
     - klici SAOP API iz IIS dnevnikov (SaopApi, SaopApiTest), ki so prisli S TEGA STREZNIKA,
       pripisani workerju, ki je takrat tekel. Klici, ko ni tekel noben PIM posel, so locani
       (intranet, Python skripta ali drug program).
  2. ZIVO (-Minute minut, vzorec vsakih -Interval sekund):
     - CPU % in pomnilnik vsakega PIM procesa (PIM.*, IIS pooli, dotnet, python, sqlservr);
     - koliko CPU in branj je vsak proces povzrocil v SQL (po PID seje);
     - katere SQL poizvedbe je takrat izvajal (zakaj);
     - kateri posel in korak je takrat tekel;
     - odprte povezave na SAOP API (port 81/82) po procesu.

  Rezultat: C:\Temp\PIM-poraba\poraba_*.txt + vzorci_*.csv (za Excel).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File PIM-poraba-workerjev.ps1
  powershell -ExecutionPolicy Bypass -File PIM-poraba-workerjev.ps1 -Minute 30 -Interval 5
  powershell -ExecutionPolicy Bypass -File PIM-poraba-workerjev.ps1 -Minute 0 -Ure 168
  powershell -ExecutionPolicy Bypass -File PIM-poraba-workerjev.ps1 -Streznik 'localhost\SQL01' -Baza PIM_prd
#>
[CmdletBinding()]
param(
    # Zivo opazovanje: koliko minut (0 = samo zgodovina).
    [double]$Minute = 10,
    [int]$Interval = 5,
    # Zgodovina: koliko ur nazaj.
    [double]$Ure = 24,
    # Baza PIM (Windows prijava). Ali pa cel -Povezava.
    [string]$Streznik = 'localhost',
    [string]$Baza = 'PIM_prd',
    [string]$Povezava,
    # IIS mesta SAOP API za stetje klicev (prazno ali -BrezSaop = ne beri).
    [string[]]$Spletna = @('SaopApi', 'SaopApiTest'),
    [switch]$BrezSaop,
    # Ce PIM ne tece na istem strezniku kot SAOP: IP naslovi PIM streznika.
    [string[]]$PimIp,
    # Kateri procesi se opazujejo (regex po imenu).
    [string]$Procesi = '^(PIM\..*|w3wp|dotnet|python.*|pythonw|sqlservr)$',
    [int[]]$SaopPorti = @(81, 82),
    [string]$Izhod = 'C:\Temp\PIM-poraba',
    [switch]$NeOdpri
)

$ErrorActionPreference = 'Continue'
$inv = [Globalization.CultureInfo]::InvariantCulture
$stoparica = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $Izhod | Out-Null
$zig = Get-Date -Format 'yyyyMMdd_HHmm'
$potPorocila = Join-Path $Izhod "poraba_$zig.txt"
$potCsv = Join-Path $Izhod "vzorci_$zig.csv"
$out = New-Object System.Collections.Generic.List[string]
function Pisi([string]$t = '') { $out.Add($t); Write-Host $t }
function Naslov([string]$t) { Pisi ''; Pisi ('=' * 110); Pisi "== $t"; Pisi ('=' * 110) }
function Tabela($vrstice) {
    if (-not $vrstice) { Pisi '(ni podatkov)'; return }
    $txt = ($vrstice | Format-Table -AutoSize -Wrap | Out-String -Width 400).TrimEnd()
    foreach ($l in $txt -split "`r?`n") { Pisi $l }
}
function Kratko([string]$v, [int]$n) { if ($null -eq $v) { return '' }; $v = ($v -replace '\s+', ' ').Trim(); if ($v.Length -gt $n) { return $v.Substring(0, $n - 3) + '...' } return $v }
function ImeWorkerja([string]$ukaz, [string]$korak) {
    if ($ukaz -match '(PIM\.[A-Za-z0-9]+)') { return $Matches[1] }
    if ($korak) { return "SQL/korak: $(Kratko $korak 40)" }
    return '(neznano)'
}

$jeAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$jeder = [Environment]::ProcessorCount
Pisi "PORABA PIM WORKERJEV - $env:COMPUTERNAME"
Pisi ("Ustvarjeno: {0:dd.MM.yyyy HH:mm}   Jeder CPU: {1}   Administrator: {2}   Zgodovina: {3} h   Zivo: {4} min" -f (Get-Date), $jeder, $jeAdmin, $Ure, $Minute)
if (-not $jeAdmin) { Pisi 'OPOZORILO: brez administratorja ne vidim CPU tujih procesov (IIS, storitve).' }

# ---------------------------------------------------------------- baza
if (-not $Povezava) { $Povezava = "Server=$Streznik;Database=$Baza;Integrated Security=True;TrustServerCertificate=True;Application Name=PIM-poraba-diagnoza;Connect Timeout=10" }
$sql = $null
try { $sql = New-Object System.Data.SqlClient.SqlConnection $Povezava; $sql.Open() }
catch { Pisi "OPOZORILO: baze ne dosezem ($($_.Exception.Message)). Brez baze ni poslov, SQL porabe in pripisa klicev SAOP."; $sql = $null }
function Sql([string]$q) {
    if (-not $sql) { return @() }
    try {
        $cmd = $sql.CreateCommand(); $cmd.CommandText = $q; $cmd.CommandTimeout = 60
        $t = New-Object System.Data.DataTable; $t.Load($cmd.ExecuteReader()); return , $t
    }
    catch { Write-Warning "SQL: $($_.Exception.Message)"; return @() }
}
$mojSpid = if ($sql) { (Sql 'SELECT @@SPID AS s').Rows[0].s } else { 0 }

# =================================================================================================
# 1. ZGODOVINA
# =================================================================================================
Naslov "1. ZGODOVINA: KAJ SO WORKERJI DELALI V ZADNJIH $Ure URAH (ops.JobRun / ops.JobStepRun)"
$koraki = @()
if ($sql) {
    $ureInt = [int][math]::Ceiling($Ure)
    $t = Sql @"
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SELECT r.JobKey, s.StepName, s.OrganizationId, s.Command, s.StartedUtc, s.EndedUtc, s.Status
FROM ops.JobStepRun AS s JOIN ops.JobRun AS r ON r.JobRunId = s.JobRunId
WHERE s.StartedUtc >= DATEADD(HOUR, -$ureInt, SYSUTCDATETIME()) AND s.Status <> N'Blocked'
UNION ALL
SELECT r.JobKey, ISNULL(r.CurrentStep, N'(v teku)'), NULL, r.CurrentStep, r.StartedUtc, NULL, N'Running'
FROM ops.JobRun AS r WHERE r.EndedUtc IS NULL AND r.Status = N'Running';
"@
    $zdaj = [datetime]::UtcNow
    foreach ($r in $t.Rows) {
        $od = [datetime]::SpecifyKind($r.StartedUtc, 'Utc')
        $do = if ($r.EndedUtc -is [DBNull]) { $zdaj } else { [datetime]::SpecifyKind($r.EndedUtc, 'Utc') }
        $koraki += [pscustomobject]@{
            Worker = ImeWorkerja ([string]$r.Command) ([string]$r.StepName)
            Posel  = [string]$r.JobKey
            Org    = if ($r.OrganizationId -is [DBNull]) { '' } else { [string]$r.OrganizationId }
            Od     = $od; Do = $do; Status = [string]$r.Status
            Sek    = [math]::Max(0, ($do - $od).TotalSeconds)
        }
    }
    Pisi ''
    Pisi '-- Po workerju (koliko casa je delal; zasedenost = delez obdobja, ko je tekel):'
    Tabela ($koraki | Group-Object Worker | ForEach-Object {
            $g = $_.Group
            [pscustomobject][ordered]@{
                Worker          = $_.Name
                Zagonov         = $g.Count
                'Minut dela'    = [math]::Round(($g | Measure-Object Sek -Sum).Sum / 60, 1)
                'Zasedenost %'  = [math]::Round(100 * ($g | Measure-Object Sek -Sum).Sum / ($Ure * 3600), 1)
                'Povp. min'     = [math]::Round(($g | Measure-Object Sek -Average).Average / 60, 1)
                'Najdlje min'   = [math]::Round(($g | Measure-Object Sek -Maximum).Maximum / 60, 1)
                Padlih          = @($g | Where-Object { $_.Status -in 'Failed', 'TimedOut' }).Count
                'Posli'         = (($g.Posel | Sort-Object -Unique) -join ', ')
            } } | Sort-Object 'Minut dela' -Descending)
    Pisi ''
    Pisi '-- Po poslu in podjetju (top 30):'
    Tabela ($koraki | Group-Object Posel, Worker, Org | ForEach-Object {
            $g = $_.Group
            [pscustomobject][ordered]@{
                Posel = $g[0].Posel; Worker = $g[0].Worker; Podjetje = $g[0].Org; Zagonov = $g.Count
                'Minut dela' = [math]::Round(($g | Measure-Object Sek -Sum).Sum / 60, 1)
                'Najdlje min' = [math]::Round(($g | Measure-Object Sek -Maximum).Maximum / 60, 1)
                Padlih = @($g | Where-Object { $_.Status -in 'Failed', 'TimedOut' }).Count
            } } | Sort-Object 'Minut dela' -Descending | Select-Object -First 30)
}
else { Pisi '(brez baze)' }

# ---------------------------------------------------------------- klici SAOP po workerju
Naslov "1b. KLICI SAOP API S TEGA STREZNIKA, PRIPISANI WORKERJU, KI JE TAKRAT TEKEL (zadnjih $Ure ur)"
if ($BrezSaop -or -not $Spletna) { Pisi '(preskoceno)' }
else {
    $lastniIp = @{ '127.0.0.1' = 1; '::1' = 1 }
    if ($PimIp) { foreach ($i in $PimIp) { $lastniIp[$i] = 1 } }
    else { try { Get-NetIPAddress -ErrorAction Stop | ForEach-Object { $lastniIp[($_.IPAddress -replace '%\d+$', '')] = 1 } } catch { } }

    # Minuta (UTC) -> workerji, ki so takrat tekli.
    $poMinuti = @{}
    foreach ($k in $koraki) {
        $m = [datetime]::new($k.Od.Year, $k.Od.Month, $k.Od.Day, $k.Od.Hour, $k.Od.Minute, 0, 'Utc')
        while ($m -le $k.Do) {
            $kl = $m.ToString('yyyyMMddHHmm')
            if (-not $poMinuti.ContainsKey($kl)) { $poMinuti[$kl] = @{} }
            $poMinuti[$kl][$k.Worker] = 1
            $m = $m.AddMinutes(1)
        }
    }

    $mesta = @()
    try {
        Import-Module WebAdministration -ErrorAction Stop
        try { & netsh http flush logbuffer | Out-Null } catch { }
        foreach ($ime in $Spletna) {
            $s = Get-Website -Name $ime
            if (-not $s) { Pisi "Spletnega mesta '$ime' na tem strezniku ni (SAOP tece drugje?). Uporabi SAOP-analiza-streznika.ps1 na IQ-SAOP in -PimIp."; continue }
            $koren = [Environment]::ExpandEnvironmentVariables($s.logFile.directory)
            $mapa = Join-Path $koren "W3SVC$($s.id)"; $centralno = $false
            if (-not (Test-Path $mapa)) { $mapa = Join-Path $koren 'W3SVC'; $centralno = $true }
            $mesta += [pscustomobject]@{ Ime = $ime; Koda = "W3SVC$($s.id)"; Mapa = $mapa; Centralno = $centralno }
        }
    }
    catch { Pisi "IIS ni dosegljiv ($($_.Exception.Message))." }

    $odUtc = [datetime]::UtcNow.AddHours(-$Ure)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $poWorkerju = @{}; $tuji = 0; $vsehKlicev = 0
    foreach ($m in $mesta) {
        if (-not (Test-Path $m.Mapa)) { continue }
        foreach ($f in (Get-ChildItem $m.Mapa -Filter '*.log' -File | Where-Object { $_.LastWriteTimeUtc -ge $odUtc } | Sort-Object Name)) {
            $sr = New-Object System.IO.StreamReader([System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite'))
            $idx = $null
            try {
                while ($null -ne ($vr = $sr.ReadLine())) {
                    if ($vr.Length -eq 0) { continue }
                    if ($vr[0] -eq '#') {
                        if ($vr.StartsWith('#Fields:')) {
                            $polja = $vr.Substring(8).Trim().Split(' '); $idx = @{}
                            for ($i = 0; $i -lt $polja.Count; $i++) { $idx[$polja[$i]] = $i }
                            $nP = $polja.Count
                            $iIp = if ($idx.ContainsKey('c-ip')) { $idx['c-ip'] } else { -1 }
                            $iMs = if ($idx.ContainsKey('time-taken')) { $idx['time-taken'] } else { -1 }
                            $iSite = if ($idx.ContainsKey('s-sitename')) { $idx['s-sitename'] } else { -1 }
                        }
                        continue
                    }
                    if ($null -eq $idx -or $iIp -lt 0) { continue }
                    $p = $vr.Split(' ')
                    if ($p.Count -ne $nP) { continue }
                    if ($m.Centralno -and $iSite -ge 0 -and $p[$iSite] -ne $m.Koda) { continue }
                    $t = [datetime]::ParseExact($p[$idx['date']] + ' ' + $p[$idx['time']], 'yyyy-MM-dd HH:mm:ss', $inv, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
                    if ($t -lt $odUtc) { continue }
                    $vsehKlicev++
                    if (-not $lastniIp.ContainsKey($p[$iIp])) { $tuji++; continue }
                    $kl = $t.ToString('yyyyMMddHHmm')
                    $kdo = if ($poMinuti.ContainsKey($kl)) { (($poMinuti[$kl].Keys | Sort-Object) -join ' + ') } else { '(noben PIM posel ni tekel - intranet, Python ali drug program)' }
                    $z = $poWorkerju[$kdo]
                    if (-not $z) { $z = @{ N = 0; Nap = 0; Ms = 0.0; Poti = @{} }; $poWorkerju[$kdo] = $z }
                    $z.N++; if ([int]$p[$idx['sc-status']] -ge 400) { $z.Nap++ }
                    if ($iMs -ge 0) { $z.Ms += [long]$p[$iMs] }
                    $pot = ($p[$idx['cs-uri-stem']] -replace '/\d+(?=/|$)', '/{st}')
                    $z.Poti[$pot] = 1 + [long]$z.Poti[$pot]
                }
            }
            finally { $sr.Dispose() }
        }
    }
    if ($mesta) {
        Pisi ("Vseh klicev SAOP API: {0:N0}   s tega streznika: {1:N0}   z drugih racunalnikov: {2:N0}" -f $vsehKlicev, ($vsehKlicev - $tuji), $tuji)
        Pisi 'Opomba: ce sta hkrati tekla dva workerja, je klic pripisan obema skupaj ("A + B").'
        Tabela ($poWorkerju.GetEnumerator() | Sort-Object { $_.Value.N } -Descending | ForEach-Object {
                [pscustomobject][ordered]@{
                    'Kdo (worker takrat v teku)' = $_.Key
                    Klicev                       = $_.Value.N
                    Napak                        = $_.Value.Nap
                    'Povp ms'                    = [math]::Round($_.Value.Ms / [math]::Max(1, $_.Value.N))
                    'Najpogostejsi klici'        = (($_.Value.Poti.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Value)x $($_.Key)" }) -join ' | ')
                } })
    }
}

# =================================================================================================
# 2. ZIVO
# =================================================================================================
if ($Minute -gt 0) {
    Naslov "2. ZIVO: $Minute MIN, VZOREC VSAKIH $Interval S"
    $opisPid = @{}
    function OpisProcesa($pr) {
        $procId = [int]$pr.Id
        if ($opisPid.ContainsKey($procId)) { return $opisPid[$procId] }
        $opis = $pr.ProcessName
        try {
            $c = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop
            if ($pr.ProcessName -eq 'w3wp' -and $c.CommandLine -match '-ap "([^"]+)"') { $opis = "IIS pool $($Matches[1])" }
            elseif ($pr.ProcessName -eq 'dotnet' -and $c.CommandLine -match '([\w\.]+)\.dll') { $opis = "dotnet $($Matches[1])" }
            elseif ($pr.ProcessName -like 'python*' -and $c.CommandLine -match '([^\\/"\s]+\.pyw?)') { $opis = "python $($Matches[1])" }
            elseif ($pr.ProcessName -eq 'sqlservr' -and $c.CommandLine -match '-s(\w+)') { $opis = "SQL Server ($($Matches[1]))" }
        }
        catch { }
        $opisPid[$procId] = $opis
        return $opis
    }

    $stat = @{}      # kljuc = opis procesa
    $prejCpu = @{}   # pid -> TotalProcessorTime ms
    $prejSql = @{}   # pid -> (cpu ms, branja)
    $csv = New-Object System.IO.StreamWriter($potCsv, $false, (New-Object System.Text.UTF8Encoding($true)))
    $csv.WriteLine('Cas;Proces;PID;CPU %;MB;SQL CPU ms;SQL branj;SAOP povezav;Posli v teku;SQL poizvedba')
    $prejCas = Get-Date
    foreach ($pr in @(Get-Process | Where-Object { $_.ProcessName -match $Procesi })) { try { $prejCpu[$pr.Id] = $pr.TotalProcessorTime.TotalMilliseconds } catch { } }
    if ($sql) { foreach ($r in (Sql 'SELECT host_process_id AS pid, SUM(cpu_time) AS cpu, SUM(logical_reads) AS br FROM sys.dm_exec_sessions WHERE is_user_process = 1 AND host_process_id IS NOT NULL GROUP BY host_process_id').Rows) { $prejSql[[int]$r.pid] = @([long]$r.cpu, [long]$r.br) } }

    $konec = (Get-Date).AddMinutes($Minute)
    $vzorec = 0
    while ((Get-Date) -lt $konec) {
        Start-Sleep -Seconds $Interval
        $vzorec++
        Write-Progress -Activity 'Opazujem porabo PIM procesov' -Status ("se {0:N0} s" -f ($konec - (Get-Date)).TotalSeconds) -PercentComplete ([math]::Min(100, 100 * $vzorec * $Interval / ($Minute * 60)))
        $zdaj = Get-Date
        $ms = ($zdaj - $prejCas).TotalMilliseconds; $prejCas = $zdaj

        # posli v teku
        $posli = ''
        if ($sql) { $posli = ((Sql "SELECT JobKey + ISNULL(N' / ' + CurrentStep, N'') AS p FROM ops.JobRun WITH (NOLOCK) WHERE EndedUtc IS NULL AND Status = N'Running'").Rows | ForEach-Object { $_.p }) -join ' | ' }

        # SQL poraba po PID + trenutne poizvedbe
        $sqlZdaj = @{}; $poizvedbe = @{}
        if ($sql) {
            foreach ($r in (Sql 'SELECT host_process_id AS pid, SUM(cpu_time) AS cpu, SUM(logical_reads) AS br FROM sys.dm_exec_sessions WHERE is_user_process = 1 AND host_process_id IS NOT NULL GROUP BY host_process_id').Rows) { $sqlZdaj[[int]$r.pid] = @([long]$r.cpu, [long]$r.br) }
            foreach ($r in (Sql @"
SELECT s.host_process_id AS pid,
  ISNULL(OBJECT_SCHEMA_NAME(t.objectid, t.dbid) + N'.' + OBJECT_NAME(t.objectid, t.dbid) + N': ', N'') +
  SUBSTRING(t.text, r.statement_start_offset / 2 + 1, 200) AS q
FROM sys.dm_exec_requests AS r JOIN sys.dm_exec_sessions AS s ON s.session_id = r.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE s.is_user_process = 1 AND r.session_id <> $mojSpid AND s.host_process_id IS NOT NULL
"@).Rows) { $poizvedbe[[int]$r.pid] = Kratko ([string]$r.q) 150 }
        }

        # SAOP povezave po PID
        $saop = @{}
        foreach ($c in @(Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $SaopPorti -contains $_.RemotePort -and $_.OwningProcess -gt 4 })) { $saop[[int]$c.OwningProcess] = 1 + [int]$saop[[int]$c.OwningProcess] }

        foreach ($pr in @(Get-Process | Where-Object { $_.ProcessName -match $Procesi })) {
            $procId = [int]$pr.Id
            $cpuMs = $null; try { $cpuMs = $pr.TotalProcessorTime.TotalMilliseconds } catch { }
            $cpuPct = 0.0
            if ($null -ne $cpuMs) {
                $prej = if ($prejCpu.ContainsKey($procId)) { $prejCpu[$procId] } else { 0 }   # nov proces: vsa poraba je iz tega intervala
                $cpuPct = [math]::Max(0, 100 * ($cpuMs - $prej) / ($ms * $jeder))
                $prejCpu[$procId] = $cpuMs
            }
            $sqlCpu = 0; $sqlBr = 0
            if ($sqlZdaj.ContainsKey($procId)) {
                $pr0 = if ($prejSql.ContainsKey($procId)) { $prejSql[$procId] } else { @(0, 0) }
                $sqlCpu = [math]::Max(0, $sqlZdaj[$procId][0] - $pr0[0]); $sqlBr = [math]::Max(0, $sqlZdaj[$procId][1] - $pr0[1])
            }
            $mb = [math]::Round($pr.WorkingSet64 / 1MB)
            $opis = OpisProcesa $pr
            $q = $poizvedbe[$procId]
            $nSaop = [int]$saop[$procId]

            $s = $stat[$opis]
            if (-not $s) { $s = @{ Pid = @{}; Vz = 0; Sum = 0.0; Max = 0.0; CpuS = 0.0; MaxMb = 0; SqlMs = 0; SqlBr = 0; Saop = 0; Posli = @{}; Q = @{} }; $stat[$opis] = $s }
            $s.Pid[$procId] = 1; $s.Vz++; $s.Sum += $cpuPct; if ($cpuPct -gt $s.Max) { $s.Max = $cpuPct }
            $s.CpuS += $cpuPct / 100 * $jeder * $ms / 1000
            if ($mb -gt $s.MaxMb) { $s.MaxMb = $mb }
            $s.SqlMs += $sqlCpu; $s.SqlBr += $sqlBr; $s.Saop += $nSaop
            if (($cpuPct -ge 1 -or $sqlCpu -gt 0 -or $q) -and $posli) { $s.Posli[$posli] = 1 + [int]$s.Posli[$posli] }
            if ($q) { $s.Q[$q] = 1 + [int]$s.Q[$q] }

            if ($cpuPct -ge 0.5 -or $sqlCpu -gt 0 -or $nSaop -or $q) {
                $csv.WriteLine((($zdaj.ToString('yyyy-MM-dd HH:mm:ss'), $opis, $procId, [math]::Round($cpuPct, 1).ToString($inv), $mb, $sqlCpu, $sqlBr, $nSaop, $posli, $q) | ForEach-Object { $v = [string]$_; if ($v -match '[;"]') { '"' + $v.Replace('"', '""') + '"' } else { $v } }) -join ';')
            }
        }
        $prejSql = $sqlZdaj
        foreach ($k in @($prejCpu.Keys)) { if (-not (Get-Process -Id $k -ErrorAction SilentlyContinue)) { $prejCpu.Remove($k) } }
    }
    $csv.Dispose()
    Write-Progress -Activity 'Opazujem porabo PIM procesov' -Completed

    Pisi ''
    Pisi "CPU % je delez CELEGA streznika ($jeder jeder). 100 % = vsa jedra polno zasedena."
    Pisi 'SQL CPU s = koliko procesorskega casa je SQL Server porabil za poizvedbe TEGA procesa (to ni vsteto v CPU % procesa).'
    Tabela ($stat.GetEnumerator() | ForEach-Object {
            $s = $_.Value
            [pscustomobject][ordered]@{
                Proces           = $_.Key
                PID              = (($s.Pid.Keys | Sort-Object) -join ',')
                'Povp CPU %'     = [math]::Round($s.Sum / [math]::Max(1, $s.Vz), 1)
                'Max CPU %'      = [math]::Round($s.Max, 1)
                'CPU s'          = [math]::Round($s.CpuS)
                'Max MB'         = $s.MaxMb
                'SQL CPU s'      = [math]::Round($s.SqlMs / 1000)
                'SQL branj (M)'  = [math]::Round($s.SqlBr / 1e6, 1)
                'SAOP povezav'   = $s.Saop
            } } | Sort-Object { $_.'CPU s' + $_.'SQL CPU s' } -Descending)

    Pisi ''
    Pisi '=== ZAKAJ: kaj je tekel posel in katere SQL poizvedbe je proces izvajal (le procesi z delom) ==='
    foreach ($e in ($stat.GetEnumerator() | Where-Object { $_.Value.CpuS -ge 1 -or $_.Value.SqlMs -gt 0 -or $_.Value.Q.Count } | Sort-Object { $_.Value.CpuS + $_.Value.SqlMs / 1000 } -Descending)) {
        $s = $e.Value
        Pisi ''
        Pisi ("--- {0}   CPU {1:N0} s, SQL CPU {2:N0} s, SAOP povezav {3}" -f $e.Key, $s.CpuS, ($s.SqlMs / 1000), $s.Saop)
        if ($s.Posli.Count) {
            Pisi '    posli v teku, ko je delal (st. vzorcev):'
            foreach ($p in ($s.Posli.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5)) { Pisi ("      {0,4}x  {1}" -f $p.Value, (Kratko $p.Key 150)) }
        }
        else { Pisi '    (ni teklo nobenega PIM posla - delo sprozil clovek v intranetu ali drug program)' }
        if ($s.Q.Count) {
            Pisi '    SQL poizvedbe (st. vzorcev):'
            foreach ($q in ($s.Q.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5)) { Pisi ("      {0,4}x  {1}" -f $q.Value, $q.Key) }
        }
    }
}

if ($sql) { $sql.Dispose() }
Pisi ''
Pisi ('Trajanje: {0:N0} s' -f $stoparica.Elapsed.TotalSeconds)
$out | Out-File -FilePath $potPorocila -Encoding UTF8
Write-Host ''
Write-Host "Porocilo: $potPorocila" -ForegroundColor Green
if ($Minute -gt 0) { Write-Host "Vzorci (Excel): $potCsv" -ForegroundColor Green }
if (-not $NeOdpri) { Start-Process notepad.exe $potPorocila }
