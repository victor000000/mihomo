$ErrorActionPreference='Stop'
& "$PSScriptRoot\Set-MihomoAutostart.ps1"
& "$PSScriptRoot\Register-MihomoAdapterRecovery.ps1"
& "$PSScriptRoot\Register-MihomoHotspot.ps1"
if(Test-Path "$PSScriptRoot\..\config\codex-cloud-tunnel.json"){
 $cloud=Get-Content "$PSScriptRoot\..\config\codex-cloud-tunnel.json" -Raw|ConvertFrom-Json
 if($cloud.enabled){& "$PSScriptRoot\Register-CodexCloudTunnel.ps1"}
}
Write-Output 'Mihomo, native adapter recovery, PAC and Windows hotspot startup registered.'
