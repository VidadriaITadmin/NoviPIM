<#
.SYNOPSIS
  Skupni zagon workerja iz skript ciklov: objavljen .exe, kadar je, sicer dotnet run.

.DESCRIPTION
  Do 2026-09-16 je vsaka od stirih skript (Zaloga-cikel, Katalog-cikel, Nocno-vse, Nadzor) imela
  svojo kopijo PozeniWorker, ki je znala samo `dotnet run --project workers\<Ime> --no-build`. To
  na strezniku pade: intranet in workerji so tam objavljeni (dotnet publish), izvorne kode in
  PIM.sln ni. Zato tu ena funkcija za vse stiri:

    1. ce je $MapaWorkerjev nastavljena in obstaja <MapaWorkerjev>\<Ime>\<Ime>.exe, tece ta .exe
       (ista postavitev, kot jo naredi PIM_Solution\deploy\Configure-WorkerScheduledTasks.ps1 in jo
       bere intranet prek WorkerConsole:PublishedWorkersRoot);
    2. sicer kot doslej: dotnet run iz mape $resitev (PIM_Solution) — razvojni racunalnik.

  Ni namenjena zagonu; skripta jo vkljuci z zapisom:  . (Join-Path $PSScriptRoot 'Workerji.ps1')
  Od klicatelja pricakuje: $resitev (mapa PIM_Solution), $MapaWorkerjev (sme biti prazna) in
  funkcijo Zapisi (dnevnik).

  Objava v eno mapo (deploy\Publish-All.ps1): ob korenu (mapa nad PIM_Solution oziroma nad scripts\)
  je mapa Workerji\. Kadar -MapaWorkerjev ni podana, velja ona — zato Namesti-opravila.ps1 na
  strezniku ne rabi nobenega argumenta.
#>

if ([string]::IsNullOrWhiteSpace($MapaWorkerjev)) {
  $privzetaMapaWorkerjev = Join-Path (Split-Path -Parent $resitev) 'Workerji'
  if (Test-Path $privzetaMapaWorkerjev) { $MapaWorkerjev = $privzetaMapaWorkerjev }
}

function PozeniWorker([string]$projekt, [string[]]$argumenti = @()) {
  $ime = Split-Path -Leaf $projekt
  $exe = if ([string]::IsNullOrWhiteSpace($MapaWorkerjev)) { '' } else { Join-Path $MapaWorkerjev (Join-Path $ime "$ime.exe") }

  $prej = Get-Location
  try {
    # Pod 'Stop' bi prva vrstica na stderr postala terminirajoca napaka in korak bi padel brez tega,
    # kar je worker o napaki povedal. Merilo uspeha je izhodna koda, ne izpis na stderr.
    $prejsnjaObravnava = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      if ($exe -and (Test-Path $exe)) {
        # Delovna mapa ob .exe: worker tam najde svoj appsettings.Local.json (LocalSettings, vir 1).
        Set-Location (Split-Path -Parent $exe)
        & $exe @argumenti 2>&1 | ForEach-Object {
          if ($_ -is [System.Management.Automation.ErrorRecord]) { Zapisi "   STDERR: $($_.Exception.Message)" }
          else { Zapisi "   $_" }
        }
      }
      else {
        if (-not (Test-Path $resitev)) {
          $kje = if ($exe) { "ni $exe in " } else { '' }
          throw "worker ${ime}: ${kje}ni mape $resitev za dotnet run. Na strezniku podaj -MapaWorkerjev (ali PIM_PUBLISHED_WORKERS)."
        }
        Set-Location $resitev
        & dotnet run --project $projekt --no-build -- @argumenti 2>&1 | ForEach-Object {
          if ($_ -is [System.Management.Automation.ErrorRecord]) { Zapisi "   STDERR: $($_.Exception.Message)" }
          else { Zapisi "   $_" }
        }
      }
    }
    finally { $ErrorActionPreference = $prejsnjaObravnava }
    if ($LASTEXITCODE -ne 0) { throw "worker $ime je koncal z izhodno kodo $LASTEXITCODE" }
  }
  finally { Set-Location $prej }
}
