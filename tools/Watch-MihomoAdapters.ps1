# SYSTEM background reconciliation, with no console or global network resets.
[CmdletBinding()]param([switch]$Once)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module "$root\src\NetStack\RebootTrace.psm1" -Force
$trace=New-RebootTrace $root 'adapter-recovery'
Import-Module "$root\src\NetStack\Architecture.psm1" -Force
$dir=Join-Path $root 'state\adapter-recovery'
New-Item -ItemType Directory $dir -Force|Out-Null
$log=Join-Path $dir 'events.log'
$previous=''
$previousHealth=''
$lastHeartbeat=[datetime]::MinValue
$lastStallCheck=[datetime]::MinValue
Import-Module "$root\src\NetStack\AdapterRecoveryHealth.psm1" -Force
do {
 try {
  if((Get-NetworkArchitecture -RepositoryRoot $root) -ne 'mihomo'){break}
  if((Test-Path $log) -and (Get-Item $log).Length -gt 1048576){Move-Item $log "$log.previous" -Force}
  $report=(& "$PSScriptRoot\Repair-MihomoAdapters.ps1" -CheckOnly | Out-String).Trim()
  if($report -ne $previous){
   Write-RebootTrace $trace 'adapter-state-change' @{Before=$previous;After=$report}
   "$(Get-Date -Format o) $report"|Add-Content $log -Encoding UTF8
   if($previous){
    try{Start-ScheduledTask -TaskName MihomoHotspot -ErrorAction Stop;"$(Get-Date -Format o) Requested hotspot check after adapter change"|Add-Content $log -Encoding UTF8}
    catch{"$(Get-Date -Format o) Hotspot check deferred: $($_.Exception.Message)"|Add-Content $log -Encoding UTF8}
   }
   $previous=$report
  }
  $changes=(& "$PSScriptRoot\Repair-MihomoAdapters.ps1" | Where-Object {$_ -notlike '*absent or ambiguous*'} | Out-String).Trim()
  if($changes){Write-RebootTrace $trace 'repair-actions' @{Report=$changes};"$(Get-Date -Format o) $changes"|Add-Content $log -Encoding UTF8}
  if($changes -match '(?m)^ERROR ' -or $report -match '(?m)^ERROR '){throw 'Adapter repair failed; see events.log'}
  if(((Get-Date)-$lastHeartbeat).TotalSeconds -ge 60){Write-RebootTrace $trace 'heartbeat' @{Report=$report};$lastHeartbeat=Get-Date}
  $health=@()
  $healthError=$null
  try {
   $nodes=(Invoke-RestMethod 'http://127.0.0.1:9097/proxies' -TimeoutSec 3).proxies
   $sharing=New-Object -ComObject HNetCfg.HNetShare -ErrorAction Stop
   $sharedNames=@(foreach($connection in $sharing.EnumEveryConnection()){
    $cfg=$sharing.INetSharingConfigurationForINetConnection($connection)
    if($cfg.SharingEnabled -and $cfg.SharingConnectionType -eq 0){$sharing.NetConnectionProps($connection).Name}
   })
   # Modern Mobile Hotspot may not expose its public link through classic
   # HNetShare. Its saved uplink plus the live private address/DHCP listener
   # establishes the sharing role without treating intent alone as health.
   $hotspotFile=Join-Path $root 'state\hotspot-state.json'
   if(Test-Path $hotspotFile){
    $hotspot=Get-Content $hotspotFile -Raw|ConvertFrom-Json
    if($hotspot.enabled -and $hotspot.uplink){
     $privateAddress=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop|Where-Object IPAddress -eq '192.168.137.1')
     $dhcp=@(Get-NetUDPEndpoint -ErrorAction Stop|Where-Object {$_.LocalPort -eq 67 -and $_.LocalAddress -eq '192.168.137.1'})
     if($privateAddress.Count -and $dhcp.Count){$sharedNames+= [string]$hotspot.uplink}
    }
   }
   foreach($entry in (Get-Content "$root\config\mihomo-adapters.json" -Raw|ConvertFrom-Json)){
    $name=$entry.name
    $slot=if($entry.proxySlot){$entry.proxySlot}else{$name}
    $tokyo=$nodes."BALANCED-$slot"; $la=$nodes."LA-$slot"
    $fresh=$false
    foreach($node in @($tokyo,$la)){
     $last=@($node.history)|Select-Object -Last 1
     if($node.alive -and $last -and $last.delay -gt 0 -and ((Get-Date)-[datetime]$last.time).TotalSeconds -lt 120){$fresh=$true}
    }
    $required=$name -notin $sharedNames
    $health+=@{Adapter=$name;ProxyReachable=$fresh;ProxyRequired=$required;Role=$(if($required){'proxy'}else{'hotspot-uplink'})}
   }
  }catch{$healthError=$_.Exception.Message}
  if(-not $healthError -and ((Get-Date)-$lastStallCheck).TotalSeconds -ge 30){
   $stallActions=Invoke-AdapterStallRecovery -RepositoryRoot $root -Health $health | Out-String
   if($stallActions.Trim()){Write-RebootTrace $trace 'stall-recovery' @{Report=$stallActions.Trim()};"$(Get-Date -Format o) $($stallActions.Trim())"|Add-Content $log -Encoding UTF8}
   $lastStallCheck=Get-Date
  }
  # Keep transitions instead of losing the previous state when status.json is replaced.
  $healthKey=(@{Health=$health;Error=$healthError}|ConvertTo-Json -Depth 4 -Compress)
  if($healthKey -ne $previousHealth){
   Write-RebootTrace $trace 'proxy-health-change' @{Previous=$previousHealth;Health=$health;Error=$healthError}
   $previousHealth=$healthKey
  }
  $status='ok' 
  if($report -match 'absent or ambiguous|status=(?!Up)' -or $healthError -or @($health|Where-Object {$_.ProxyRequired -ne $false -and -not $_.ProxyReachable}).Count){$status='degraded'}
  @{Time=(Get-Date -Format o);Status=$status;Report=$report;ProxyHealth=$health;HealthError=$healthError}|ConvertTo-Json -Depth 4|Set-Content "$dir\status.json" -Encoding UTF8
 }catch{
  Write-RebootTrace $trace 'recovery-error' @{Message=$_.Exception.Message}
  "$(Get-Date -Format o) ERROR $($_.Exception.Message)"|Add-Content $log -Encoding UTF8
  @{Time=(Get-Date -Format o);Status='error';Error=$_.Exception.Message}|ConvertTo-Json|Set-Content "$dir\status.json" -Encoding UTF8
 }
 if(-not $Once){Start-Sleep -Seconds 10}
}while(-not $Once)
