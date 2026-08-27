<#
.SYNOPSIS
  Registrira nacrtovani opravili PIM: nocni tok in petminutni zalogovni cikel.

.DESCRIPTION
  Nacrtovana opravila so po AGENTS.md #4.7 sistemska nastavitev. Ta skripta obstaja zato, da je
  ukaz zapisan, ponovljiv in odstranljiv - ne zato, da bi jo pognal kdorkoli.

  Registrira dve nalogi pod tvojim racunom:

    PIM nocni tok   vsak dan ob $Ura   cel tok: katalog, XML, zaloga, validacija, izvoz
    PIM zaloga      vsakih 5 minut     SAOP, Nowodvorski FTP in Braytron XML

  Zaloga je ena sama naloga, ker se vsak vir v istem prehodu prevzame in prebere. Loceno
  opravilo za prevzem in loceno za branje je zalogo drzalo en cikel zadaj.

  Braytron dovoli en prenos na 180 minut; prevzemnik njegovo okno spostuje sam in vira vmes ne
  klice, zato petminutni ritem ne pomeni petminutnega prenasanja.

  Ritem je enak razporedu v ops.ScheduleProfile (migracija 112). Ce ga tu spremenis, spremeni
  tudi razpored v bazi - sicer worker zavrne zagon z napako 51100.

  Vsi zalogovni cikli klicejo ziv SAOP oziroma dobavitelja. Registracija te naloge JE privolitev
  v ponavljajoc se zunanji klic (AGENTS.md #4.5); brez nje nic od tega ne tece samo.

  Naloge se ne podvajajo (IgnoreNew) in nadoknadijo zamujen zagon (StartWhenAvailable), zato
  ugasnjen racunalnik ne pomeni izgubljenega cikla.

.PARAMETER Ura
  Ura nocnega toka v obliki HH:mm. Privzeto 02:30.

.PARAMETER Odstrani
  Namesto registracije vse stiri naloge odstrani.

.PARAMETER BrezZaloge
  Registriraj samo nocni tok, brez zalogovnega cikla.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [ValidatePattern('^\d{2}:\d{2}$')] [string]$Ura = '02:30',
  [switch]$Odstrani,
  [switch]$BrezZaloge
)

$ErrorActionPreference = 'Stop'

$mestoSkripte = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$koren = Split-Path -Parent $mestoSkripte
$nocno  = Join-Path $mestoSkripte 'Nocno-vse.ps1'
$cikel  = Join-Path $mestoSkripte 'Zaloga-cikel.ps1'

# Stari imeni sta v seznamu zato, da jih -Odstrani pospravi tudi pri tistih, ki so ju ze imeli
# registrirani; nova namestitev ju ne ustvari vec.
$imena = @('PIM nocni tok', 'PIM zaloga', 'PIM prevzem datotek', 'PIM zaloga iz datotek', 'PIM zaloga iz SAOP')

if ($Odstrani) {
  foreach ($ime in $imena) {
    if (Get-ScheduledTask -TaskName $ime -ErrorAction SilentlyContinue) {
      Unregister-ScheduledTask -TaskName $ime -Confirm:$false
      Write-Output "Odstranjena: $ime"
    }
    else { Write-Output "Ni bilo: $ime" }
  }
  return
}

foreach ($pot in @($nocno, $cikel)) {
  if (-not (Test-Path $pot)) { throw "Ni najdena skripta $pot." }
}

# Polna pot, ne samo ime. Razporejevalnik ne deduje nase poti PATH: prvi zagon je padel z
# 0x80070002 (datoteke ni mogoce najti), ceprav pwsh.exe v ukazni vrstici deluje.
$ukaz = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if (-not $ukaz) { $ukaz = Get-Command powershell.exe -ErrorAction Stop }
$izvajalec = $ukaz.Source
if (-not (Test-Path $izvajalec)) { throw "Izvajalca $izvajalec ni mogoce najti." }

function Registriraj([string]$ime, [string]$skripta, [string[]]$dodatni, $prozilec) {
  $argumenti = (@('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$skripta`"",
                  '-KorenRepozitorija', "`"$koren`"") + $dodatni) -join ' '

  $akcija = New-ScheduledTaskAction -Execute $izvajalec -Argument $argumenti -WorkingDirectory $koren
  $nastavitve = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 8) `
    -DontStopIfGoingOnBatteries `
    -AllowStartIfOnBatteries

  # LogonType S4U (tece tudi brez prijavljenega uporabnika, brez shranjenega gesla) bi okno
  # odpravil najciseje, a ga Windows brez skrbniskih pravic zavrne z "Access is denied" —
  # zahteva pravico "Log on as a batch job". Zato ostane Interactive, okno pa skrije
  # -WindowStyle Hidden v argumentih (glej Registriraj). Otroski procesi dotet run podedujejo
  # isto skrito konzolo in svojega okna ne odprejo.
  if ($PSCmdlet.ShouldProcess($ime, 'Registriraj nacrtovano nalogo')) {
    Register-ScheduledTask -TaskName $ime -Action $akcija -Trigger $prozilec `
      -Settings $nastavitve -User $env:USERNAME -RunLevel Limited -Force | Out-Null
    Write-Output "Registrirana: $ime"
    Write-Output "   $izvajalec $argumenti"
  }
}

# Ponavljajoc prozilec potrebuje zacetek v prihodnosti, sicer prvi zagon zamudi in naloga caka
# cel interval. Zamiki so razmaknjeni, da se trije cikli ne zaletijo v isti minuti.
function Ponavljajoc([int]$minute, [int]$zamikMinut) {
  New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($zamikMinut) `
    -RepetitionInterval (New-TimeSpan -Minutes $minute)
}

Registriraj 'PIM nocni tok' $nocno @('-DanPolnegaZajema', '1', '-HkratnihPodjetij', '4', '-ZalogaIzSaop') `
  (New-ScheduledTaskTrigger -Daily -At $Ura)

if (-not $BrezZaloge) {
  # Prejsnja delitev na tri naloge je odpadla; ce so se registrirane, jih pocistimo, sicer bi
  # tekle vzporedno z novo in podvajale klice na dobavitelja.
  foreach ($staro in @('PIM prevzem datotek', 'PIM zaloga iz datotek', 'PIM zaloga iz SAOP')) {
    if (Get-ScheduledTask -TaskName $staro -ErrorAction SilentlyContinue) {
      Unregister-ScheduledTask -TaskName $staro -Confirm:$false
      Write-Output "Odstranjena stara naloga: $staro"
    }
  }

  Registriraj 'PIM zaloga' $cikel @('-Kaj', 'Vse') (Ponavljajoc 5 2)
}

Write-Output ''
Write-Output 'Preveri z:  Get-ScheduledTask -TaskName "PIM *" | Get-ScheduledTaskInfo'
Write-Output 'Odstrani z: pwsh -File scripts\Namesti-opravila.ps1 -Odstrani'
Write-Output 'Dnevniki:   logs\ (nocni tok in zalogovni cikel pisata locena dnevnika)'
