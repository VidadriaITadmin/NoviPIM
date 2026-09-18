<#
.SYNOPSIS
  Nastavi mapo, kamor PIM.B2bWorker pise katalog.csv in stranke.csv (in magento-stock-prices.csv).

.DESCRIPTION
  Ena sprememba namesto urejanja vec datotek. Worker (PIM.B2bWorker) pot prebere ob vsakem
  zagonu iz registra ops.SystemPath (kljuc EXPORT_ROOT, migracija 173) - ista nastavitev, ki jo
  lahko urejas tudi na strani /sistem/mape v intranetu. Ta skripta samo klice ops.SetSystemPath,
  ki ga klice tudi tista stran; razlika je, da ta ne preveri, ali je mapa dosegljiva in pisljiva
  (to naredi worker sam ob naslednjem zagonu - ce pot ne obstaja ali vanjo ni mogoce pisati, ta
  zagon pade in to je vidno v /sistem/postopki).

  Ni potreben restart nicesar: Katalog-cikel.ps1 (vsako uro) in Nocno-vse.ps1 (vsako noc) zazenejo
  PIM.B2bWorker kot svez proces vsakic znova, zato nova pot velja od naslednjega zagona naprej.

  Vrstni red, ki ga worker uposteva (PIM.B2bWorker\Program.cs): rocni --output-dir > okoljska
  spremenljivka PIM_EXPORT_ROOT > ta register > vgrajeni privzetek (izvoz\magento\<podjetje> pod
  korenom repozitorija).

.PARAMETER Pot
  Absolutna pot na strezniku, kamor naj gresta katalog.csv in stranke.csv, npr.
  C:\inetpub\wwwroot\PIM_exports_csv ali \\streznik\delitev\izvoz.

.PARAMETER OrganizationId
  Ce podano, velja nastavitev samo za to podjetje. Privzeto NULL - velja za vsa (danes v
  katalog.csv/stranke.csv pise samo podjetje 2, glej Katalog-cikel.ps1 -PodjetjeKataloga).

.PARAMETER KorenRepozitorija
  Koren repozitorija, od koder skripta prebere appsettings.Local.json, ce PIM_CONNECTION_STRING
  ni nastavljena. Privzeto se izpelje iz mesta te skripte.

.EXAMPLE
  .\Nastavi-izvozno-pot.ps1 -Pot 'C:\inetpub\wwwroot\PIM_exports_csv'

.EXAMPLE
  # Samo za podjetje 2, ce bi kdaj rabili razlicno pot po podjetjih:
  .\Nastavi-izvozno-pot.ps1 -Pot 'D:\Izvozi\IQLighting' -OrganizationId 2
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Pot,
  [int]$OrganizationId,
  [string]$KorenRepozitorija = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($KorenRepozitorija)) {
  $KorenRepozitorija = Split-Path -Parent $PSScriptRoot
}

. (Join-Path $PSScriptRoot 'Sql.ps1')

if (-not [System.IO.Path]::IsPathRooted($Pot)) {
  throw "Pot mora biti absolutna (npr. C:\inetpub\wwwroot\PIM_exports_csv ali \\streznik\delitev\izvoz), dobil: $Pot"
}

$povezava = PimPovezava $KorenRepozitorija

$varnaPot = $Pot.Replace("'", "''")
$orgSql = if ($PSBoundParameters.ContainsKey('OrganizationId')) { $OrganizationId } else { 'NULL' }
$uporabnik = "$($env:USERDOMAIN)\$($env:USERNAME) (Nastavi-izvozno-pot.ps1)".Replace("'", "''")

Write-Host "Pisem v bazo (streznik/baza glej spodaj) ..." -ForegroundColor Cyan
Write-Host (PimUkaz $povezava "SELECT StreznikBaze = @@SERVERNAME, Baza = DB_NAME();")

$nastavi = PimUkaz $povezava "EXEC ops.SetSystemPath @PathKey = N'EXPORT_ROOT', @Location = N'$varnaPot', @UpdatedBy = N'$uporabnik', @OrganizationId = $orgSql;"
if ($nastavi) { Write-Host $nastavi }

$preveri = PimUkaz $povezava "EXEC ops.ResolveSystemPath @PathKey = N'EXPORT_ROOT', @OrganizationId = $orgSql;"
Write-Host "EXPORT_ROOT zdaj: " -NoNewline -ForegroundColor Green
Write-Host $preveri
