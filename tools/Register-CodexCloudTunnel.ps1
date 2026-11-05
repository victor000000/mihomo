# Run elevated as the interactive user. Keep the cloud-only tunnel across logons.
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$dir=Join-Path $root 'state\codex-cloud-tunnel'
New-Item -ItemType Directory $dir -Force|Out-Null
$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18'){throw 'Register as the interactive user'}
$name='MihomoCodexCloudTunnel'
$existing=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
if($existing){Export-ScheduledTask -TaskName $name|Set-Content "$dir\previous-task.xml";Stop-ScheduledTask -TaskName $name}
$action=New-ScheduledTaskAction -Execute "$env:WINDIR\System32\conhost.exe" -Argument "--headless `"$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$root\tools\Watch-CodexCloudTunnel.ps1`"" -WorkingDirectory $root
$trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
$trigger.Delay='PT45S'
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$settings.Hidden=$true
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Route only the Codex cloud backend IPs through the local Mihomo Codex egress; refresh DNS host routes' -Force|Out-Null
Start-ScheduledTask -TaskName $name
'Registered and started MihomoCodexCloudTunnel'
