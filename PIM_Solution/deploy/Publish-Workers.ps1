[CmdletBinding(SupportsShouldProcess=$true)]
# Objavi workerje (workers\*\*.csproj) v <Destination>\<Worker>\<Worker>.exe — postavitev, ki jo
# bereta intranet (WorkerConsole:PublishedWorkersRoot, stran /sistem/workerji) in skripte ciklov
# (-MapaWorkerjev, scripts\Workerji.ps1). Ista oblika kot v Configure-WorkerScheduledTasks.ps1, le
# da tu ne registrira nalog: to naredi scripts\Namesti-opravila.ps1 -MapaWorkerjev <Destination>.
#
# Self-contained win-x64 kot Publish-Intranet.ps1: na strezniku ni treba imeti .NET runtime.
#
# Tece v Windows PowerShell 5.1 (powershell) in v PowerShell 7 (pwsh); ne uporablja $IsWindows kot
# Publish-Intranet.ps1, zato pwsh ni potreben. Uporaba (tam, kjer je izvorna koda, iz PIM_Solution):
#   powershell -ExecutionPolicy Bypass -File .\deploy\Publish-Workers.ps1 -Destination C:\PIM\Workerji -DryRun
#   powershell -ExecutionPolicy Bypass -File .\deploy\Publish-Workers.ps1 -Destination C:\PIM\Workerji
#   powershell -ExecutionPolicy Bypass -File .\deploy\Publish-Workers.ps1 -Destination C:\PIM\Workerji -Only PIM.B2bWorker,PIM.Watchdog
param(
  [Parameter(Mandatory=$true)][string]$Destination,
  [string]$Configuration = 'Release',
  [string[]]$Only = @(),
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

$projects = Get-ChildItem (Join-Path $projectRoot 'workers') -Directory |
  ForEach-Object { Get-ChildItem $_.FullName -Filter '*.csproj' -File } |
  Where-Object { $Only.Count -eq 0 -or $Only -contains $_.BaseName }
if (-not $projects) { throw "V $projectRoot\workers ni nobenega projekta$(if ($Only) { " med: $($Only -join ', ')" })." }

foreach ($project in $projects) {
  $name = $project.BaseName
  $target = Join-Path $Destination $name
  if ($DryRun) { Write-Host "DRYRUN: publish $name -> $target\$name.exe"; continue }
  if ($PSCmdlet.ShouldProcess($target, "Publish $name")) {
    dotnet publish $project.FullName -c $Configuration -r win-x64 --self-contained true -o $target --nologo
    if ($LASTEXITCODE -ne 0) { throw "Publish $name ni uspel." }
    if (-not (Test-Path (Join-Path $target "$name.exe"))) { throw "Po objavi ni $target\$name.exe." }
    Write-Host "Objavljen: $target\$name.exe"
  }
}

Write-Host ''
Write-Host "Workerji: $Destination"
Write-Host "Intranet: ce je to mapa Workerji\ ob intranetu (Publish-All.ps1), nastavitev ni potrebna; sicer v appsettings.Local.json"
Write-Host "          ob intranetu WorkerConsole:PublishedWorkersRoot = $Destination (in RepositoryRoot = mapa s scripts\ za cikle)."
Write-Host "Naloge:   powershell -ExecutionPolicy Bypass -File scripts\Namesti-opravila.ps1 [-MapaWorkerjev $Destination]  (odpade, ce je Workerji\ ob korenu)"
Write-Host 'SAOP:     workerji, ki klicejo SAOP, berejo poverilnice iz appsettings.Local.json ob svojem .exe ali iz PIM_SAOP_*.'
