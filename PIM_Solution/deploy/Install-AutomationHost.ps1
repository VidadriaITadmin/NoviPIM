[CmdletBinding(SupportsShouldProcess=$true)]
# Namestitev gostitelja avtomatike (PIM.AutomationHost, migracija 237) kot Windows storitve.
#
# Zakaj storitev in ne IIS: ura v procesu intraneta (221) je bila vezana na aplikacijski bazen -
# recikliranje, deploy ali mirovanje bazena so ustavili tudi avtomatiko, notranji watchdog pa je
# nadziral sam sebe. Storitev tece ne glede na IIS, Windows jo po padcu sam ponovno zazene
# (sc.exe failure), zunanje opravilo pa preveri njen utrip (scripts\Namesti-nadzor-avtomatike.ps1).
#
# Kaj naredi:
#   1. vzame ze objavljen program (objava intraneta odlozi Workerji\PIM.AutomationHost\PIM.AutomationHost.exe
#      ob druge workerje; -BinaryPath) ali ga objavi sam (dotnet publish, self-contained, v InstallRoot);
#   2. dodeli racunu storitve pravico branja in izvajanja (icacls);
#   3. ustvari ali posodobi storitev PIM.AutomationHost (New-Service / sc.exe config), StartupType Automatic;
#   4. nastavi samodejni ponovni zagon ob padcu: 5 s, 10 s, 30 s, stevec se ponastavi po enem dnevu;
#   5. storitev zazene in po zelji registrira zunanji nadzor (-ZunanjiNadzor).
#
# Racun storitve potrebuje: prijavo v SQL Server (Integrated Security) z vlogami, ki jih imajo workerji,
# pravico pisanja v mape iz registra ops.SystemPath (LANDING_ROOT, EXPORT_ROOT, LOG_ROOT) in branje mape
# Workerji\. LocalSystem ni dovoljen (najmanjse pravice, kot pri Install-Workers.ps1).
#
# Povezava do baze: appsettings.Local.json v mapi intraneta nad Workerji\ (isti vir kot workerji) ali
# strojna okoljska spremenljivka PIM_CONNECTION_STRING za racun storitve.
#
# Samo ASCII v tej datoteki (PowerShell 5.1 bere datoteko brez BOM kot ANSI). Uporaba (kot administrator):
#   .\deploy\Install-AutomationHost.ps1 -InstallRoot C:\PIM\Storitve -ServiceAccount 'DOMENA\pim-avtomatika' -DryRun
#   .\deploy\Install-AutomationHost.ps1 -BinaryPath C:\inetpub\wwwroot\PIM\Workerji\PIM.AutomationHost\PIM.AutomationHost.exe -ServiceAccount 'DOMENA\pim-avtomatika' -ZunanjiNadzor
#   .\deploy\Install-AutomationHost.ps1 -Odstrani
param(
  # Mapa, kamor se gostitelj objavi, kadar -BinaryPath ni podan (nastane InstallRoot\PIM.AutomationHost).
  [string]$InstallRoot = '',
  # Ze objavljen program (objava intraneta v eno mapo); takrat se ne objavlja nic.
  [string]$BinaryPath = '',
  [string]$ServiceAccount = '',
  [string]$ServiceName = 'PIM.AutomationHost',
  # Po namestitvi registriraj se nacrtovano nalogo zunanjega nadzora (scripts\Namesti-nadzor-avtomatike.ps1).
  [switch]$ZunanjiNadzor,
  [switch]$Odstrani,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$solutionRoot = Split-Path $PSScriptRoot -Parent
$project = Join-Path $solutionRoot 'workers\PIM.AutomationHost\PIM.AutomationHost.csproj'

if ($Odstrani) {
  if ($DryRun) { Write-Host "DRYRUN: Stop-Service $ServiceName; sc.exe delete $ServiceName"; return }
  $existing = Get-Service $ServiceName -ErrorAction SilentlyContinue
  if (-not $existing) { Write-Host "Storitve $ServiceName ni."; return }
  if ($PSCmdlet.ShouldProcess($ServiceName, 'Ustavi in odstrani storitev')) {
    if ($existing.Status -ne 'Stopped') { Stop-Service $ServiceName -Force }
    & sc.exe delete $ServiceName | Out-Null
    Write-Host "Storitev $ServiceName je odstranjena. Zunanji nadzor odstrani z scripts\Namesti-nadzor-avtomatike.ps1 -Odstrani."
  }
  return
}

if ($ServiceAccount -eq 'LocalSystem' -or $ServiceAccount -eq 'SYSTEM' -or $ServiceAccount -eq 'NT AUTHORITY\SYSTEM') {
  throw 'LocalSystem ni dovoljen; uporabi namenski najmanj privilegiran racun storitve.'
}
if ([string]::IsNullOrWhiteSpace($ServiceAccount)) { throw 'Podaj -ServiceAccount (racun storitve s prijavo v SQL Server).' }
if ([string]::IsNullOrWhiteSpace($BinaryPath) -and [string]::IsNullOrWhiteSpace($InstallRoot)) { throw 'Podaj -BinaryPath (ze objavljen program) ali -InstallRoot (objava).' }

if ([string]::IsNullOrWhiteSpace($BinaryPath)) {
  $target = Join-Path $InstallRoot 'PIM.AutomationHost'
  $BinaryPath = Join-Path $target 'PIM.AutomationHost.exe'
  if ($DryRun) { Write-Host "DRYRUN: dotnet publish $project -c Release -r win-x64 --self-contained true -o $target" }
  elseif ($PSCmdlet.ShouldProcess($target, 'Objavi PIM.AutomationHost')) {
    dotnet publish $project -c Release -r win-x64 --self-contained true -o $target --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Publish PIM.AutomationHost ni uspel.' }
  }
}
elseif (-not $DryRun -and -not (Test-Path $BinaryPath)) { throw "Program ne obstaja: $BinaryPath" }

$binaryDirectory = Split-Path $BinaryPath -Parent
if ($DryRun) {
  Write-Host "DRYRUN: icacls $binaryDirectory /grant ${ServiceAccount}:(OI)(CI)RX"
  Write-Host "DRYRUN: New-Service -Name $ServiceName -BinaryPathName `"$BinaryPath`" -StartupType Automatic -Credential $ServiceAccount"
  Write-Host "DRYRUN: sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000; sc.exe failureflag $ServiceName 1"
  Write-Host "DRYRUN: Start-Service $ServiceName"
  if ($ZunanjiNadzor) { Write-Host "DRYRUN: scripts\Namesti-nadzor-avtomatike.ps1 -Program `"$BinaryPath`"" }
  return
}

if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) { throw 'Namestitev storitve je dovoljena samo v Windows.' }
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Namestitev storitve zahteva PowerShell kot administrator.' }

if ($PSCmdlet.ShouldProcess($binaryDirectory, "Dodeli branje in izvajanje racunu $ServiceAccount")) {
  & icacls $binaryDirectory /grant:r "${ServiceAccount}:(OI)(CI)RX" /T | Out-Null
}

$service = Get-Service $ServiceName -ErrorAction SilentlyContinue
if (-not $service) {
  if ($PSCmdlet.ShouldProcess($ServiceName, 'Ustvari storitev')) {
    New-Service -Name $ServiceName -BinaryPathName "`"$BinaryPath`"" -DisplayName 'PIM gostitelj avtomatike' `
      -Description 'Poganja posle PIM (zajem iz SAOP, validacija, objava, izvozi za splet, nadzor). Konzola je intranet /sistem/opravila.' `
      -StartupType Automatic -Credential (Get-Credential $ServiceAccount) | Out-Null
  }
}
elseif ($PSCmdlet.ShouldProcess($ServiceName, 'Posodobi pot programa')) {
  if ($service.Status -ne 'Stopped') { Stop-Service $ServiceName -Force }
  & sc.exe config $ServiceName binPath= "`"$BinaryPath`"" start= auto | Out-Null
}

if ($PSCmdlet.ShouldProcess($ServiceName, 'Samodejni ponovni zagon ob padcu')) {
  # Tri ponovitve (5 s, 10 s, 30 s), stevec se ponastavi po enem dnevu brez padca; failureflag 1 pomeni,
  # da se ponovni zagon sprozi tudi ob nenicelni izhodni kodi, ne samo ob sesutju.
  & sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
  & sc.exe failureflag $ServiceName 1 | Out-Null
}

if ($PSCmdlet.ShouldProcess($ServiceName, 'Zazeni storitev')) {
  Start-Service $ServiceName
  Start-Sleep -Seconds 3
  Write-Host ("Storitev {0}: {1}" -f $ServiceName, (Get-Service $ServiceName).Status)
}

if ($ZunanjiNadzor) {
  $monitor = Join-Path (Split-Path $solutionRoot -Parent) 'scripts\Namesti-nadzor-avtomatike.ps1'
  if (-not (Test-Path $monitor)) { $monitor = Join-Path $solutionRoot 'scripts\Namesti-nadzor-avtomatike.ps1' }
  if (Test-Path $monitor) { & powershell -NoProfile -ExecutionPolicy Bypass -File $monitor -Program $BinaryPath }
  else { Write-Warning "Skripte zunanjega nadzora ni: $monitor. Registriraj jo rocno." }
}

Write-Host ''
Write-Host 'Preveri: /sistem/opravila (Gostitelj: Tece), Get-Service PIM.AutomationHost, dnevnik <LOG_ROOT>\gostitelj\gostitelj-<datum>.log.'
Write-Host 'Zunanji nadzor (vsakih 5 min, alarm ob 10 min molka): scripts\Namesti-nadzor-avtomatike.ps1 -Program <pot do PIM.AutomationHost.exe>.'
