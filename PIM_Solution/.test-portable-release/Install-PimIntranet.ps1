[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Destination,
  [Parameter(Mandatory=$true)][string]$SiteName,
  [Parameter(Mandatory=$true)][string]$HealthUrl,
  [ValidateScript({ Test-Path $_ -PathType Leaf })][string]$ConfigFile
)

# Ta skripta tece na IIS strezniku kot Administrator.
# Vir je vedno mapa intranet ob tej skripti; Destination, SiteName in URL so namensko parametri.
$ErrorActionPreference = 'Stop'
Import-Module WebAdministration

$source = Join-Path $PSScriptRoot 'intranet'
if (-not (Test-Path $source -PathType Container)) { throw "Mapa publish intraneta ne obstaja: $source" }
if (-not (Test-Path "IIS:\Sites\$SiteName")) { throw "IIS site ne obstaja: $SiteName" }

$destination = [IO.Path]::GetFullPath($Destination)
$parent = Split-Path $destination -Parent
if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stage = "$destination.new-$stamp"
$backup = "$destination.backup-$stamp"
$failed = "$destination.failed-$stamp"
$oldConfig = Join-Path $destination 'appsettings.Local.json'
$stageConfig = Join-Path $stage 'appsettings.Local.json'

try {
  Copy-Item $source $stage -Recurse -Force

  if ($ConfigFile) {
    Copy-Item (Resolve-Path $ConfigFile).Path $stageConfig -Force
  } elseif (Test-Path $oldConfig -PathType Leaf) {
    Copy-Item $oldConfig $stageConfig -Force
  } else {
    throw 'Prva objava potrebuje -ConfigFile C:\PIM\Config\appsettings.Local.json.'
  }

  Stop-WebSite -Name $SiteName
  if (Test-Path $destination) { Move-Item $destination $backup }
  Move-Item $stage $destination
  Start-WebSite -Name $SiteName

  $response = Invoke-WebRequest -Uri $HealthUrl -TimeoutSec 30
  if ($response.StatusCode -ne 200) { throw "Health endpoint je vrnil HTTP $($response.StatusCode)." }
  Write-Host "Intranet je objavljen. Prejsnja verzija je: $backup"
}
catch {
  Write-Error 'Objava ni uspela; izvaja se povrnitev prejsnje mape.'
  Stop-WebSite -Name $SiteName -ErrorAction SilentlyContinue
  if (Test-Path $destination) { Move-Item $destination $failed }
  if (Test-Path $backup) { Move-Item $backup $destination }
  Start-WebSite -Name $SiteName -ErrorAction SilentlyContinue
  throw
}
finally {
  if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
}
