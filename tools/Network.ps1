[CmdletBinding()]
param([ValidateSet('Start','Status','Repair','Stop','AutostartOn','AutostartOff')][string]$Action='Status',[switch]$DryRun)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$isAdmin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $DryRun -and $Action -in @('Repair','AutostartOn','AutostartOff') -and -not $isAdmin){
 $p=Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Action $Action"
 $null=$p.Handle;$p.WaitForExit();exit $p.ExitCode
}
New-Item "$root\state" -ItemType Directory -Force|Out-Null
Start-Transcript "$root\state\network-$Action.log" -Append|Out-Null
try{
 if($DryRun){
  if($Action -eq 'Repair'){& "$root\repair-network.ps1" -DryRun}else{Write-Output "Would run $Action; no changes made"}
  return
 }
 switch($Action){
  Start { & "$PSScriptRoot\Start-MihomoNetwork.ps1" }
  Status { & "$PSScriptRoot\Get-MihomoStatus.ps1" }
  Repair { & "$root\repair-network.ps1" }
  AutostartOn { & "$PSScriptRoot\Register-MihomoStartup.ps1" }
  AutostartOff { & "$PSScriptRoot\Disable-MihomoAutostart.ps1" }
  Stop {
   $processes=Get-CimInstance Win32_Process
   $supervisors=$processes|Where-Object {$_.Name -in @('pwsh.exe','powershell.exe') -and $_.CommandLine -like "*-File*${root}\runtime\mihomo-supervisor.ps1*"}
   foreach($p in $supervisors){Stop-Process -Id $p.ProcessId -ErrorAction Stop}
   foreach($p in ($processes|Where-Object ExecutablePath -eq "$root\runtime\mihomo.exe")){Stop-Process -Id $p.ProcessId -ErrorAction Stop}
   & "$PSScriptRoot\Set-MihomoSystemProxy.ps1" -Disable
   Write-Output 'Stopped this project proxy and disabled the user system proxy. Hotspot and native networking retained.'
  }
 }
}finally{Stop-Transcript|Out-Null}
