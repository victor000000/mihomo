# Read-only status for the gateway design; no legacy launch or config regeneration.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$snapshot=Join-Path $root 'state\gateway-status.json'
& "$PSScriptRoot\Write-MihomoBootSnapshot.ps1" -OutputPath $snapshot
$data=Get-Content $snapshot -Raw -Encoding UTF8 | ConvertFrom-Json
Import-Module "$root\src\NetStack\Architecture.psm1" -Force
Write-Output "Ordinary transport: $(Get-OrdinaryTransport $root); Mihomo only"
foreach($p in $data.ProxySelection){
 if($p.Error){Write-Output "Proxy API: $($p.Error)"}else{Write-Output "$($p.Group): $($p.Selected)"}
}
$managedNames=@(Get-Content "$root\config\mihomo-adapters.json" -Raw | ConvertFrom-Json | ForEach-Object {$_.name})
foreach($nic in $data.Adapters | Where-Object Name -in $managedNames){
 Write-Output "$($nic.Name): $($nic.Status)"
}
Write-Output "Detailed snapshot: $snapshot"
Write-Output 'Listeners and selected routes do not prove end-to-end connectivity; use Test-NetworkHealth.ps1 for live probes.'
