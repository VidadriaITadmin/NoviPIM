[CmdletBinding(SupportsShouldProcess=$true)]
# Ena objava, ena mapa: intranet + Workerji\ + scripts\. Tanka ovojnica okoli `dotnet publish` intraneta:
# workerje in skripte zraven objavi ze sam projekt (cilj PimPublishWorkersAndScripts v PIM.Intranet.csproj),
# zato je enakovredno tudi goli ukaz
#   dotnet publish PIM_Solution\src\PIM.Intranet\PIM.Intranet.csproj -c Release -r win-x64 --self-contained true -o <mapa>
# Ta skripta doda samo: -BrezWorkerjev (= -p:PublishWorkers=false), varnostni izbris appsettings.Local.json
# in izpis korakov za streznik.
#
# Mapo prekopiras cez mapo spletnega mesta (npr. C:\inetpub\wwwroot\PIM_test_app) in vse najde vse samo:
#   - intranet (/sistem/workerji) najde Workerji\ in scripts\ ob sebi (WorkerConsoleLayout),
#   - skripte ciklov najdejo Workerji\ ob korenu (Workerji.ps1) in appsettings.Local.json v korenu,
#   - Namesti-opravila.ps1 registrira naloge z isto mapo brez -MapaWorkerjev.
#
# Zakaj to sme v mapo spletnega mesta, ceprav SystemPaths (migracija 173) svari pred njo: tam gre za
# datoteke, ki NASTAJAJO (izvozi, prevzem, dnevniki) in bi jih naslednja objava pobrisala. Workerji in
# skripte so koda - naj jih naslednja objava zamenja. Izvozi gredo v EXPORT_ROOT, prevzem v LANDING_ROOT
# (oba /administracija/mape, izven mape spletnega mesta), dnevniki v <mapa>\logs (robocopy /XD logs jih ohrani).
#
# appsettings.Local.json NIKOLI ni del objave (PIM.Intranet.csproj ga izloci; tu ga za vsak primer se
# pobrisemo): na strezniku ostane tisti, ki je ze tam, s povezavo na tamkajsnjo bazo.
#
# Samo ASCII v tej datoteki: PowerShell 5.1 jo brez BOM bere kot ANSI in pomisljaj v nizu razpade v
# narekovaj, ki niz zakljuci. Tece v powershell (5.1) in pwsh. Uporaba (na razvojnem racunalniku):
#   powershell -ExecutionPolicy Bypass -File .\PIM_Solution\deploy\Publish-All.ps1 -Destination C:\PIM_publish\PIM_test_app -DryRun
#   powershell -ExecutionPolicy Bypass -File .\PIM_Solution\deploy\Publish-All.ps1 -Destination C:\PIM_publish\PIM_test_app
#   powershell -ExecutionPolicy Bypass -File .\PIM_Solution\deploy\Publish-All.ps1 -Destination C:\PIM_publish\PIM_test_app -BrezWorkerjev
# Prenos na streznik: docs\PUBLISH.md, korak 1.4.
param(
  [Parameter(Mandatory=$true)][string]$Destination,
  [string]$Configuration = 'Release',
  # Samo intranet; Workerji\ in scripts\ v Destination ostanejo, kot so (hitrejsa objava popravka intraneta).
  [switch]$BrezWorkerjev,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent   # PIM_Solution
$intranet = Join-Path $projectRoot 'src\PIM.Intranet\PIM.Intranet.csproj'
$publishWorkers = if ($BrezWorkerjev) { 'false' } else { 'true' }

if ($DryRun) {
  Write-Host "DRYRUN: dotnet publish PIM.Intranet -c $Configuration -r win-x64 --self-contained true -o $Destination -p:PublishWorkers=$publishWorkers"
  if (-not $BrezWorkerjev) { Write-Host "DRYRUN:   (csproj zraven objavi workers\*\*.csproj -> $Destination\Workerji\<Worker>\ in scripts\*.ps1, *.vbs -> $Destination\scripts)" }
  Write-Host "DRYRUN: pobrisi $Destination\appsettings.Local.json, ce bi ga publish vseeno prinesel"
  return
}

if ($PSCmdlet.ShouldProcess($Destination, 'Objavi intranet, workerje in skripte')) {
  dotnet publish $intranet -c $Configuration -r win-x64 --self-contained true -o $Destination "-p:PublishWorkers=$publishWorkers" --nologo
  if ($LASTEXITCODE -ne 0) { throw 'Publish ni uspel.' }
  $local = Join-Path $Destination 'appsettings.Local.json'
  if (Test-Path $local) { Remove-Item $local -Force; Write-Host "Pobrisan $local - lokalna nastavitev ne gre na streznik." }
}

$workers = @(Get-ChildItem (Join-Path $Destination 'Workerji') -Directory -ErrorAction SilentlyContinue)
$scripts = @(Get-ChildItem (Join-Path $Destination 'scripts') -File -ErrorAction SilentlyContinue)
Write-Host ''
Write-Host "Objava je v $Destination ($($workers.Count) workerjev, $($scripts.Count) skript). Na strezniku (docs\PUBLISH.md 1.4):"
Write-Host '  1. povezava mora biti v appsettings.Local.json v mapi spletnega mesta (ne v appsettings.json - tega objava prepise),'
Write-Host '  2. app_offline.htm v mapo spletnega mesta, prekopiraj vse cez (robocopy /MIR /XF appsettings.Local.json app_offline.htm /XD logs izvoz), app_offline.htm stran,'
Write-Host '  3. prvic: powershell -ExecutionPolicy Bypass -File scripts\Namesti-opravila.ps1  (Workerji\ najde sam).'
