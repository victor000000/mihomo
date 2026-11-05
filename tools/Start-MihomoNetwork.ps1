# Explicit manual startup; retain the validated running configuration.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module "$root\src\NetStack\Architecture.psm1" -Force
if((Get-NetworkArchitecture $root) -ne 'mihomo'){throw 'Mihomo mode required'}
& "$PSScriptRoot\Mihomo-Startup.ps1"
Start-ScheduledTask -TaskName MihomoHotspot -ErrorAction Stop
$ready=$false
foreach($attempt in 1..30){
 try{Invoke-RestMethod 'http://127.0.0.1:9097/version' -TimeoutSec 2 | Out-Null;$ready=$true;break}catch{Start-Sleep -Seconds 2}
}
& "$PSScriptRoot\Get-MihomoStatus.ps1"
if(-not $ready){throw 'Proxy API not ready; inspect Mihomo startup logs'}

& "$PSScriptRoot\Set-MihomoSystemProxy.ps1"
& "$PSScriptRoot\Start-AdaptiveDispatch.ps1"
