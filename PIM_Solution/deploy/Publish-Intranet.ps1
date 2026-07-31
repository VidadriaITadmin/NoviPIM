[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
# Uporaba: -WhatIf za PowerShell simulacijo ali -DryRun za determinističen predogled.
param(
  [Parameter(Mandatory=$true)][string]$Destination,
  [string]$SiteName = 'PIM',
  [string]$HealthUrl = 'http://localhost/health',
  [string]$Configuration = 'Release',
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$publishRoot = Join-Path ([IO.Path]::GetTempPath()) ("pim-publish-" + [guid]::NewGuid())
$backupRoot = "$Destination.backup"
$localConfig = Join-Path $Destination 'appsettings.Local.json'
$savedConfig = Join-Path ([IO.Path]::GetTempPath()) ("pim-local-" + [guid]::NewGuid() + '.json')
$offline = Join-Path $Destination 'app_offline.htm'

function Show-Step([string]$Text) { Write-Host ("DRYRUN: " + $Text) }
if ($DryRun) {
  Show-Step "preveri IIS, dotnet in pravice za $Destination"
  Show-Step "dotnet publish win-x64 --self-contained true"
  Show-Step "ohrani appsettings.Local.json, ustvari app_offline.htm in backup"
  Show-Step "atomsko zamenjaj deploy, preveri health $HealthUrl, ob napaki izvedi rollback"
  exit 0
}
if (-not $IsWindows) { throw 'Dejanski IIS deploy je dovoljen samo v Windows; uporabi -DryRun.' }
foreach ($command in @('dotnet','Get-WebSite')) { if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Manjka predpogoj: $command" } }
Import-Module WebAdministration
if (-not (Test-Path "IIS:\Sites\$SiteName")) { throw "IIS spletno mesto ne obstaja: $SiteName" }
try {
  if ($PSCmdlet.ShouldProcess($Destination, 'Objavi intranet PIM')) {
    dotnet publish (Join-Path $projectRoot 'src/PIM.Intranet/PIM.Intranet.csproj') -c $Configuration -r win-x64 --self-contained true -o $publishRoot
    if ($LASTEXITCODE -ne 0) { throw 'Publish ni uspel.' }
    if (Test-Path $localConfig) { Copy-Item $localConfig $savedConfig -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Set-Content -Path $offline -Value '<h1>Vzdrževanje PIM</h1>' -Encoding UTF8
    if (Test-Path $backupRoot) { Remove-Item $backupRoot -Recurse -Force }
    Move-Item $Destination $backupRoot
    Move-Item $publishRoot $Destination
    if (Test-Path $savedConfig) { Copy-Item $savedConfig (Join-Path $Destination 'appsettings.Local.json') -Force }
    Remove-Item (Join-Path $Destination 'app_offline.htm') -Force -ErrorAction SilentlyContinue
    $response = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 30
    if ($response.StatusCode -ne 200) { throw "Health endpoint je vrnil $($response.StatusCode)." }
  }
} catch {
  Write-Error 'Deploy ni uspel; izvaja se rollback brez izpisa skrivnosti.'
  if ((Test-Path $backupRoot) -and $PSCmdlet.ShouldProcess($Destination, 'Rollback')) {
    $failed = "$Destination.failed"
    if (Test-Path $failed) { Remove-Item $failed -Recurse -Force }
    if (Test-Path $Destination) { Move-Item $Destination $failed }
    Move-Item $backupRoot $Destination
    Remove-Item (Join-Path $Destination 'app_offline.htm') -Force -ErrorAction SilentlyContinue
  }
  throw
} finally {
  Remove-Item $publishRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $savedConfig -Force -ErrorAction SilentlyContinue
}
