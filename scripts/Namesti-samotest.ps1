<#
.SYNOPSIS
  Registrira nacrtovano nalogo Windows, ki vsako noc pozene scripts\Nocni-samotest.ps1.

.DESCRIPTION
  To skripto pozene CLOVEK, ne agent. Nacrtovana opravila so po AGENTS.md #4.7 sistemska
  nastavitev in so na zaprtem seznamu stvari, ki jih agent ne sme spreminjati sam. Skripta je
  tu zato, da je ukaz zapisan in ponovljiv.

  Pozeni v PowerShellu:

      powershell -ExecutionPolicy Bypass -File scripts\Namesti-samotest.ps1

  Kaj naredi: ustvari (ali posodobi) nalogo "PIM samotest", ki ob dogovorjeni uri pozene
  Nocni-samotest.ps1. Rezultat gre v bazo; skrbnik ga vidi na /sistem in /sistem/samotest.

  Zakaj ob 04:30 in ne ob 02:30: nocno opravilo (Namesti-nocno-opravilo.ps1) se zacne ob 02:30
  in sme teci do osem ur. Samotest, ki bi tekel med njim, bi meril sistem sredi dela — polovico
  uvozenega kataloga in izvoz, ki se ni koncan. Ob 04:30 je nocni tok obicajno ze mimo, hkrati
  pa je se dovolj casa, da clovek zjutraj vidi izid.

.PARAMETER Ura
  Ura zagona v obliki HH:mm. Privzeto 04:30.

.PARAMETER ImeNaloge
  Ime naloge v razporejevalniku.

.PARAMETER Odstrani
  Namesto registracije nalogo odstrani.
#>
[CmdletBinding()]
param(
  [ValidatePattern('^\d{2}:\d{2}$')] [string]$Ura = '04:30',
  [string]$ImeNaloge = 'PIM samotest',
  [switch]$Odstrani
)

$ErrorActionPreference = 'Stop'

$mestoSkripte = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$koren = Split-Path -Parent $mestoSkripte
$samotest = Join-Path $mestoSkripte 'Nocni-samotest.ps1'
if (-not (Test-Path $samotest)) { throw "Ni najdena skripta $samotest." }

if ($Odstrani) {
  if (Get-ScheduledTask -TaskName $ImeNaloge -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $ImeNaloge -Confirm:$false
    Write-Output "Naloga '$ImeNaloge' je odstranjena."
  }
  else { Write-Output "Naloge '$ImeNaloge' ni bilo." }
  return
}

. (Join-Path $mestoSkripte 'Izvajalec.ps1')

# Naloga tece prek Tiho.vbs, da konzolnega okna ni niti za trenutek — isto kot pri drugih
# nalogah; zakaj tako, je do konca zapisano v Tiho.vbs.
$ukaz = TihiUkaz -Skripta $samotest -MapaSkript $mestoSkripte -Argumenti @(
  '-KorenRepozitorija', "`"$koren`""
)

$akcija   = New-ScheduledTaskAction -Execute $ukaz.Program -Argument $ukaz.Argumenti -WorkingDirectory $koren
$prozilec = New-ScheduledTaskTrigger -Daily -At $Ura

# Samotest, ki traja dlje od pol ure, je sam po sebi napaka; meja ga ustavi, ops.BeginSelfTest
# pa naslednjo noc tak zagon oznaci kot Abandoned in to je vidno na nadzorni plosci.
$nastavitve = New-ScheduledTaskSettingsSet `
  -StartWhenAvailable `
  -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
  -DontStopIfGoingOnBatteries `
  -AllowStartIfOnBatteries

# DOMENA\uporabnik: samo $env:USERNAME domenski racunalnik zavrne (glej Namesti-opravila.ps1).
Register-ScheduledTask -TaskName $ImeNaloge -Action $akcija -Trigger $prozilec `
  -Settings $nastavitve -User ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
  -RunLevel Limited -Force | Out-Null

Write-Output "Naloga '$ImeNaloge' je registrirana; zagon vsak dan ob $Ura."
Write-Output "Ukaz: $($ukaz.Program) $($ukaz.Argumenti)"
Write-Output 'Preveri z: Get-ScheduledTask -TaskName "PIM samotest" | Get-ScheduledTaskInfo'
Write-Output 'Izid vidis na /sistem in /sistem/samotest.'
