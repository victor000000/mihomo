# Disable future starts only. Do not stop the proxy, hotspot or current sessions.
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$backup=Join-Path $root ('state\startup-gateway\disabled-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory $backup -Force | Out-Null
foreach($name in 'MihomoHotspot','MihomoAdapterRecovery','MihomoCodexCloudTunnel'){
 $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
 if($task){
  Export-ScheduledTask -TaskName $name | Set-Content "$backup\$name.xml" -Encoding Unicode
  $task | Disable-ScheduledTask | Out-Null
 }
}
$startup=[Environment]::GetFolderPath('Startup')
foreach($name in 'Mihomo-Startup.vbs','Mihomo-PacServer.vbs'){
 $path=Join-Path $startup $name
 if(Test-Path $path){Move-Item -LiteralPath $path -Destination $backup}
}
Write-Output "Mihomo autostart disabled; running network retained. Backup: $backup"
