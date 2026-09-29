<#
.SYNOPSIS
  Namesti ali posodobi PIM bralni API kot IIS spletno mesto (poženi na strežniku kot skrbnik).

.DESCRIPTION
  Skripta leži v objavljeni mapi (Publish-Api.ps1 jo kopira zraven PIM.Api.exe). Naredi:
    1. preveri IIS in ASP.NET Core Hosting Bundle (modul AspNetCoreModuleV2);
    2. ustvari aplikacijsko skupino (brez .NET CLR, vedno zagnana), če je ni;
    3. prekopira datoteke v mapo spletnega mesta (appsettings.Local.json in logs ostaneta);
    4. ob prvi namestitvi ustvari appsettings.Local.json s povezavo (Windows prijava aplikacijske skupine);
    5. ustvari spletno mesto na izbranih vratih, če ga ni;
    6. v bazi ustvari prijavo in uporabnika za aplikacijsko skupino ter ga doda v vlogo pim_api_reader
       (samo branje prek sheme api; migracija 287 mora biti uveljavljena);
    7. preveri /health.

  Posodobitev: ponovno poženi isto skripto iz nove objavljene mape.

.PARAMETER SqlServer
  SQL strežnik z bazo PIM, npr. STREZNIK\MSSQLSERVER3.

.PARAMETER SqlLogin
  Windows prijava, s katero API dostopa do baze. Privzeto IIS APPPOOL\<AppPool> (SQL na istem računalniku
  kot IIS). Če je SQL na drugem strežniku, podaj račun računalnika z IIS, npr. DOMENA\IISSTREZNIK$, ali
  namenski domenski račun (takrat ga nastavi tudi kot identiteto aplikacijske skupine).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Install-PimApi.ps1 -SqlServer 'SRV-PIM\MSSQLSERVER3'
  powershell -ExecutionPolicy Bypass -File .\Install-PimApi.ps1 -SqlServer 'SRV-SQL' -SqlLogin 'VIDADRIA\SRV-IIS$' -Port 5095 -OpenFirewall
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$SqlServer,
  [string]$Database = "PIM",
  [string]$SiteName = "PIM-API",
  [string]$AppPool = "PIM-API",
  [string]$SitePath = "C:\inetpub\PIM-API",
  [int]$Port = 5095,
  [string]$SqlLogin = "",
  [switch]$SkipSql,
  [switch]$OpenFirewall
)

$ErrorActionPreference = "Stop"
function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Poženi PowerShell kot skrbnik (Run as administrator)." }
$source = $PSScriptRoot
if (-not (Test-Path (Join-Path $source "PIM.Api.exe"))) { throw "V mapi $source ni PIM.Api.exe. Skripto poženi iz objavljene mape (Publish-Api.ps1)." }
if (-not $SqlLogin) { $SqlLogin = "IIS APPPOOL\$AppPool" }

Step "1/7 IIS in Hosting Bundle"
Import-Module WebAdministration
if (-not (Get-WebGlobalModule -Name AspNetCoreModuleV2 -ErrorAction SilentlyContinue)) {
  throw "Manjka ASP.NET Core Hosting Bundle 10 (modul AspNetCoreModuleV2). Namesti ga in poženi iisreset (isto kot za intranet, docs/PUBLISH.md)."
}
Write-Host "OK"

Step "2/7 Aplikacijska skupina $AppPool"
if (-not (Test-Path "IIS:\AppPools\$AppPool")) { New-WebAppPool -Name $AppPool | Out-Null; Write-Host "ustvarjena" }
Set-ItemProperty "IIS:\AppPools\$AppPool" -Name managedRuntimeVersion -Value ""
Set-ItemProperty "IIS:\AppPools\$AppPool" -Name startMode -Value "AlwaysRunning"
Set-ItemProperty "IIS:\AppPools\$AppPool" -Name processModel.idleTimeout -Value ([TimeSpan]::Zero)
Write-Host "OK (brez .NET CLR, vedno zagnana)"

Step "3/7 Datoteke v $SitePath"
New-Item -ItemType Directory -Force -Path $SitePath | Out-Null
$siteExists = [bool](Get-Website -Name $SiteName -ErrorAction SilentlyContinue)
$offline = Join-Path $SitePath "app_offline.htm"
if ($siteExists) { Set-Content -Path $offline -Value "<html><body>PIM API se posodablja.</body></html>" -Encoding UTF8; Start-Sleep -Seconds 3 }
& robocopy $source $SitePath /E /NFL /NDL /NJH /NJS /NP /XF appsettings.Local.json app_offline.htm /XD logs | Out-Null
if ($LASTEXITCODE -ge 8) { throw "Kopiranje ni uspelo (robocopy $LASTEXITCODE)." }
Write-Host "OK"

Step "4/7 Nastavitve (appsettings.Local.json)"
$local = Join-Path $SitePath "appsettings.Local.json"
if (-not (Test-Path $local)) {
  $connection = "Server=$SqlServer;Database=$Database;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Application Name=PIM.Api"
  $settings = [ordered]@{
    ConnectionStrings = [ordered]@{ PimApi = $connection }
    Api = [ordered]@{ AllowedRemoteIps = @(); PublicBaseUrl = "" }
  }
  $settings | ConvertTo-Json -Depth 5 | Set-Content -Path $local -Encoding UTF8
  Write-Host "ustvarjena: $local"
} else {
  Write-Host "že obstaja, ne spreminjam: $local"
}

Step "5/7 Spletno mesto $SiteName (vrata $Port)"
if (-not $siteExists) {
  New-Website -Name $SiteName -PhysicalPath $SitePath -ApplicationPool $AppPool -Port $Port | Out-Null
  Write-Host "ustvarjeno"
} else {
  Set-ItemProperty "IIS:\Sites\$SiteName" -Name applicationPool -Value $AppPool
  Write-Host "obstaja"
}
if ($OpenFirewall) {
  if (-not (Get-NetFirewallRule -DisplayName "PIM API $Port" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "PIM API $Port" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
  }
  Write-Host "požarni zid: vrata $Port odprta"
}

Step "6/7 Uporabnik baze za API ($SqlLogin → vloga pim_api_reader)"
if ($SkipSql) {
  Write-Host "preskočeno (-SkipSql). Ročno v SSMS:" -ForegroundColor Yellow
  Write-Host "  CREATE LOGIN [$SqlLogin] FROM WINDOWS;  USE [$Database];  CREATE USER [$SqlLogin] FOR LOGIN [$SqlLogin];  ALTER ROLE pim_api_reader ADD MEMBER [$SqlLogin];"
} else {
  if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) { throw "sqlcmd ni v PATH. Namesti sqlcmd ali poženi z -SkipSql in ukaze izvedi v SSMS." }
  $login = $SqlLogin.Replace("]", "]]")
  $sql = @"
SET NOCOUNT ON;
IF DATABASE_PRINCIPAL_ID(N'pim_api_reader') IS NULL THROW 52876, N'V bazi ni vloge pim_api_reader: najprej uveljavi migracijo 287.', 1;
IF SUSER_ID(N'$login') IS NULL EXEC(N'CREATE LOGIN [$login] FROM WINDOWS');
IF USER_ID(N'$login') IS NULL EXEC(N'CREATE USER [$login] FOR LOGIN [$login]');
IF IS_ROLEMEMBER(N'pim_api_reader', N'$login') = 0 EXEC(N'ALTER ROLE pim_api_reader ADD MEMBER [$login]');
PRINT N'OK';
"@
  & sqlcmd -S $SqlServer -d $Database -E -I -b -Q $sql
  if ($LASTEXITCODE -ne 0) { throw "Ustvarjanje uporabnika baze ni uspelo." }
}

Step "7/7 Zagon in preverjanje"
if (Test-Path $offline) { Remove-Item $offline -Force }
Restart-WebAppPool -Name $AppPool -ErrorAction SilentlyContinue
if ((Get-Website -Name $SiteName).State -ne "Started") { Start-Website -Name $SiteName }
Start-Sleep -Seconds 3
try {
  $health = Invoke-RestMethod -Uri "http://localhost:$Port/health" -TimeoutSec 30
  Write-Host "zdravje: $($health.status), baza: $($health.database)" -ForegroundColor Green
} catch {
  Write-Host "Preverjanje /health ni uspelo: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "Poglej dnevnik dogodkov (Application) ali vklopi stdoutLogEnabled v web.config." -ForegroundColor Yellow
  exit 1
}

Write-Host ""
Write-Host "API teče na http://localhost:$Port  (navodila za AI: /api/v1/guide, OpenAPI: /openapi.json, MCP: /mcp)" -ForegroundColor Green
Write-Host "Ključ za odjemalca ustvari (kot skrbnik baze):"
Write-Host "  & '$SitePath\PIM.Api.exe' odjemalec dodaj --ime ""Claude analitika"" --podjetja 2,3 --podrocja izdelki,cene,zaloga"
