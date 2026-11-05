# Run elevated; Task Scheduler starts native adapter recovery before user logon.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module "$root\src\NetStack\Architecture.psm1" -Force
if((Get-NetworkArchitecture -RepositoryRoot $root) -ne 'mihomo'){throw 'Gateway mode required'}
New-Item -ItemType Directory -Path "$root\state\adapter-recovery-registration" -Force | Out-Null
$name='MihomoAdapterRecovery'
$old=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
if($old){Export-ScheduledTask -TaskName $name | Set-Content "$root\state\adapter-recovery-registration\previous-task.xml"}
$action=New-ScheduledTaskAction -Execute "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$root\tools\Watch-MihomoAdapters.ps1`"" -WorkingDirectory $root
$trigger=New-ScheduledTaskTrigger -AtStartup
$trigger.Delay='PT15S'
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$settings.Hidden=$true
$principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Recover known USB adapter names and configured IP addresses after replug' -Force | Out-Null
Start-ScheduledTask $name
Get-ScheduledTask $name | Select-Object TaskName,@{N='Enabled';E={$_.Settings.Enabled}},@{N='User';E={$_.Principal.UserId}},@{N='Trigger';E={$_.Triggers[0].CimClass.CimClassName}} | ConvertTo-Json | Set-Content "$root\state\adapter-recovery-registration\registered.json"
