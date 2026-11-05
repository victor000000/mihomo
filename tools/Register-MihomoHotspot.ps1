# Run elevated as the Windows user who signs in. WinRT requires an interactive session.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18'){throw 'Run as the interactive Windows user, not SYSTEM'}
$action=New-ScheduledTaskAction -Execute "$env:WINDIR\System32\conhost.exe" `
 -Argument "--headless `"$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$root\tools\Start-MihomoHotspot.ps1`"" -WorkingDirectory $root
$trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
$trigger.Delay='PT30S'
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
 -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
 -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$settings.Hidden=$true
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName MihomoHotspot -Action $action -Trigger $trigger -Settings $settings `
 -Principal $principal -Description 'Ensure Windows hotspot and ICS after logon; diagnostics in state/hotspot.log' -Force | Out-Null
Start-ScheduledTask MihomoHotspot
