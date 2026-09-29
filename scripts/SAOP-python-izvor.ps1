<#
.SYNOPSIS
  Poisce, od kod prihaja Python skripta, ki klice SAOP API (api/V2/Price ...): kje je, kdo jo je
  namestil, kdo jo zaganja in kako.

.DESCRIPTION
  Zaganja se NA STREZNIKU IQ-SAOP, kot administrator. Nicesar ne spreminja, samo bere.

  1. Namestitve Pythona (kje, kdaj, kdo je lastnik datotek).
  2. Python procesi, ki tecejo zdaj (ukazna vrstica, uporabnik, kdo jih je zagnal).
  3. Opravila v Task Schedulerju, ki zaganjajo python / .py / .bat / .cmd / .ps1 (avtor, datum, urnik).
  4. Windows storitve s Pythonom (tudi NSSM ovoji).
  5. Samodejni zagon (Run v registru, mapa Startup).
  6. Datoteke skript, v katerih se omenja SAOP API (iCenterAPI, V2/Price, port 81 ...).
  7. Dnevniki dogodkov: namestitev Pythona (MsiInstaller), registracija opravil, prijave uporabnikov.
  8. Z -Ujemi N: N minut caka na naslednji zagon in ujame proces, ki klice SAOP (klici so ob :56 in :00).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File SAOP-python-izvor.ps1
  powershell -ExecutionPolicy Bypass -File SAOP-python-izvor.ps1 -Ujemi 10
#>
[CmdletBinding()]
param(
    [string]$Izhod = 'C:\Temp\SAOP-promet',
    # Minute cakanja na zagon skripte (0 = ne cakaj). Zazeni npr. ob :54 z -Ujemi 10.
    [int]$Ujemi = 0,
    # Porti SAOP API (SaopApi = 81, SaopApiTest = 82).
    [int[]]$Porti = @(81, 82),
    # Kje iskati datoteke skript. Privzeto vsi lokalni diski.
    [string[]]$Poti,
    [string]$Vzorec = 'iCenterAPI|V2/Price|registeredviews|GetItemDeliveryDate|:81/|:82/|priceListID',
    [int]$DniDogodkov = 365,
    [switch]$NeOdpri
)

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

# ---------------------------------------------------------------- procesi (skupno)
$vsiProcesi = @{}
try { Get-CimInstance Win32_Process | ForEach-Object { $vsiProcesi[[int]$_.ProcessId] = $_ } } catch { }
function Opis-Procesa($p) {
    if (-not $p) { return $null }
    $up = ''
    try { $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop; if ($o.User) { $up = "$($o.Domain)\$($o.User)" } } catch { }
    [pscustomobject][ordered]@{
        PID        = $p.ProcessId
        Program    = $p.ExecutablePath
        Ukaz       = $p.CommandLine
        Uporabnik  = $up
        Zagnan     = $p.CreationDate
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

# ---------------------------------------------------------------- 1. namestitve Pythona
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

# ---------------------------------------------------------------- 2. procesi zdaj
Naslov '2. PYTHON PROCESI, KI TECEJO ZDAJ'
Tabela ($vsiProcesi.Values | Where-Object { $_.Name -match '^(python|pythonw|py)\d*(\.\d+)?\.exe$' -or $_.CommandLine -match '\.py(\s|"|$)' } | ForEach-Object { Opis-Procesa $_ })

# ---------------------------------------------------------------- 3. opravila
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

# ---------------------------------------------------------------- 4. storitve
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

# ---------------------------------------------------------------- 5. samodejni zagon
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

# ---------------------------------------------------------------- 6. datoteke skript
Naslov "6. DATOTEKE SKRIPT, KI OMENJAJO SAOP API (vzorec: $Vzorec)"
if (-not $Poti) { $Poti = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $_.DeviceID + '\' }) }
$izpusti = '\\Windows\\|\\WindowsApps\\|\\site-packages\\|\\node_modules\\|\\\$Recycle\.Bin\\|\\WinSxS\\|\\Lib\\test\\|\\inetpub\\logs\\|\\System Volume Information\\|\\Microsoft\.NET\\|\\assembly\\'
$koncnice = @('.py', '.pyw', '.bat', '.cmd', '.ps1', '.vbs', '.ini', '.cfg', '.conf', '.env', '.json', '.yaml', '.yml', '.toml', '.txt')
$najdeno = @()
foreach ($koren in $Poti) {
    Write-Host "Iscem skripte v $koren ..."
    $datoteke = Get-ChildItem -Path $koren -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $koncnice -contains $_.Extension.ToLower() -and $_.Length -lt 5MB -and $_.FullName -notmatch $izpusti }
    foreach ($f in $datoteke) {
        $zad = Select-String -LiteralPath $f.FullName -Pattern $Vzorec -ErrorAction SilentlyContinue | Select-Object -First 3
        if ($zad) {
            $najdeno += [pscustomobject][ordered]@{
                Datoteka   = $f.FullName
                Ustvarjena = $f.CreationTime
                Spremenjena = $f.LastWriteTime
                'Zadnji dostop' = $f.LastAccessTime
                Lastnik    = (Lastnik $f.FullName)
                Vrstice    = (($zad | ForEach-Object { "#$($_.LineNumber): $($_.Line.Trim())" }) -join "`n              ")
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

# ---------------------------------------------------------------- 7. dnevniki dogodkov
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

# ---------------------------------------------------------------- 8. ujemi zagon
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
            if ($p.Name -eq 'w3wp.exe' -and $p.CommandLine -match '-ap "PIM') { }  # PIM je znan, vseeno zapisi
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
Pisi ('Trajanje skripte: {0:N0} s' -f $stoparica.Elapsed.TotalSeconds)
$out | Out-File -FilePath $potPorocila -Encoding UTF8
Write-Host ''
Write-Host "Porocilo: $potPorocila" -ForegroundColor Green
if (-not $NeOdpri) { Start-Process notepad.exe $potPorocila }
