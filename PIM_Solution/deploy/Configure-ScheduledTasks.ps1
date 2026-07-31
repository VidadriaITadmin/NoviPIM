[CmdletBinding(SupportsShouldProcess=$true)]
# Uporaba: -WhatIf ali -DryRun brez sprememb Scheduled Tasks.
param(
  [Parameter(Mandatory=$true)][string]$InstallRoot,
  [Parameter(Mandatory=$true)][string]$ServiceAccount,
  [int]$IntervalMinutes=5,
  [switch]$DryRun
)
$ErrorActionPreference='Stop'
if($ServiceAccount -eq 'SYSTEM' -or $ServiceAccount -eq 'LocalSystem'){throw 'Uporabi namenski najmanj privilegiran ServiceAccount.'}
$workers=@('PIM.Watchdog','PIM.AlertDispatcher')
foreach($worker in $workers){
  if($DryRun){Write-Host "DRYRUN: Register-ScheduledTask $worker vsakih $IntervalMinutes minut kot $ServiceAccount";continue}
  if(-not $IsWindows){throw 'Scheduled Tasks so na voljo samo v Windows.'}
  if($PSCmdlet.ShouldProcess($worker,'Registriraj Scheduled Task')){
    $action=New-ScheduledTaskAction -Execute (Join-Path $InstallRoot "$worker\$worker.exe")
    $trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
    $principal=New-ScheduledTaskPrincipal -UserId $ServiceAccount -LogonType Password -RunLevel Limited
    Register-ScheduledTask -TaskName "PIM-$worker" -Action $action -Trigger $trigger -Principal $principal -Password (Read-Host 'Geslo računa' -AsSecureString) -Force
  }
}
