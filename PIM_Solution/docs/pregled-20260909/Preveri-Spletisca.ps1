<#
.SYNOPSIS
  Dokaz D2 iz docs/PREGLED_SISTEMA_IN_UX_2026-09-08.md po uporabnikovi odlocitvi 2026-09-08:
  kam gre izdelek, povedo potrditvena polja po spletiscu in ne Product.WebPublish iz SAOP.

.DESCRIPTION
  Dva dela:
    1. Nad tekoco aplikacijo — kartica izdelka ima razdelek Spletisca; bralna vloga ga vidi z
       onemogocenimi polji, vloga s pravico pisanja pa z omogocenimi.
    2. Nad razvojno bazo — krog pim.SaveProductWebShops -> val.RunValidation: ko je izdelku
       oznaka odvzeta, njegove spletne napake ugasnejo; ko je vrnjena, se spet odprejo.
       Skript si zapomni zacetno stanje izdelka in ga na koncu vrne.

  Zacasni racun ustvari in pobrise sam. Poslovnih podatkov ne pusti spremenjenih.
#>
param([string]$Base = 'http://127.0.0.1:5091')
$ErrorActionPreference = 'Stop'

$solution = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$repo = Split-Path $solution -Parent
$settings = Get-Content (Join-Path $repo 'appsettings.Local.json') -Raw | ConvertFrom-Json
$builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder $settings.ConnectionStrings.Pim
$server = ($builder.DataSource -split '\\')[0]
if ($builder.InitialCatalog -ne 'PIM' -or $server -notin @('.', 'localhost', '127.0.0.1', $env:COMPUTERNAME)) {
  throw 'Dovoljena je samo lokalna razvojna baza PIM.'
}
$connection = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
$connection.Open()

$userName = 'qa_shop_' + [Guid]::NewGuid().ToString('N')
$password = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
$userId = $null
$script:failures = 0

function Sql([string]$sql, [hashtable]$parameters = @{}) {
  $cmd = $connection.CreateCommand()
  $cmd.CommandText = $sql
  $cmd.CommandTimeout = 300
  [void]$cmd.Parameters.AddWithValue('@UserName', $userName)
  [void]$cmd.Parameters.AddWithValue('@Id', $(if ($null -eq $userId) { [DBNull]::Value } else { $userId }))
  foreach ($key in $parameters.Keys) { [void]$cmd.Parameters.AddWithValue($key, $parameters[$key]) }
  try { return $cmd.ExecuteScalar() } finally { $cmd.Dispose() }
}

function Check([string]$name, [bool]$ok, [string]$detail) {
  if ($ok) { Write-Output ("  OK    {0} - {1}" -f $name, $detail) }
  else { $script:failures++; Write-Output ("  PADLO {0} - {1}" -f $name, $detail) }
}

function NewSession { New-Object Microsoft.PowerShell.Commands.WebRequestSession }

# Samo razdelek Spletisca kartice; kartica ima potrditvena polja tudi drugod.
function Section([string]$html) {
  $start = $html.IndexOf('id="panel-spletisca"')
  if ($start -lt 0) { return '' }
  $end = $html.IndexOf('id="panel-saop-endpoint"', $start)
  if ($end -lt 0) { $end = $html.Length }
  return $html.Substring($start, $end - $start)
}

function Web($session, [string]$path, [string]$method = 'GET', $body = $null) {
  try {
    $response = Invoke-WebRequest -Uri "$Base/$path" -Method $method -Body $body -WebSession $session -UseBasicParsing -TimeoutSec 180
    return [pscustomobject]@{ Status = [int]$response.StatusCode; Path = $response.BaseResponse.ResponseUri.AbsolutePath; Content = [string]$response.Content }
  } catch {
    $failed = $_.Exception.Response
    if ($null -eq $failed) { throw }
    $reader = New-Object IO.StreamReader $failed.GetResponseStream()
    $content = $reader.ReadToEnd(); $reader.Dispose()
    return [pscustomobject]@{ Status = [int]$failed.StatusCode; Path = $failed.ResponseUri.AbsolutePath; Content = $content }
  }
}

function Login($session, [string]$user, [string]$pass) {
  $login = Web $session 'prijava'
  $token = [regex]::Match($login.Content, 'name="__RequestVerificationToken"[^>]*value="([^"]+)"').Groups[1].Value
  if (-not $token) { throw 'Antiforgery zetona ni bilo mogoce prebrati.' }
  return Web $session 'auth/prijava' 'POST' @{ uporabniskoIme = $user; geslo = $pass; __RequestVerificationToken = $token }
}

$productId = $null
$originalFlag = $null
try {
  $salt = New-Object byte[] 16
  $random = [Security.Cryptography.RandomNumberGenerator]::Create(); $random.GetBytes($salt); $random.Dispose()
  $derive = [Security.Cryptography.Rfc2898DeriveBytes]::new($password, $salt, 210000, [Security.Cryptography.HashAlgorithmName]::SHA256)
  $hash = 'v1.210000.' + [Convert]::ToBase64String($salt) + '.' + [Convert]::ToBase64String($derive.GetBytes(32))
  $derive.Dispose()
  $create = $connection.CreateCommand()
  $create.CommandText = 'sec.CreateLocalUser'
  $create.CommandType = [Data.CommandType]::StoredProcedure
  [void]$create.Parameters.AddWithValue('@UserName', $userName)
  [void]$create.Parameters.AddWithValue('@DisplayName', 'QA dokaz spletisc')
  [void]$create.Parameters.AddWithValue('@PasswordHash', $hash)
  [void]$create.Parameters.AddWithValue('@RoleCode', 'VIEWER')
  $userId = $create.ExecuteScalar()
  $create.Dispose()

  # Izdelek, ki je danes oznacen za spletisce in ima odprte spletne napake.
  $productId = Sql "
    SELECT TOP (1) i.ProductId
    FROM val.ProductIssue i
    JOIN val.ValidationProfile vp ON vp.ValidationProfileId = i.ValidationProfileId
    JOIN pim.ProductWebShop s ON s.ProductId = i.ProductId AND s.IsPublished = 1
    WHERE i.IsActive = 1 AND vp.Scope = N'WEB' AND s.WebShopCode = vp.CategoryTreeCode
    ORDER BY i.ProductId;"
  if ($null -eq $productId) { throw 'Za dokaz je potreben izdelek z oznako spletisca in odprto spletno napako.' }

  Write-Output '=== Kartica: bralna vloga ==='
  $viewer = NewSession
  $null = Login $viewer $userName $password
  $card = Web $viewer "izdelki/$productId"
  Check 'razdelek Spletisca je viden' ($card.Content -match 'panel-spletisca') ('HTTP ' + $card.Status)
  # Steti je treba samo polja v razdelku Spletisca; kartica ima potrditvena polja tudi drugod.
  # Prav tako se besedila s sumniki ne da zanesljivo primerjati - PowerShell 5.1 odgovor
  # dekodira po glavi odgovora in slovenske crke razbije - zato so vzorci brez sumnikov.
  $viewerSection = Section $card.Content
  $disabled = ([regex]::Matches($viewerSection, '<input type="checkbox"[^>]*disabled')).Count
  $enabled  = ([regex]::Matches($viewerSection, '<input type="checkbox"(?![^>]*disabled)')).Count
  Check 'potrditvena polja so za VIEWER onemogocena' ($disabled -gt 0 -and $enabled -eq 0) ("onemogocenih: $disabled, omogocenih: $enabled")
  Check 'VIEWER dobi pojasnilo namesto gumba' ($viewerSection -match 'Spremembo splet') 'besedilo o vlogah'

  Write-Output '=== Kartica: vloga s pravico pisanja ==='
  $null = Sql "INSERT sec.LocalUserRole(LocalUserId,RoleId) SELECT @Id,RoleId FROM sec.Role WHERE RoleCode=N'CATALOG_EDITOR' AND EXISTS(SELECT 1 FROM sec.LocalUser WHERE LocalUserId=@Id AND UserName=@UserName); SELECT 1;"
  $editor = NewSession
  $null = Login $editor $userName $password
  $editorSection = Section (Web $editor "izdelki/$productId").Content
  $editorEnabled = ([regex]::Matches($editorSection, '<input type="checkbox"(?![^>]*disabled)')).Count
  $editorDisabled = ([regex]::Matches($editorSection, '<input type="checkbox"[^>]*disabled')).Count
  Check 'potrditvena polja so za CATALOG_EDITOR omogocena' ($editorEnabled -gt 0 -and $editorDisabled -eq 0) ("omogocenih: $editorEnabled, onemogocenih: $editorDisabled")
  Check 'gumb Shrani spletisca je viden' ($editorSection -match 'Shrani splet') 'gumb'

  Write-Output '=== Baza: oznaka doloca obseg spletne validacije ==='
  $shopCode = Sql "SELECT TOP (1) s.WebShopCode FROM pim.ProductWebShop s WHERE s.ProductId=@Product AND s.IsPublished=1 ORDER BY s.WebShopCode;" @{ '@Product' = $productId }
  $organizationId = Sql "SELECT OrganizationId FROM canon.Product WHERE ProductId=@Product;" @{ '@Product' = $productId }
  $originalFlag = 1
  $before = Sql "SELECT COUNT(*) FROM val.ProductIssue i JOIN val.ValidationProfile vp ON vp.ValidationProfileId=i.ValidationProfileId WHERE i.ProductId=@Product AND i.IsActive=1 AND vp.Scope=N'WEB';" @{ '@Product' = $productId }

  $null = Sql "EXEC pim.SaveProductWebShops @OrganizationId=@Org, @ProductId=@Product, @ChangesJson=@Json, @Actor=@UserName, @Note=N'QA dokaz spletisc';" `
    @{ '@Org' = $organizationId; '@Product' = $productId; '@Json' = ('[{"webShopCode":"' + $shopCode + '","isPublished":"0"}]') }
  $afterOff = Sql "SELECT COUNT(*) FROM val.ProductIssue i JOIN val.ValidationProfile vp ON vp.ValidationProfileId=i.ValidationProfileId WHERE i.ProductId=@Product AND i.IsActive=1 AND vp.Scope=N'WEB';" @{ '@Product' = $productId }
  Check 'brez oznake spletne napake ugasnejo' ($before -gt 0 -and $afterOff -eq 0) ("pred: $before, po odvzemu: $afterOff")

  $history = Sql "SELECT COUNT(*) FROM pim.ProductFieldHistory WHERE ProductId=@Product AND FieldKey=CONCAT(N'ProductWebShop.', @Shop);" @{ '@Product' = $productId; '@Shop' = $shopCode }
  Check 'sprememba pusti sled v zgodovini' ($history -ge 1) ("vrstic zgodovine: $history")

  $null = Sql "EXEC pim.SaveProductWebShops @OrganizationId=@Org, @ProductId=@Product, @ChangesJson=@Json, @Actor=@UserName, @Note=N'QA dokaz spletisc - vrnitev';" `
    @{ '@Org' = $organizationId; '@Product' = $productId; '@Json' = ('[{"webShopCode":"' + $shopCode + '","isPublished":"1"}]') }
  $afterOn = Sql "SELECT COUNT(*) FROM val.ProductIssue i JOIN val.ValidationProfile vp ON vp.ValidationProfileId=i.ValidationProfileId WHERE i.ProductId=@Product AND i.IsActive=1 AND vp.Scope=N'WEB';" @{ '@Product' = $productId }
  Check 'z vrnjeno oznako se spletne napake spet odprejo' ($afterOn -gt 0) ("po vrnitvi: $afterOn")

  $restored = Sql "SELECT CAST(IsPublished AS int) FROM pim.ProductWebShop WHERE ProductId=@Product AND WebShopCode=@Shop;" @{ '@Product' = $productId; '@Shop' = $shopCode }
  Check 'zacetno stanje izdelka je vrnjeno' ($restored -eq 1) ("IsPublished: $restored")

} finally {
  if ($null -ne $userId) {
    $remaining = Sql "DELETE sec.LocalUserRole WHERE LocalUserId=@Id AND EXISTS(SELECT 1 FROM sec.LocalUser WHERE LocalUserId=@Id AND UserName=@UserName); DELETE sec.LocalUser WHERE LocalUserId=@Id AND UserName=@UserName; SELECT COUNT(*) FROM sec.LocalUser WHERE LocalUserId=@Id;"
    Write-Output ('QA_ACCOUNT_CLEANUP_COMPLETE ostanek=' + $remaining)
  }
  $connection.Close()
}

Write-Output ''
if ($script:failures -eq 0) { Write-Output 'REZULTAT: VSE OK'; exit 0 }
Write-Output ('REZULTAT: PADLIH PREVERB ' + $script:failures)
exit 1
