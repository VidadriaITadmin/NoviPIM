[CmdletBinding(SupportsShouldProcess=$true)]
# Namesti in razporedi "zazeni in koncaj" workerje, ki jih Configure-ScheduledTasks.ps1
# (Watchdog/AlertDispatcher) ne pokriva: SAOP katalog, SAOP zaloga, SAOP datumi dobave, Magento
# artikli/stranke, Magento cene/zaloga. Najdeno 2026-09-14 na razvojnem racunalniku, tu preneseno na
# namenski streznik: (1) worker mora imeti aktiven razpored v ops.ScheduleProfile, preden prvi zagon
# uspe - SAOP vrstice dodajo migracije 043/112/164, MAGENTO_PRODUCTS in MAGENTO_STOCK_PRICES
# migracija 201 (v SONJA/PIM so bile prej dodane rocno); (2) navaden Scheduled Task z .bat akcijo na
# "Run only when user is logged on" vsakic odpre vidno CMD okno - tu se zato vsak worker zazene prek
# skrite VBScript ovojnice (WScript.Shell.Run ..., 0, True), enako kot je bilo popravljeno na dev
# stroju; (3) SAOP workerja brez PIM_SAOP_MODE=Live SAOP-a sploh ne poklieta (izpiseta, kaj bi
# poklicala, in koncata z 0) - .bat ga zato nastavi.
#
# SAOP katalog (2026-09-15): brez njega na strezniku nihce ne bere artiklov iz SAOP, zato novi
# artikli, spremembe in polja z naknadno dodano preslikavo (npr. VATRateID -> Product.VatRateId)
# ne pridejo v PIM. Delta vsako uro bere samo spremenjene artikle; tedenski poln zajem pobere tudi
# polja, ki so bila preslikana po zadnjem branju, ker jih delta pri nespremenjenih artiklih ne vidi.
#
# Uporaba (na ciljnem strezniku, po git clone in rocni namestitvi appsettings.Local.json -
# skrivnosti se NE prenasajo prek tega skripta, glej README-Windows.md):
#   .\deploy\Configure-WorkerScheduledTasks.ps1 -InstallRoot C:\PIM -ExportRoot C:\PIM\Izvoz\Magento -DryRun
#   .\deploy\Configure-WorkerScheduledTasks.ps1 -InstallRoot C:\PIM -ExportRoot C:\PIM\Izvoz\Magento
param(
  [Parameter(Mandatory=$true)][string]$InstallRoot,
  [Parameter(Mandatory=$true)][string]$ExportRoot,
  [int[]]$Organizations = @(1,2,3,4),
  [switch]$DryRun
)
$ErrorActionPreference='Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$scriptsDir = Join-Path $InstallRoot 'Scripts'

# Vsak vnos: kam se publisha (Worker), ime naloge, dodatni argumenti, razmik v minutah, ali gre za
# B2bWorker (ki rabi zanko po podjetjih - SAOP workerja to pocneta sama znotraj sebe) in ali worker
# klice SAOP (Saop=$true -> PIM_SAOP_MODE=Live).
$jobs = @(
  @{ Worker='PIM.KatalogWorker';   TaskName='PIM-SaopKatalog';       Args='--max-parallel 4';         Minutes=60;    PerOrg=$false; Saop=$true },
  @{ Worker='PIM.KatalogWorker';   TaskName='PIM-SaopKatalogPoln';   Args='--full --max-parallel 4';  Minutes=10080; PerOrg=$false; Saop=$true },
  @{ Worker='PIM.SaopStockWorker'; TaskName='PIM-SaopStockWorker';   Args='--po-urniku';              Minutes=5;     PerOrg=$false; Saop=$true },
  @{ Worker='PIM.SaopStockWorker'; TaskName='PIM-SaopDeliveryDates'; Args='--dostave --po-urniku';    Minutes=30;    PerOrg=$false; Saop=$true },
  # --osvezi-validacijo: pred izvozom val.RunValidation + val.Promote (na tem strezniku ju nihce
  # drug ne pozene), sicer katalog ne dobi novo oznacenih/popravljenih artiklov.
  @{ Worker='PIM.B2bWorker';       TaskName='PIM-MagentoProducts';   Args='--export-magento --osvezi-validacijo --po-urniku';   Minutes=120; PerOrg=$true; Saop=$false },
  @{ Worker='PIM.B2bWorker';       TaskName='PIM-MagentoStockPrices';Args='--export-profile MAGENTO_STOCK_PRICES --po-urniku';  Minutes=5;   PerOrg=$true; Saop=$false }
)

if ($DryRun) {
  Write-Host "DRYRUN: InstallRoot=$InstallRoot ExportRoot=$ExportRoot Organizations=$($Organizations -join ',')"
  foreach ($j in $jobs) { Write-Host "DRYRUN: publish $($j.Worker) -> registriraj $($j.TaskName) vsakih $($j.Minutes) min$(if ($j.Saop) { ' (PIM_SAOP_MODE=Live)' })" }
  return
}
if (-not $IsWindows) { throw 'Scheduled Tasks so na voljo samo v Windows.' }

New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null

# En publish na worker (ne na nalogo) - SaopStockWorker in KatalogWorker se uporabita dvakrat, ni
# smisla ju zgraditi dvakrat.
$publishedWorkers = @{}
foreach ($workerName in ($jobs.Worker | Select-Object -Unique)) {
  $target = Join-Path $InstallRoot $workerName
  if ($PSCmdlet.ShouldProcess($target, "Publish $workerName")) {
    dotnet publish (Join-Path $repoRoot "workers/$workerName/$workerName.csproj") -c Release -r win-x64 --self-contained true -o $target
    if ($LASTEXITCODE -ne 0) { throw "Publish $workerName ni uspel." }
  }
  $publishedWorkers[$workerName] = Join-Path $target "$workerName.exe"
}

foreach ($j in $jobs) {
  $exe = $publishedWorkers[$j.Worker]
  $vbsPath = Join-Path $scriptsDir "$($j.TaskName).vbs"
  $batPath = Join-Path $scriptsDir "$($j.TaskName).bat"

  $lines = @('@echo off')
  if ($j.Saop) { $lines += 'set PIM_SAOP_MODE=Live' }
  if ($j.PerOrg) {
    # Magento izvoz nima notranje zanke po podjetjih (drugace kot SAOP workerja) - vsak zagon
    # naloge poklice exe enkrat na podjetje, vsako v svojo mapo pod ExportRoot.
    foreach ($org in $Organizations) {
      $orgDir = Join-Path $ExportRoot $org
      $lines += "`"$exe`" $($j.Args) --organization-id $org --output-dir `"$orgDir`""
    }
  } else {
    $lines += "`"$exe`" $($j.Args)"
  }
  Set-Content -Path $batPath -Value $lines -Encoding ASCII

  # Skrita VBScript ovojnica: 0 = brez okna, True = pocakaj da bat konca, preden Task Scheduler
  # oznaci nalogo kot zakljuceno (drugace bi se lahko dva zagona prekrivala). Zgrajeno z
  # zdruzevanjem enojno-narekovanih delov, da se izognemo gnezdenim escape zaporedjem.
  $vbsRunLine = 'objShell.Run "cmd /c ""' + $batPath + '""", 0, True'
  Set-Content -Path $vbsPath -Value @(
    'Set objShell = CreateObject("WScript.Shell")'
    $vbsRunLine
  ) -Encoding ASCII

  if ($PSCmdlet.ShouldProcess($j.TaskName, 'Registriraj Scheduled Task')) {
    Unregister-ScheduledTask -TaskName $j.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "//B `"$vbsPath`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
      -RepetitionInterval (New-TimeSpan -Minutes $j.Minutes) -RepetitionDuration (New-TimeSpan -Days 3650)
    Register-ScheduledTask -TaskName $j.TaskName -Action $action -Trigger $trigger -Force | Out-Null
    Write-Host "Registrirano: $($j.TaskName) vsakih $($j.Minutes) min -> $vbsPath"
  }
}

Write-Host ''
Write-Host 'Opomba: naloge tecejo pod "Run only when user is logged on" (privzeto, brez posebnega'
Write-Host 'racuna) - ce strezniku ne bo nihce prijavljen, se ne bodo sprozile. Za "Run whether'
Write-Host 'user is logged on or not" spremeni Principal na tej napravi rocno kot administrator'
Write-Host '(Set-ScheduledTask -Principal (New-ScheduledTaskPrincipal -UserId TA-RACUN -LogonType S4U)),'
Write-Host 'kar ne rabi gesla in ostane brez CMD okna.'
Write-Host ''
Write-Host 'Preveri: pipeline SAOP_PRODUCTS, SAOP_STOCK, SAOP_DELIVERY, MAGENTO_PRODUCTS in'
Write-Host 'MAGENTO_STOCK_PRICES morajo imeti omogoceno vrstico v ops.ScheduleProfile (migracije) in'
Write-Host "appsettings.Local.json mora obstajati v korenu resitve ($repoRoot) s pravo povezavo in"
Write-Host 'SAOP poverilnicami - kopiraj rocno, ni v Gitu.'
Write-Host 'Po prvi namestitvi enkrat rocno pozeni PIM-SaopKatalogPoln (Start-ScheduledTask), da se polja'
Write-Host 'z novejsimi preslikavami (npr. VatRateId) napolnijo takoj in ne sele cez teden.'
