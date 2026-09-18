[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [ValidateSet('win-x64')][string]$Runtime = 'win-x64',
  [ValidateSet('Debug','Release')][string]$Configuration = 'Release',
  [switch]$Replace
)

# Ta skripta tece na razvojnem/racunskem racunalniku, NE na IIS strezniku.
# Naredi samostojen Windows paket, zato ciljni IIS streznik ne potrebuje SDK-ja niti repozitorija.
$ErrorActionPreference = 'Stop'
$solutionRoot = Split-Path $PSScriptRoot -Parent
$output = [IO.Path]::GetFullPath($OutputDirectory)

if (Test-Path $output) {
  if (-not $Replace) {
    throw "Izhodna mapa ze obstaja: $output. Uporabi novo mapo ali dodaj -Replace."
  }
  Remove-Item $output -Recurse -Force
}

foreach ($command in @('dotnet')) {
  if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
    throw "Manjka predpogoj: $command"
  }
}

$intranet = Join-Path $output 'intranet'
$database = Join-Path $output 'database'
New-Item -ItemType Directory -Path $intranet, $database | Out-Null

function Invoke-DotnetPublish([string]$Project, [string]$Destination) {
  & dotnet publish $Project -c $Configuration -r $Runtime --self-contained true -o $Destination
  if ($LASTEXITCODE -ne 0) { throw "Publish ni uspel: $Project" }
}

Invoke-DotnetPublish (Join-Path $solutionRoot 'src\PIM.Intranet\PIM.Intranet.csproj') $intranet
Invoke-DotnetPublish (Join-Path $solutionRoot 'src\PIM.Migrator\PIM.Migrator.csproj') $database

Copy-Item (Join-Path $solutionRoot 'sql\migrations') (Join-Path $database 'migrations') -Recurse -Force
Copy-Item (Join-Path $solutionRoot 'deploy\portable\Apply-PimDatabase.ps1') (Join-Path $database 'Apply-PimDatabase.ps1') -Force
Copy-Item (Join-Path $solutionRoot 'deploy\portable\Zazeni-Pim-Migracije.ps1') (Join-Path $database 'migrations\Zazeni-Pim-Migracije.ps1') -Force
Copy-Item (Join-Path $solutionRoot 'deploy\portable\Install-PimIntranet.ps1') (Join-Path $output 'Install-PimIntranet.ps1') -Force
Copy-Item (Join-Path $solutionRoot 'appsettings.Local.example.json') (Join-Path $output 'appsettings.Local.example.json') -Force
Copy-Item (Join-Path $solutionRoot 'deploy\PORTABLE_RELEASE.md') (Join-Path $output 'README-DEPLOY.md') -Force

$manifest = [ordered]@{
  CreatedUtc = [DateTime]::UtcNow.ToString('O')
  Runtime = $Runtime
  Configuration = $Configuration
  Intranet = 'intranet'
  DatabaseMigrator = 'database\PIM.Migrator.exe'
  Migrations = 'database\migrations'
} | ConvertTo-Json
Set-Content -Path (Join-Path $output 'release-manifest.json') -Value $manifest -Encoding utf8

Write-Host "Release paket je pripravljen: $output"
Write-Host 'Na streznik prenesi CELOTNO to mapo. Ne prenasaj appsettings.Local.json iz razvoja.'
