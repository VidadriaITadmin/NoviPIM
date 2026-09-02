<#
.SYNOPSIS
  Registrira nacrtovano nalogo Windows, ki vsako noc pozene scripts\Nocno-vse.ps1.

.DESCRIPTION
  To skripto pozene CLOVEK, ne agent. Nacrtovana opravila so po AGENTS.md #4.7 sistemska
  nastavitev in so na zaprtem seznamu stvari, ki jih agent ne sme spreminjati sam. Skripta
  je tu zato, da je ukaz zapisan in ponovljiv, ne zato, da bi jo pognal kdorkoli.

  Pozeni v PowerShellu kot skrbnik:

      pwsh -File scripts\Namesti-nocno-opravilo.ps1

  Kaj naredi: ustvari (ali posodobi) nalogo "PIM nocno opravilo", ki ob dogovorjeni uri pozene
  Nocno-vse.ps1 pod tvojim racunom. Naloga tece tudi, ce racunalnik ob tisti uri ni bil prizgan
  (StartWhenAvailable), in se ne podvaja, ce prejsnja se tece (IgnoreNew).

  Zivi klic na SAOP za kolicine zaloge NI vklopljen. Ko se odlocis, da sme teci, dodaj
  -ZalogaIzSaop v $argumenti spodaj in nalogo registriraj znova.

.PARAMETER Ura
  Ura zagona v obliki HH:mm. Privzeto 02:30 — po polnoci, da poln zajem ne jemlje zmogljivosti
  ERP-ju podnevi, in dovolj zgodaj, da je izvoz gotov pred jutrom.

.PARAMETER ImeNaloge
  Ime naloge v razporejevalniku.

.PARAMETER Odstrani
  Namesto registracije nalogo odstrani.
#>
[CmdletBinding()]
param(
  [ValidatePattern('^\d{2}:\d{2}$')] [string]$Ura = '02:30',
  [string]$ImeNaloge = 'PIM nocno opravilo',
  [switch]$Odstrani
)

$ErrorActionPreference = 'Stop'

$mestoSkripte = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$koren = Split-Path -Parent $mestoSkripte
$nocno = Join-Path $mestoSkripte 'Nocno-vse.ps1'
if (-not (Test-Path $nocno)) { throw "Ni najdena skripta $nocno." }

if ($Odstrani) {
  if (Get-ScheduledTask -TaskName $ImeNaloge -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $ImeNaloge -Confirm:$false
    Write-Output "Naloga '$ImeNaloge' je odstranjena."
  }
  else { Write-Output "Naloge '$ImeNaloge' ni bilo." }
  return
}

. (Join-Path $mestoSkripte 'Izvajalec.ps1')

# Argumenti naloge. Tu je edino mesto, kjer se ritem in obseg nocnega opravila nastavita:
# kateri dan v mesecu je poln zajem, koliko podjetij hkrati in katera podjetja.
#
# Ukaz zgradi Izvajalec.ps1, isti kot pri Namesti-opravila.ps1: naloga tece prek Tiho.vbs, da
# konzolnega okna ni niti za trenutek. Ko je vsaka skripta gradila svoj ukaz, je popravek v eni
# pustil drugo po starem in okno se je vrnilo.
$ukaz = TihiUkaz -Skripta $nocno -MapaSkript $mestoSkripte -Argumenti @(
  '-KorenRepozitorija', "`"$koren`"",
  '-DanPolnegaZajema', '1',
  '-HkratnihPodjetij', '4'
)

$akcija   = New-ScheduledTaskAction -Execute $ukaz.Program -Argument $ukaz.Argumenti -WorkingDirectory $koren
$prozilec = New-ScheduledTaskTrigger -Daily -At $Ura
$nastavitve = New-ScheduledTaskSettingsSet `
  -StartWhenAvailable `
  -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Hours 8) `
  -DontStopIfGoingOnBatteries `
  -AllowStartIfOnBatteries

Register-ScheduledTask -TaskName $ImeNaloge -Action $akcija -Trigger $prozilec `
  -Settings $nastavitve -User $env:USERNAME -RunLevel Limited -Force | Out-Null

Write-Output "Naloga '$ImeNaloge' je registrirana; zagon vsak dan ob $Ura."
Write-Output "Ukaz: $($ukaz.Program) $($ukaz.Argumenti)"
Write-Output 'Preveri z: Get-ScheduledTask -TaskName "PIM nocno opravilo" | Get-ScheduledTaskInfo'
Write-Output 'Zivi klic na SAOP za zalogo ni vklopljen; za vklop dodaj -ZalogaIzSaop v $argumenti.'
