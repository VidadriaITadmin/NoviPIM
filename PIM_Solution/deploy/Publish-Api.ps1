<#
.SYNOPSIS
  Objavi PIM bralni API (src\PIM.Api) v mapo, ki se jo prenese na strežnik.

.DESCRIPTION
  Samostojna objava (self-contained, win-x64): na strežniku .NET ni potreben, za IIS pa ASP.NET Core
  Hosting Bundle 10 (isti kot za intranet). appsettings.Local.json se NE objavi — na strežniku ostane
  tista, ki jo tam postavi skrbnik (Install-PimApi.ps1 je ne povozi).

  Navodila: Navodila\08_API_za_AI.md, tehnično: docs\API.md.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File PIM_Solution\deploy\Publish-Api.ps1
  powershell -ExecutionPolicy Bypass -File PIM_Solution\deploy\Publish-Api.ps1 -Output D:\prenos\PIM-API
#>
[CmdletBinding()]
param(
  [string]$Output = ""
)

$ErrorActionPreference = "Stop"
$solution = Split-Path -Parent $PSScriptRoot
$project = Join-Path $solution "src\PIM.Api\PIM.Api.csproj"
if (-not $Output) { $Output = Join-Path (Split-Path -Parent $solution) ("publish_api_" + (Get-Date -Format "yyyy-MM-dd")) }

Write-Host "Objavljam PIM.Api v $Output ..." -ForegroundColor Cyan
& dotnet publish $project -c Release -r win-x64 --self-contained true -o $Output --nologo -v q
if ($LASTEXITCODE -ne 0) { throw "dotnet publish ni uspel (koda $LASTEXITCODE)." }

$local = Join-Path $Output "appsettings.Local.json"
if (Test-Path $local) { Remove-Item $local -Force }
Copy-Item (Join-Path $PSScriptRoot "Install-PimApi.ps1") $Output -Force

Write-Host ""
Write-Host "Končano. Mapo $Output prenesi na strežnik in tam poženi (kot skrbnik):" -ForegroundColor Green
Write-Host "  powershell -ExecutionPolicy Bypass -File <mapa>\Install-PimApi.ps1 -SqlServer 'STREZNIK\INSTANCA'"
