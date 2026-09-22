<#
.SYNOPSIS
  Registrira nacrtovano nalogo "PIM nadzor avtomatike": zunanji nadzor utripa gostitelja avtomatike.

.DESCRIPTION
  Notranji watchdog lahko nadzira posamezne posle, ne more pa zanesljivo nadzirati samega sebe:
  ce se gostitelj (PIM.AutomationHost, migracija 237) ustavi, se ustavi tudi nadzor in nihce ne
  poslje alarma. Zato ta naloga vsakih 5 minut v svojem procesu pozene

    PIM.AutomationHost.exe --preveri

  ki prebere najem v ops.SchedulerLease; ce gostitelj molci vec kot 10 minut (ali najema ni ali ga
  drzi intranet), odpre alarm AutomationHostDown, ga uvrsti v vrsto in pozene razposiljalca alarmov
  (PIM.AlertDispatcher), da e-posta odide tudi takrat, ko gostitelj lezi. Izhod 0 = utripa, 1 = molci.

  To je edina smiselna uporaba zunanje Windows naloge; poslovnih ciklov ne poganja vec (stare naloge
  odstrani scripts\Namesti-opravila.ps1 -Odstrani). Registracija je sistemska nastavitev in jo pozene
  clovek. Samo ASCII v tej datoteki (PowerShell 5.1 bere datoteko brez BOM kot ANSI).

.PARAMETER Program
  Pot do PIM.AutomationHost.exe. Privzeto <koren>\Workerji\PIM.AutomationHost\PIM.AutomationHost.exe
  (objava intraneta v eno mapo), sicer razvojni izpis PIM_Solution\workers\PIM.AutomationHost\bin\Release\net10.0.

.PARAMETER RacunStoritve
  Streznik: naloga tece pod tem racunom (LogonType Password, geslo se vprasa); brez tega pod trenutnim
  racunom (razvojni racunalnik, Interactive).

.PARAMETER Odstrani
  Nalogo odstrani.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\Namesti-nadzor-avtomatike.ps1
  powershell -ExecutionPolicy Bypass -File scripts\Namesti-nadzor-avtomatike.ps1 -Program C:\inetpub\wwwroot\PIM\Workerji\PIM.AutomationHost\PIM.AutomationHost.exe -RacunStoritve 'DOMENA\pim-avtomatika'
  powershell -ExecutionPolicy Bypass -File scripts\Namesti-nadzor-avtomatike.ps1 -Odstrani
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$Program = '',
  [string]$RacunStoritve = '',
  [int]$MinuteRazmika = 5,
  [switch]$Odstrani
)

$ErrorActionPreference = 'Stop'
$ime = 'PIM nadzor avtomatike'
$mestoSkripte = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$koren = Split-Path -Parent $mestoSkripte

if ($Odstrani) {
  if (Get-ScheduledTask -TaskName $ime -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $ime -Confirm:$false
    Write-Output "Odstranjena: $ime"
  }
  else { Write-Output "Ni bilo: $ime" }
  return
}

if ([string]::IsNullOrWhiteSpace($Program)) {
  $kandidati = @(
    (Join-Path $koren 'Workerji\PIM.AutomationHost\PIM.AutomationHost.exe'),
    (Join-Path $koren 'PIM_Solution\workers\PIM.AutomationHost\bin\Release\net10.0\PIM.AutomationHost.exe'),
    (Join-Path $koren 'PIM_Solution\workers\PIM.AutomationHost\bin\Debug\net10.0\PIM.AutomationHost.exe')
  )
  $Program = $kandidati | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $Program) { throw "PIM.AutomationHost.exe ni najden; objavi intranet (Workerji\) ali zgradi workers\PIM.AutomationHost, ali podaj -Program." }
}
if (-not (Test-Path $Program)) { throw "Program ne obstaja: $Program" }

# Brez konzolnega okna ob vsakem zagonu na razvojnem racunalniku: isti tihi zaganjalnik kot pri
# starih nalogah (Tiho.vbs pozene program s skritim oknom in vrne njegovo izhodno kodo).
$tiho = Join-Path $mestoSkripte 'Tiho.vbs'
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
if ((Test-Path $tiho) -and (Test-Path $wscript) -and [string]::IsNullOrWhiteSpace($RacunStoritve)) {
  $akcija = New-ScheduledTaskAction -Execute $wscript -Argument ('//B //Nologo "{0}" "{1}" --preveri' -f $tiho, $Program) -WorkingDirectory (Split-Path $Program -Parent)
}
else {
  $akcija = New-ScheduledTaskAction -Execute $Program -Argument '--preveri' -WorkingDirectory (Split-Path $Program -Parent)
}

$prozilec = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $MinuteRazmika)
$nastavitve = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
  -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries

if ($PSCmdlet.ShouldProcess($ime, 'Registriraj nacrtovano nalogo')) {
  if ([string]::IsNullOrWhiteSpace($RacunStoritve)) {
    Register-ScheduledTask -TaskName $ime -Action $akcija -Trigger $prozilec -Settings $nastavitve `
      -User ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -RunLevel Limited -Force | Out-Null
  }
  else {
    $principal = New-ScheduledTaskPrincipal -UserId $RacunStoritve -LogonType Password -RunLevel Limited
    Register-ScheduledTask -TaskName $ime -Action $akcija -Trigger $prozilec -Settings $nastavitve -Principal $principal `
      -Password (Read-Host 'Geslo racuna' -AsSecureString) -Force | Out-Null
  }
  Write-Output "Registrirana: $ime (vsakih $MinuteRazmika min)"
  Write-Output "   $Program --preveri"
}

Write-Output ''
Write-Output 'Preveri z:  Get-ScheduledTask -TaskName "PIM nadzor avtomatike" | Get-ScheduledTaskInfo'
Write-Output 'Rocno:      PIM.AutomationHost.exe --preveri   (izhod 0 = gostitelj utripa, 1 = molci, 2 = baza ni dosegljiva)'
