param([string]$OutputDirectory = $PSScriptRoot, [switch]$Focused)
$ErrorActionPreference = 'Stop'
$base = 'http://127.0.0.1:5199'
$solution = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$repo = Split-Path $solution -Parent
$settings = Get-Content (Join-Path $repo 'appsettings.Local.json') -Raw | ConvertFrom-Json
$builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder $settings.ConnectionStrings.Pim
$server = ($builder.DataSource -split '\\')[0]
if ($builder.InitialCatalog -ne 'PIM' -or $server -notin @('.', 'localhost', '127.0.0.1', $env:COMPUTERNAME)) { throw 'Only local development PIM is allowed.' }
$connection = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
$connection.Open()
$userName = 'qa_review_' + [Guid]::NewGuid().ToString('N')
$password = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
$userId = $null
$chrome = $null
$script:socket = $null
$script:messageId = 0
$results = New-Object System.Collections.Generic.List[object]

function SqlScalar([string]$sql) {
  $cmd = $connection.CreateCommand()
  $cmd.CommandText = $sql
  $cmd.CommandTimeout = 60
  [void]$cmd.Parameters.AddWithValue('@UserName', $userName)
  [void]$cmd.Parameters.AddWithValue('@Id', $(if ($null -eq $userId) { [DBNull]::Value } else { $userId }))
  try { return $cmd.ExecuteScalar() } finally { $cmd.Dispose() }
}

function Cdp([string]$method, $parameters = @{}) {
  $script:messageId++
  $id = $script:messageId
  $payload = @{id=$id;method=$method;params=$parameters} | ConvertTo-Json -Depth 25 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
  $cancel = New-Object Threading.CancellationTokenSource
  $cancel.CancelAfter(60000)
  try {
    $script:socket.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, $cancel.Token).GetAwaiter().GetResult()
    while ($true) {
      $memory = New-Object IO.MemoryStream
      try {
        do {
          $buffer = New-Object byte[] 65536
          $received = $script:socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), $cancel.Token).GetAwaiter().GetResult()
          if ($received.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw 'Browser closed the connection.' }
          $memory.Write($buffer,0,$received.Count)
        } while (-not $received.EndOfMessage)
        $message = [Text.Encoding]::UTF8.GetString($memory.ToArray()) | ConvertFrom-Json
        if ($message.id -eq $id) {
          if ($message.error) { throw ($message.error | ConvertTo-Json -Compress) }
          return $message.result
        }
      } finally { $memory.Dispose() }
    }
  } finally { $cancel.Dispose() }
}

function Evaluate([string]$expression) {
  $response = Cdp 'Runtime.evaluate' @{expression=$expression;returnByValue=$true;awaitPromise=$true}
  if ($response.exceptionDetails) { throw 'Browser evaluation failed.' }
  return $response.result.value
}

function Login {
  $script:webSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
  $login = Invoke-WebRequest -Uri "$base/prijava" -WebSession $script:webSession -UseBasicParsing -TimeoutSec 90
  $token = [regex]::Match($login.Content, 'name="__RequestVerificationToken"[^>]*value="([^"]+)"').Groups[1].Value
  if (-not $token) { throw 'Login antiforgery token not found.' }
  $response = Invoke-WebRequest -Uri "$base/auth/prijava" -Method Post -Body @{uporabniskoIme=$userName;geslo=$password;__RequestVerificationToken=$token} -WebSession $script:webSession -UseBasicParsing -TimeoutSec 120
  if ($response.BaseResponse.ResponseUri.AbsolutePath -like '*prijava*') { throw 'Test login failed.' }
  $cookies = @($script:webSession.Cookies.GetCookies([Uri]$base) | ForEach-Object { @{name=$_.Name;value=$_.Value;url=$base;httpOnly=$_.HttpOnly} })
  $null = Cdp 'Network.clearBrowserCookies'
  $null = Cdp 'Network.setCookies' @{cookies=$cookies}
}

function Inspect([string]$path, [string]$name, [bool]$capture=$false, [int]$width=1440) {
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $null = Cdp 'Emulation.setDeviceMetricsOverride' @{width=$width;height=1000;deviceScaleFactor=1;mobile=$false}
  $null = Cdp 'Page.navigate' @{url="$base/$path"}
  $ready = $false
  for ($attempt=0;$attempt -lt 100;$attempt++) {
    Start-Sleep -Milliseconds 300
    try {
      $state = Evaluate "({ready:document.readyState, path:location.pathname, loading:[...document.querySelectorAll('.loading-state')].some(x=>x.getClientRects().length>0)})"
      $expectedPath = '/' + ($path -split '\?')[0]
      if ($state.ready -eq 'complete' -and -not $state.loading -and $state.path -eq $expectedPath) { $ready=$true;break }
    } catch { }
  }
  Start-Sleep -Milliseconds 700
  $summary = Evaluate "JSON.stringify({title:document.title,path:location.pathname,heading:document.querySelector('h1')?.innerText,viewport:innerWidth,bodyWidth:document.documentElement.scrollWidth,rows:document.querySelectorAll('tbody tr').length,editableVisible:[...document.querySelectorAll('input:not([type=hidden]):not([type=checkbox]),textarea,select')].filter(x=>x.getClientRects().length>0&&!x.disabled&&!x.readOnly).length,errors:[...document.querySelectorAll('.error-state,.error-message,.login-alert')].filter(x=>x.getClientRects().length>0).map(x=>x.innerText.slice(0,220)),logoutVisible:[...document.querySelectorAll('.logout-button')].some(x=>x.getClientRects().length>0)})"
  $result = $summary | ConvertFrom-Json
  $clock.Stop()
  $entry = [pscustomobject]@{Name=$name;Path=$path;Loaded=$ready;Ms=$clock.ElapsedMilliseconds;Summary=$result}
  $results.Add($entry)
  Write-Output ($entry | ConvertTo-Json -Depth 8 -Compress)
  if ($capture) {
    $screen = Cdp 'Page.captureScreenshot' @{format='png';captureBeyondViewport=$false}
    [IO.File]::WriteAllBytes((Join-Path $OutputDirectory ($name+'.png')), [Convert]::FromBase64String($screen.data))
  }
}

try {
  $salt = New-Object byte[] 16
  $random = [Security.Cryptography.RandomNumberGenerator]::Create()
  $random.GetBytes($salt)
  $random.Dispose()
  $derive = [Security.Cryptography.Rfc2898DeriveBytes]::new($password,$salt,210000,[Security.Cryptography.HashAlgorithmName]::SHA256)
  $hash = 'v1.210000.' + [Convert]::ToBase64String($salt) + '.' + [Convert]::ToBase64String($derive.GetBytes(32))
  $derive.Dispose()
  $create = $connection.CreateCommand()
  $create.CommandText = 'sec.CreateLocalUser'
  $create.CommandType = [Data.CommandType]::StoredProcedure
  [void]$create.Parameters.AddWithValue('@UserName',$userName)
  [void]$create.Parameters.AddWithValue('@DisplayName','QA pregled aplikacije')
  [void]$create.Parameters.AddWithValue('@PasswordHash',$hash)
  [void]$create.Parameters.AddWithValue('@RoleCode','VIEWER')
  $userId = $create.ExecuteScalar()
  $create.Dispose()
  $product = SqlScalar 'SELECT TOP (1) ProductId FROM canon.Product WHERE OrganizationId=2 AND WebPublish=1 ORDER BY ProductId;'
  $profilePath = Join-Path $OutputDirectory ('browser-'+[Guid]::NewGuid().ToString('N'))
  $chromePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
  $chrome = Start-Process $chromePath -ArgumentList @('--headless=new','--incognito','--disable-gpu','--no-first-run','--no-default-browser-check','--remote-debugging-port=9223','--proxy-server=http://127.0.0.1:9','--proxy-bypass-list=127.0.0.1;localhost',('--user-data-dir="'+$profilePath+'"'),'about:blank') -PassThru
  for($attempt=0;$attempt -lt 30;$attempt++) {
    try { $tabs=Invoke-RestMethod 'http://127.0.0.1:9223/json/list' -TimeoutSec 2; if($tabs){break} } catch { Start-Sleep -Milliseconds 300 }
  }
  $tab = $tabs | Where-Object type -eq 'page' | Select-Object -First 1
  if (-not $tab.webSocketDebuggerUrl) { throw 'Browser debugging endpoint unavailable.' }
  $script:socket = New-Object Net.WebSockets.ClientWebSocket
  $script:socket.ConnectAsync([Uri]$tab.webSocketDebuggerUrl,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
  $null=Cdp 'Page.enable'
  $null=Cdp 'Network.enable'
  Login
  Inspect "izdelki/$product" 'viewer-product' $true
  $null = Evaluate "document.getElementById('tab-web')?.click();true"
  Start-Sleep -Seconds 1
  $viewer = Evaluate "JSON.stringify({webEditable:[...document.querySelectorAll('#panel-web input,#panel-web textarea,#panel-web select')].filter(x=>x.getClientRects().length>0&&!x.disabled&&!x.readOnly).length,saveButtonPresent:[...document.querySelectorAll('button')].some(x=>x.innerText.includes('Shrani spremembe'))})"
  Write-Output ('VIEWER_FORM '+$viewer)
  $screen = Cdp 'Page.captureScreenshot' @{format='png';captureBeyondViewport=$false}
  [IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'viewer-web-fields.png'),[Convert]::FromBase64String($screen.data))
  if ($Focused) {
    $null = SqlScalar 'UPDATE sec.LocalUser SET IsEnabled=0 WHERE LocalUserId=@Id AND UserName=@UserName; SELECT 1;'
    $stillSignedIn = Invoke-WebRequest -Uri "$base/izdelki" -WebSession $script:webSession -UseBasicParsing -TimeoutSec 120
    Write-Output ('DISABLED_ACCOUNT_COOKIE ' + (@{Status=[int]$stillSignedIn.StatusCode;Path=$stillSignedIn.BaseResponse.ResponseUri.AbsolutePath} | ConvertTo-Json -Compress))
    $null = SqlScalar 'UPDATE sec.LocalUser SET IsEnabled=1 WHERE LocalUserId=@Id AND UserName=@UserName; SELECT 1;'
    Inspect 'preverbe' 'viewer-checks'
    Write-Output ('VIEWER_CHECK_ACTIONS ' + (Evaluate "JSON.stringify([...document.querySelectorAll('button')].filter(x=>x.getClientRects().length&&!x.disabled).map(x=>x.innerText).filter(x=>/potrd|resolv|ack/i.test(x)).slice(0,5))"))
  }
  $null = SqlScalar "INSERT sec.LocalUserRole(LocalUserId,RoleId) SELECT @Id,RoleId FROM sec.Role WHERE RoleCode=N'ADMIN' AND EXISTS(SELECT 1 FROM sec.LocalUser WHERE LocalUserId=@Id AND UserName=@UserName); SELECT 1;"
  Login
  $pages=@(
    @('nadzorna-plosca','dashboard'),@('izdelki','products'),@("izdelki/$product",'product'),
    @('zajem','ingest'),@('zajem/teki','ingest-runs'),@('zajem/tezave','ingest-issues'),@('zajem/cakalna-vrsta','ingest-queue'),@('zajem/neujemanja','unmapped'),@('zajem/atributi','source-attributes'),
    @('kakovost','quality'),@('kakovost/napake','validation-errors'),@('kakovost/prevodi','translations'),@('kakovost/kategorije','category-mapping'),@('karantena','quarantine'),
    @('mediji','media'),@('cene','prices'),@('zaloge','stock'),@('preverbe','checks'),@('cene/tisk','price-sheet'),
    @('nastavitve','catalog-settings'),@('nastavitve/kategorije','categories'),@('nastavitve/nabori-atributov','attribute-sets'),@('nastavitve/atributi','attributes'),@('nastavitve/kanali','channels'),@('nastavitve/jeziki','languages'),@('nastavitve/skladisca','warehouses'),@('nastavitve/povezave-izdelkov','product-links'),
    @('pravila','rules'),@('pravila/validacija','validation-rules'),@('pravila/slovar','dictionary'),@('pravila/preslikave','field-mappings'),@('pravila/nazivi','title-rules'),
    @('saop','saop'),@('saop/artikli','saop-items'),@('saop/zgodovina','saop-history'),@('saop/odkloni','saop-drifts'),@('saop/polja','saop-fields'),@('outbound','outbound'),@('izvozi/mnozicno','bulk-outbound'),@('izvozi/obvestila','outbound-events'),
    @('splet','web'),@('splet/izvoz','web-build'),@('izvozi/profili/1','export-profile'),@('izdelki/uvoz','product-import'),@('izdelki/kategorije','product-categories'),
    @('sistem','system'),@('sistem/integracije','integrations'),@('sistem/urniki','schedules'),@('sistem/napake','system-errors'),@('sistem/vloge','roles'),@('sistem/zmogljivost','performance'),@('sistem/izvozi','export-runs'),@('sistem/samotest','selftest')
  )
  $captures=@('dashboard','products','product','ingest','quality','validation-errors','media','prices','stock','categories','attribute-sets','attributes','title-rules','saop-items','web','system','product-import')
  if ($Focused) {
    $pages=@(@('saop/zgodovina','saop-history-plain'),@('saop/zgodovina?stanje=PendingApproval','saop-history-filtered'),@('nastavitve/atributi/GARANCIJA','attribute-detail'),@('zajem/viri/BT_XML','source-detail'))
    $captures=@('attribute-detail','source-detail')
  }
  foreach($page in $pages) { Inspect $page[0] $page[1] ($captures -contains $page[1]) }
  Inspect 'izdelki' 'products-800' $true 800
  try {
    Write-Output ('MOBILE_SEARCH_LAYOUT '+(Evaluate "JSON.stringify({fieldHeight:document.querySelector('.search-field')?.getBoundingClientRect().height,fieldFlex:document.querySelector('.search-field')?getComputedStyle(document.querySelector('.search-field')).flex:null,toolbarDirection:document.querySelector('.toolbar-row')?getComputedStyle(document.querySelector('.toolbar-row')).flexDirection:null,logoutVisible:[...document.querySelectorAll('.logout-button')].some(x=>x.getClientRects().length>0)})"))
  } catch { Write-Output 'MOBILE_SEARCH_LAYOUT unavailable' }
  $resultName = if ($Focused) { 'ui-focused-results.json' } else { 'ui-results.json' }
  $results | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutputDirectory $resultName) -Encoding utf8
} finally {
  if ($script:socket -and $script:socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
    try { $null=Cdp 'Network.clearBrowserCookies' } catch { }
    $script:socket.Dispose()
  }
  if ($chrome -and -not $chrome.HasExited) { Stop-Process -Id $chrome.Id -ErrorAction SilentlyContinue }
  if ($null -ne $userId) {
    $null=SqlScalar "DELETE ops.AlertSeen WHERE UserKey=@UserName; DELETE sec.LocalUserRole WHERE LocalUserId=@Id AND EXISTS(SELECT 1 FROM sec.LocalUser WHERE LocalUserId=@Id AND UserName=@UserName); DELETE sec.LocalUser WHERE LocalUserId=@Id AND UserName=@UserName; SELECT COUNT(*) FROM sec.LocalUser WHERE LocalUserId=@Id AND UserName=@UserName;"
    Write-Output 'QA_ACCOUNT_CLEANUP_COMPLETE'
  }
  $connection.Close()
}
