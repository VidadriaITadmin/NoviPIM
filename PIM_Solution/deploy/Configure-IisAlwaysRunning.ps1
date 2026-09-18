[CmdletBinding(SupportsShouldProcess=$true)]
# Razporejevalnik v aplikaciji (2026-09-17, migracija 221) tece znotraj procesa intraneta. Pod IIS
# to pomeni dvoje, cesar privzet aplikacijski bazen ne zagotavlja:
#
#   1. bazen brez zahtev IIS po 20 minutah ugasne (idleTimeout) - in z njim uro. Intranet se sicer
#      sam klice na /health (WorkerSchedulerService, Scheduler:KeepAliveMinutes), a sele po prvi
#      zahtevi, ko ze pozna svoj naslov;
#   2. po recikliranju bazena (privzeto vsakih 29 ur) nov proces nastane sele ob prvi zahtevi -
#      ce ponoci nihce ne odpre intraneta, nocni tok ob 02:30 ne stece.
#
# Ta skripta nastavi bazen na "Always running" in mestu vklopi predhodno nalaganje (Application
# Initialization), da IIS proces zazene sam ob zagonu in po vsakem recikliranju. Sistemska
# nastavitev je (AGENTS.md #4.7): pozene jo skrbnik streznika kot administrator, ne agent.
#
# Uporaba (PowerShell kot administrator, na strezniku z IIS):
#   .\deploy\Configure-IisAlwaysRunning.ps1 -SiteName PIM -AppPoolName PIM -DryRun
#   .\deploy\Configure-IisAlwaysRunning.ps1 -SiteName PIM -AppPoolName PIM
#
# Ce IIS nima modula Application Initialization, ga skripta namesti (Windows Server: vloga
# Web-AppInit; Windows 10/11: funkcija IIS-ApplicationInit).
param(
  [Parameter(Mandatory=$true)][string]$SiteName,
  [Parameter(Mandatory=$true)][string]$AppPoolName,
  # Virtualna aplikacija znotraj mesta (npr. /PIM); prazno pomeni koren mesta.
  [string]$ApplicationPath = '',
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

if ($DryRun) {
  Write-Host "DRYRUN: bazen $AppPoolName -> startMode=AlwaysRunning, idleTimeout=0, recycling.periodicRestart.time=0 (brez rednega recikliranja po casu)"
  Write-Host "DRYRUN: mesto $SiteName$ApplicationPath -> preloadEnabled=true (Application Initialization)"
  Write-Host "DRYRUN: preveri modul Application Initialization (Web-AppInit / IIS-ApplicationInit)"
  return
}

$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Nastavitev IIS zahteva PowerShell kot administrator.'
}

Import-Module WebAdministration

# Modul Application Initialization: brez njega preloadEnabled ne naredi nicesar.
$initInstalled = $false
if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
  $feature = Get-WindowsFeature Web-AppInit
  if ($feature -and -not $feature.Installed -and $PSCmdlet.ShouldProcess('Web-AppInit', 'Namesti Application Initialization')) {
    Install-WindowsFeature Web-AppInit | Out-Null
  }
  $initInstalled = (Get-WindowsFeature Web-AppInit).Installed
}
elseif (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
  $feature = Get-WindowsOptionalFeature -Online -FeatureName IIS-ApplicationInit
  if ($feature -and $feature.State -ne 'Enabled' -and $PSCmdlet.ShouldProcess('IIS-ApplicationInit', 'Vklopi Application Initialization')) {
    Enable-WindowsOptionalFeature -Online -FeatureName IIS-ApplicationInit -All -NoRestart | Out-Null
  }
  $initInstalled = (Get-WindowsOptionalFeature -Online -FeatureName IIS-ApplicationInit).State -eq 'Enabled'
}

$pool = "IIS:\AppPools\$AppPoolName"
if (-not (Test-Path $pool)) { throw "Aplikacijski bazen ne obstaja: $AppPoolName" }
if ($PSCmdlet.ShouldProcess($AppPoolName, 'Always running, brez mirovanja in brez rednega recikliranja')) {
  Set-ItemProperty $pool -Name startMode -Value 'AlwaysRunning'
  Set-ItemProperty $pool -Name processModel.idleTimeout -Value ([TimeSpan]::Zero)
  # Redno recikliranje po 29 urah ni potrebno; ce ga streznik hoce, naj ga nastavi ob uri, ko
  # nobeden od ciklov ne tece (glej /sistem/workerji), sicer bo tek prekinjen in oznacen Cancelled.
  Set-ItemProperty $pool -Name recycling.periodicRestart.time -Value ([TimeSpan]::Zero)
}

$sitePath = "IIS:\Sites\$SiteName"
if (-not (Test-Path $sitePath)) { throw "Spletno mesto ne obstaja: $SiteName" }
$target = if ([string]::IsNullOrWhiteSpace($ApplicationPath)) { $sitePath } else { "$sitePath$ApplicationPath" }
if ($PSCmdlet.ShouldProcess($target, 'Predhodno nalaganje (preloadEnabled)')) {
  Set-ItemProperty $target -Name applicationDefaults.preloadEnabled -Value $true -ErrorAction SilentlyContinue
  Set-ItemProperty $target -Name preloadEnabled -Value $true -ErrorAction SilentlyContinue
}

Write-Host "Bazen $AppPoolName: startMode=$((Get-ItemProperty $pool -Name startMode).ToString()), idleTimeout=$((Get-ItemProperty $pool -Name processModel.idleTimeout).ToString())"
Write-Host "Mesto $SiteName$ApplicationPath: preloadEnabled nastavljen."
if (-not $initInstalled) {
  Write-Warning 'Modul Application Initialization ni namescen/vklopljen; po recikliranju bazena bo intranet (in razporejevalnik) stekel sele ob prvi zahtevi.'
}
Write-Host 'Preveri na /sistem/workerji: "Razporejevalnik: Teče v tej aplikaciji", pod IIS pa tudi cas zadnjega samodejnega utripa.'
