[CmdletBinding(SupportsShouldProcess=$true)]
# Uporaba: -WhatIf; workerji uporabljajo skupni PIM.Operations wrapper.
param(
  [Parameter(Mandatory=$true)][string]$InstallRoot,
  [Parameter(Mandatory=$true)][string]$ServiceAccount,
  [switch]$DryRun
)
$ErrorActionPreference='Stop'
$workers=@('PIM.Watchdog','PIM.AlertDispatcher')
if ($ServiceAccount -eq 'LocalSystem') { throw 'LocalSystem ni dovoljen; uporabi namenski najmanj privilegiran račun.' }
foreach($worker in $workers){
  $target=Join-Path $InstallRoot $worker
  if($DryRun){Write-Host "DRYRUN: publish $worker v $target; dodeli ReadAndExecute računu $ServiceAccount; New-Service";continue}
  if(-not $IsWindows){throw 'Namestitev storitev je dovoljena samo v Windows.'}
  if($PSCmdlet.ShouldProcess($target,"Namesti worker $worker")){
    dotnet publish (Join-Path (Split-Path $PSScriptRoot -Parent) "workers/$worker/$worker.csproj") -c Release -r win-x64 --self-contained true -o $target
    if($LASTEXITCODE -ne 0){throw "Publish $worker ni uspel."}
    & icacls $target /inheritance:r /grant:r "${ServiceAccount}:(OI)(CI)RX" | Out-Null
    if(-not(Get-Service $worker -ErrorAction SilentlyContinue)){New-Service -Name $worker -BinaryPathName (Join-Path $target "$worker.exe") -Credential (Get-Credential $ServiceAccount) -StartupType Automatic}
  }
}
