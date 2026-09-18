<#
.SYNOPSIS
  Registrira nacrtovani opravili PIM: nocni tok in petminutni zalogovni cikel.

.DESCRIPTION
  Nacrtovana opravila so po AGENTS.md #4.7 sistemska nastavitev. Ta skripta obstaja zato, da je
  ukaz zapisan, ponovljiv in odstranljiv - ne zato, da bi jo pognal kdorkoli.

  OD 2026-09-17 TE NALOGE NISO VEC POTREBNE: cikle poganja razporejevalnik v samem intranetu
  (migracija 221, stran /sistem/workerji, docs/WORKERS.md "Razporejevalnik v aplikaciji") - pod
  IIS, v Visual Studiu ali z dotnet run. Skripte ciklov se same umaknejo, kadar intranet drzi najem
  (Sql.ps1, -Vseeno za rocni zagon). Naloge odstrani z -Odstrani; registriraj jih samo, kadar intranet
  ne tece nikjer in cikle hoces poganjati z racunalnika brez njega.

  Registrira stiri naloge pod tvojim racunom:

    PIM nocni tok   vsak dan ob $Ura   cel tok: katalog, XML, zaloga, validacija, izvoz
    PIM zaloga      vsakih 5 minut     SAOP, Nowodvorski FTP, Braytron XML, promote, cena+zaloga
    PIM katalog     vsako uro          promote + poln izvoz (katalog.csv/stranke.csv)
    PIM nadzor      vsakih 5 minut     nadzornik zastalih obdelav in razposiljanje alarmov

  PIM katalog je locena od PIM zaloga zato, ker je poln izvoz (215 stolpcev) tezji od hitrega
  profila cena+zaloga (14 stolpcev) — uporabnik 2026-09-10 je hotel katalog na uro, ceno in
  zalogo pa pogosteje; ti dve nalogi to locita, ne da bi poln izvoz tekel vsakih 5 minut.

  Nadzor je edini del, ki pove, da se je nekaj ustavilo. Brez njega odpoved ostane tiha -
  izmerjeno 28. 8. 2026 je zaloga padla 18-krat zapored in tega ni izvedel nihce.

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

.PARAMETER MapaWorkerjev
  Strežnik brez izvorne kode: mapa objavljenih workerjev (<mapa>\<Worker>\<Worker>.exe, kot jo
  naredi PIM_Solution\deploy\Publish-Workers.ps1 oziroma Publish-All.ps1). Vsaka naloga jo dobi kot
  -MapaWorkerjev in skripte pozenejo .exe namesto dotnet run (glej Workerji.ps1). Privzeto
  <koren>\Workerji, ce obstaja — pri objavi v eno mapo torej ni treba podati nicesar. Koren je tu
  mapa nad scripts\ — v njej mora biti appsettings.Local.json ali appsettings.json s povezavo,
  PIM_Solution\ pa ni potrebna.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [ValidatePattern('^\d{2}:\d{2}$')] [string]$Ura = '02:30',
  [switch]$Odstrani,
  [switch]$BrezZaloge,
  [string]$MapaWorkerjev = ''
)

$ErrorActionPreference = 'Stop'

$mestoSkripte = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$koren = Split-Path -Parent $mestoSkripte
$nocno   = Join-Path $mestoSkripte 'Nocno-vse.ps1'
$cikel   = Join-Path $mestoSkripte 'Zaloga-cikel.ps1'
$katalog = Join-Path $mestoSkripte 'Katalog-cikel.ps1'
$nadzor  = Join-Path $mestoSkripte 'Nadzor.ps1'

# Objava v eno mapo (deploy\Publish-All.ps1): Workerji\ ob korenu velja brez -MapaWorkerjev. Podamo jo
# nalogam izrecno, da je v registrirani nalogi vidno, od kod tecejo.
if ([string]::IsNullOrWhiteSpace($MapaWorkerjev) -and (Test-Path (Join-Path $koren 'Workerji'))) {
  $MapaWorkerjev = Join-Path $koren 'Workerji'
}

# Stari imeni sta v seznamu zato, da jih -Odstrani pospravi tudi pri tistih, ki so ju ze imeli
# registrirani; nova namestitev ju ne ustvari vec.
$imena = @('PIM nocni tok', 'PIM zaloga', 'PIM katalog', 'PIM nadzor', 'PIM prevzem datotek', 'PIM zaloga iz datotek', 'PIM zaloga iz SAOP')

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

. (Join-Path $mestoSkripte 'Izvajalec.ps1')

foreach ($pot in @($nocno, $cikel, $katalog, $nadzor)) {
  if (-not (Test-Path $pot)) { throw "Ni najdena skripta $pot." }
}

function Registriraj([string]$ime, [string]$skripta, [string[]]$dodatni, $prozilec, [timespan]$meja) {
  # Ukaz zgradi Izvajalec.ps1: naloga ne pozene PowerShella naravnost, ampak prek Tiho.vbs,
  # da konzolnega okna ni niti za trenutek. Zakaj je tako, je zapisano v Tiho.vbs.
  $skupni = @('-KorenRepozitorija', "`"$koren`"")
  if (-not [string]::IsNullOrWhiteSpace($MapaWorkerjev)) { $skupni += @('-MapaWorkerjev', "`"$MapaWorkerjev`"") }
  $ukaz = TihiUkaz -Skripta $skripta -MapaSkript $mestoSkripte -Argumenti ($skupni + $dodatni)

  $akcija = New-ScheduledTaskAction -Execute $ukaz.Program -Argument $ukaz.Argumenti -WorkingDirectory $koren

  # Meja izvajanja je na kratki povodec, ker MultipleInstances IgnoreNew nov zagon zavrne, dokler
  # prejsnji tece. Ena obticala instanca torej ustavi cel ritem, ne samo sebe: izmerjeno je
  # nadzor od 1. 9. 2026 20:31 visel 22 ur s 1,5 sekunde porabljenega procesorja in vsak
  # petminutni tik se je vrnil z 0x800710E0 (zavrnjeno, ker ze tece). Osem ur meje je bilo za
  # petminutni cikel nesmisel; ob meji Windows instanco konca in naslednji tik spet stece.
  $nastavitve = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit $meja `
    -DontStopIfGoingOnBatteries `
    -AllowStartIfOnBatteries

  # LogonType S4U (tece tudi brez prijavljenega uporabnika, brez shranjenega gesla) bi nalogo
  # prestavil v sejo 0, a ga Windows brez skrbniskih pravic zavrne z "Access is denied" -
  # zahteva pravico "Log on as a batch job". Zato ostane Interactive.
  #
  # -WindowStyle Hidden tega ni resil in ga tu ni vec: konzolo alocira Windows, preden jo
  # PowerShell utegne skriti, pri Store aliasu pa sploh. Okno odpravi Tiho.vbs (glej
  # Registriraj). Otroski procesi dotnet run podedujejo isto skrito konzolo in svojega okna
  # ne odprejo.
  if ($PSCmdlet.ShouldProcess($ime, 'Registriraj nacrtovano nalogo')) {
    # Polno ime (DOMENA\uporabnik): na domenskem racunalniku samo $env:USERNAME Register-ScheduledTask
    # zavrne z "The parameter is incorrect ... UserId" (izmerjeno 2026-09-14, AD\david).
    Register-ScheduledTask -TaskName $ime -Action $akcija -Trigger $prozilec `
      -Settings $nastavitve -User ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
      -RunLevel Limited -Force | Out-Null
    Write-Output "Registrirana: $ime"
    Write-Output "   $($ukaz.Program) $($ukaz.Argumenti)"
  }
}

# Ponavljajoc prozilec potrebuje zacetek v prihodnosti, sicer prvi zagon zamudi in naloga caka
# cel interval. Zamiki so razmaknjeni, da se trije cikli ne zaletijo v isti minuti.
function Ponavljajoc([int]$minute, [int]$zamikMinut) {
  New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($zamikMinut) `
    -RepetitionInterval (New-TimeSpan -Minutes $minute)
}

Registriraj 'PIM nocni tok' $nocno @('-DanPolnegaZajema', '1', '-HkratnihPodjetij', '4', '-ZalogaIzSaop') `
  (New-ScheduledTaskTrigger -Daily -At $Ura) (New-TimeSpan -Hours 8)

if (-not $BrezZaloge) {
  # Prejsnja delitev na tri naloge je odpadla; ce so se registrirane, jih pocistimo, sicer bi
  # tekle vzporedno z novo in podvajale klice na dobavitelja.
  foreach ($staro in @('PIM prevzem datotek', 'PIM zaloga iz datotek', 'PIM zaloga iz SAOP')) {
    if (Get-ScheduledTask -TaskName $staro -ErrorAction SilentlyContinue) {
      Unregister-ScheduledTask -TaskName $staro -Confirm:$false
      Write-Output "Odstranjena stara naloga: $staro"
    }
  }

  Registriraj 'PIM zaloga' $cikel @('-Kaj', 'Vse', '-PoUrniku') (Ponavljajoc 5 2) (New-TimeSpan -Minutes 30)

  # Vsako uro, locena od petminutne zaloge (glej opis Katalog-cikel.ps1: poln izvoz je tezji od
  # hitrega profila cena+zaloga in ne sodi v isti petminutni ritem).
  Registriraj 'PIM katalog' $katalog @() (Ponavljajoc 60 6) (New-TimeSpan -Minutes 45)

  # Nadzor je zamaknjen za dve minuti od zaloge: ce bi tekla hkrati, bi nadzornik lahko razglasil
  # za zastalo izvajanje, ki se je pravkar zacelo.
  Registriraj 'PIM nadzor' $nadzor @() (Ponavljajoc 5 4) (New-TimeSpan -Minutes 15)
}

Write-Output ''
Write-Output 'Preveri z:  Get-ScheduledTask -TaskName "PIM *" | Get-ScheduledTaskInfo'
Write-Output 'Odstrani z: powershell -ExecutionPolicy Bypass -File scripts\Namesti-opravila.ps1 -Odstrani'
Write-Output 'Dnevniki:   logs\ (nocni tok, zalogovni cikel in katalog cikel pisejo loceno)'
