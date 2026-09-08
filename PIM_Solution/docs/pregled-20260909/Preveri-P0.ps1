<#
.SYNOPSIS
  Dokaz P0 popravkov iz docs/PREGLED_SISTEMA_IN_UX_2026-09-08.md (ugotovitve A1-A5).

.DESCRIPTION
  Preverja tekoco aplikacijo, ne kode. Ustvari si zacasen lokalen racun z vlogo VIEWER, se
  prijavi in preveri:

    A1  kartica izdelka bralni vlogi ne ponudi obrazca in gumba "Shrani spremembe"
    A2  /saop/zgodovina brez poizvedbenega parametra vrne 200, ne 500
    A3  onemogocen racun z istim piskotkom ne pride vec do /izdelki
    A3  enajsta neuspela prijava vrne HTTP 429
    A5  zaprta stran vodi na /brez-dostopa in ne na prijavni obrazec

  Racun in njegove vrstice na koncu pobrise sam (AGENTS.md 4.1). Ne spreminja poslovnih
  podatkov in ne klice nicesar zunanjega. Pisana je za Windows PowerShell 5.1, tako kot
  docs/pregled-20260908/Inspect-Ui.ps1.

.PARAMETER Base
  Naslov tekoce aplikacije; privzeto http://127.0.0.1:5199.
#>
param([string]$Base = 'http://127.0.0.1:5199')
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
$userName = 'qa_p0_' + [Guid]::NewGuid().ToString('N')
$password = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
$userId = $null
$script:failures = 0

function Sql([string]$sql) {
  $cmd = $connection.CreateCommand()
  $cmd.CommandText = $sql
  $cmd.CommandTimeout = 60
  [void]$cmd.Parameters.AddWithValue('@UserName', $userName)
  [void]$cmd.Parameters.AddWithValue('@Id', $(if ($null -eq $userId) { [DBNull]::Value } else { $userId }))
  try { return $cmd.ExecuteScalar() } finally { $cmd.Dispose() }
}

function Check([string]$name, [bool]$ok, [string]$detail) {
  if ($ok) { Write-Output ("  OK    {0} - {1}" -f $name, $detail) }
  else { $script:failures++; Write-Output ("  PADLO {0} - {1}" -f $name, $detail) }
}

function NewSession { New-Object Microsoft.PowerShell.Commands.WebRequestSession }

# Windows PowerShell 5.1 ob 4xx/5xx vrze izjemo; odgovor je treba prebrati iz nje, sicer se
# 429 in 500 sploh ne dasta izmeriti.
function Web($session, [string]$path, [string]$method = 'GET', $body = $null) {
  try {
    $response = Invoke-WebRequest -Uri "$Base/$path" -Method $method -Body $body -WebSession $session `
      -UseBasicParsing -TimeoutSec 120
    return [pscustomobject]@{
      Status  = [int]$response.StatusCode
      Path    = $response.BaseResponse.ResponseUri.AbsolutePath
      Content = [string]$response.Content
    }
  } catch {
    $failed = $_.Exception.Response
    if ($null -eq $failed) { throw }
    $stream = $failed.GetResponseStream()
    $reader = New-Object IO.StreamReader $stream
    $content = $reader.ReadToEnd()
    $reader.Dispose()
    return [pscustomobject]@{
      Status  = [int]$failed.StatusCode
      Path    = $failed.ResponseUri.AbsolutePath
      Content = $content
    }
  }
}

function Login($session, [string]$user, [string]$pass) {
  $login = Web $session 'prijava'
  $token = [regex]::Match($login.Content, 'name="__RequestVerificationToken"[^>]*value="([^"]+)"').Groups[1].Value
  if (-not $token) { throw 'Antiforgery zetona ni bilo mogoce prebrati.' }
  return Web $session 'auth/prijava' 'POST' @{ uporabniskoIme = $user; geslo = $pass; __RequestVerificationToken = $token }
}

try {
  $salt = New-Object byte[] 16
  $random = [Security.Cryptography.RandomNumberGenerator]::Create()
  $random.GetBytes($salt)
  $random.Dispose()
  $derive = [Security.Cryptography.Rfc2898DeriveBytes]::new($password, $salt, 210000, [Security.Cryptography.HashAlgorithmName]::SHA256)
  $hash = 'v1.210000.' + [Convert]::ToBase64String($salt) + '.' + [Convert]::ToBase64String($derive.GetBytes(32))
  $derive.Dispose()

  $create = $connection.CreateCommand()
  $create.CommandText = 'sec.CreateLocalUser'
  $create.CommandType = [Data.CommandType]::StoredProcedure
  [void]$create.Parameters.AddWithValue('@UserName', $userName)
  [void]$create.Parameters.AddWithValue('@DisplayName', 'QA dokaz P0')
  [void]$create.Parameters.AddWithValue('@PasswordHash', $hash)
  [void]$create.Parameters.AddWithValue('@RoleCode', 'VIEWER')
  $userId = $create.ExecuteScalar()
  $create.Dispose()

  $product = Sql 'SELECT TOP (1) ProductId FROM canon.Product ORDER BY ProductId;'

  Write-Output '=== Bralna vloga VIEWER ==='
  $viewer = NewSession
  $signIn = Login $viewer $userName $password
  Check 'prijava VIEWER' ($signIn.Path -notlike '*prijava*') ('pot po prijavi: ' + $signIn.Path)

  # A1 - kartica izdelka
  $card = Web $viewer "izdelki/$product"
  Check 'A1 kartica brez gumba Shrani spremembe' (-not ($card.Content -match 'Shrani spremembe')) ('HTTP ' + $card.Status)
  Check 'A1 kartica pove, da je samo za branje' ($card.Content -match 'Samo za branje') 'znacka Samo za branje'
  $editable = ([regex]::Matches($card.Content, '<input[^>]*class="field-input"')).Count `
            + ([regex]::Matches($card.Content, '<textarea[^>]*class="field-input"')).Count `
            + ([regex]::Matches($card.Content, '<select[^>]*class="field-input"')).Count
  Check 'A1 kartica nima urejivih polj kanala' ($editable -eq 0) ("urejivih polj: $editable (pregled 2026-09-08: 14)")

  # A5 - zaprta stran
  $denied = Web $viewer 'saop'
  Check 'A5 zaprta stran vodi na /brez-dostopa' ($denied.Path -like '*brez-dostopa*') ('pot: ' + $denied.Path)
  Check 'A5 stran brez dostopa pove vlogo' ($denied.Content -match 'Tvoje vloge') 'besedilo Tvoje vloge'

  # A3 - onemogocen racun
  $null = Sql 'UPDATE sec.LocalUser SET IsEnabled=0 WHERE LocalUserId=@Id AND UserName=@UserName; SELECT 1;'
  $afterDisable = Web $viewer 'izdelki'
  Check 'A3 onemogocen racun ne pride do /izdelki' ($afterDisable.Path -like '*prijava*') `
    ('pot: ' + $afterDisable.Path + ', HTTP ' + $afterDisable.Status)
  $null = Sql 'UPDATE sec.LocalUser SET IsEnabled=1 WHERE LocalUserId=@Id AND UserName=@UserName; SELECT 1;'

  Write-Output '=== Vloga ADMIN ==='
  $null = Sql "INSERT sec.LocalUserRole(LocalUserId,RoleId) SELECT @Id,RoleId FROM sec.Role WHERE RoleCode=N'ADMIN' AND EXISTS(SELECT 1 FROM sec.LocalUser WHERE LocalUserId=@Id AND UserName=@UserName); SELECT 1;"
  $admin = NewSession
  $null = Login $admin $userName $password

  # A1 - protidokaz: vloga s pravico pisanja mora obrazec se vedno dobiti
  $adminCard = Web $admin "izdelki/$product"
  Check 'A1 protidokaz: ADMIN ima gumb Shrani spremembe' ($adminCard.Content -match 'Shrani spremembe') ('HTTP ' + $adminCard.Status)
  $adminEditable = ([regex]::Matches($adminCard.Content, '<input[^>]*class="field-input"')).Count `
                 + ([regex]::Matches($adminCard.Content, '<textarea[^>]*class="field-input"')).Count `
                 + ([regex]::Matches($adminCard.Content, '<select[^>]*class="field-input"')).Count
  Check 'A1 protidokaz: ADMIN ima urejiva polja' ($adminEditable -gt 0) ("urejivih polj: $adminEditable")

  # A2 - zgodovina SAOP
  $history = Web $admin 'saop/zgodovina'
  Check 'A2 /saop/zgodovina brez parametra' ($history.Status -eq 200 -and $history.Content -match 'Zgodovina zapisov v SAOP') ('HTTP ' + $history.Status)
  $filtered = Web $admin 'saop/zgodovina?stanje=PendingApproval'
  Check 'A2 /saop/zgodovina s parametrom' ($filtered.Status -eq 200) ('HTTP ' + $filtered.Status)

  Write-Output '=== Omejitev prijave ==='
  $codes = @()
  for ($attempt = 1; $attempt -le 11; $attempt++) {
    $session = NewSession
    $response = Login $session $userName 'napacno-geslo-za-preizkus'
    $codes += $response.Status
  }
  Check 'A3 enajsti neuspeli poskus vrne 429' ($codes[10] -eq 429) ('kode poskusov 1-11: ' + ($codes -join ', '))

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
