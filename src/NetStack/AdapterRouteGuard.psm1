# Default-route reconciliation must not disturb live native or proxy sessions.
function Get-AdapterRouteGuardDecision {
 param($Snapshot,$Previous,[datetime]$NowUtc=[datetime]::UtcNow,[int]$QuietSeconds=120)
 $now=$NowUtc.ToUniversalTime()
 $since=$now
 $count=1
 if($Previous -and $Previous.Fingerprint -eq $Snapshot.Fingerprint){
  try {
   $last=[datetime]::Parse($Previous.LastObservedUtc).ToUniversalTime()
   $oldSince=[datetime]::Parse($Previous.StableSinceUtc).ToUniversalTime()
   # Missing observations and backward clocks cannot establish stability.
   if($now -ge $last -and ($now-$last).TotalSeconds -le 45 -and $oldSince -le $last){
    $since=$oldSince;$count=[int]$Previous.Observations+1
   }
  }catch{}
 }
 $reason='stable-and-idle'
 if(-not $Snapshot.InspectionSucceeded){$reason='inspection-unavailable';$since=$now;$count=1}
 elseif($Snapshot.ActiveConnections){$reason='preserving-active-connections';$since=$now;$count=1}
 elseif($Snapshot.HotspotPublic){$reason='preserving-hotspot';$since=$now;$count=1}
 elseif($count -lt 3 -or ($now-$since).TotalSeconds -lt $QuietSeconds){$reason='waiting-for-stable-idle-inventory'}
 [pscustomobject]@{
  Allowed=($reason -eq 'stable-and-idle');Reason=$reason
  State=[pscustomobject]@{Fingerprint=$Snapshot.Fingerprint;StableSinceUtc=$since.ToString('o');LastObservedUtc=$now.ToString('o');Observations=$count;Decision=$reason}
 }
}

function Get-AdapterRouteGuardSnapshot {
 param([array]$Adapters,[array]$Nics)
 $ErrorActionPreference='Stop'
 $inventory=@();$addresses=@();$hotspot=$false
 foreach($entry in $Adapters){
  $matches=@($Nics|Where-Object {
   ($entry.mac -and $_.MacAddress -eq $entry.mac) -or
   ($entry.interfaceGuid -and ([string]$_.InterfaceGuid).Trim('{}') -eq ([string]$entry.interfaceGuid).Trim('{}')) -or
   ($entry.pnpDeviceId -and $_.PnPDeviceID -eq $entry.pnpDeviceId)
  })
  if($matches.Count -ne 1){$inventory+="$($entry.name):unavailable:$($matches.Count)";continue}
  $nic=$matches[0];$identity=([string]$nic.InterfaceGuid).Trim('{}')
  $inventory+="$($entry.name):$identity`:$($nic.ifIndex):$($nic.Status)"
  if($nic.Status -ne 'Up'){continue}
  $ips=@(Get-NetIPAddress -InterfaceIndex $nic.ifIndex -ErrorAction Stop)
  $addresses+=@($ips|Select-Object -ExpandProperty IPAddress)
  $inventory+=@($ips|ForEach-Object {"ip:$identity`:$($_.IPAddress):$($_.AddressState)"})
  $interfaces=@(Get-NetIPInterface -InterfaceIndex $nic.ifIndex -ErrorAction Stop)
  $inventory+=@($interfaces|ForEach-Object {"interface:$identity`:$($_.AddressFamily):$($_.InterfaceMetric):$($_.ConnectionState)"})
  # Query the interface table first: an absent default is a valid observation.
  $routes=@(Get-NetRoute -InterfaceIndex $nic.ifIndex -ErrorAction Stop|Where-Object DestinationPrefix -in @('0.0.0.0/0','::/0'))
  $inventory+=@($routes|ForEach-Object {"route:$identity`:$($_.DestinationPrefix):$($_.NextHop):$($_.RouteMetric)"})
 }
 $tcp=@(Get-NetTCPConnection -State Established,SynSent -ErrorAction Stop|Where-Object LocalAddress -in $addresses)
 # Wildcard UDP bindings may be using any uplink; preserve them conservatively.
 $udp=@(Get-NetUDPEndpoint -ErrorAction Stop|Where-Object { $_.LocalAddress -in $addresses -or $_.LocalAddress -in @('0.0.0.0','::') })
 if($tcp.Count -eq 0 -and $udp.Count -eq 0){
  $sharing=New-Object -ComObject HNetCfg.HNetShare -ErrorAction Stop
  $guids=@($Nics|Select-Object -ExpandProperty InterfaceGuid|ForEach-Object {([string]$_).Trim('{}')})
  foreach($connection in $sharing.EnumEveryConnection()){
   $cfg=$sharing.INetSharingConfigurationForINetConnection($connection)
   if($cfg.SharingEnabled -and $cfg.SharingConnectionType -eq 0){
    $props=$sharing.NetConnectionProps($connection)
    if(([string]$props.Guid).Trim('{}') -in $guids){$hotspot=$true}
   }
  }
 }
 $sha=[Security.Cryptography.SHA256]::Create()
 try{$fingerprint=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((@($inventory|Sort-Object)-join "`n"))))).Replace('-','').ToLowerInvariant()}
 finally{$sha.Dispose()}
 [pscustomobject]@{InspectionSucceeded=$true;Fingerprint=$fingerprint;ActiveConnections=($tcp.Count -gt 0 -or $udp.Count -gt 0);HotspotPublic=$hotspot}
}

function Get-AdapterRouteMutationGuard {
 param([string]$RepositoryRoot,[array]$Adapters,[array]$Nics)
 try {
  $file=Join-Path $RepositoryRoot 'state\adapter-recovery\route-guard.json'
  $previous=$null
  if(Test-Path -LiteralPath $file){$previous=Get-Content -LiteralPath $file -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop}
  $snapshot=Get-AdapterRouteGuardSnapshot -Adapters $Adapters -Nics $Nics
  $result=Get-AdapterRouteGuardDecision -Snapshot $snapshot -Previous $previous
  $null=New-Item -ItemType Directory -Path (Split-Path $file -Parent) -Force -ErrorAction Stop
  $result.State|ConvertTo-Json -Depth 4|Set-Content -LiteralPath "$file.tmp" -Encoding UTF8 -ErrorAction Stop
  Move-Item -LiteralPath "$file.tmp" -Destination $file -Force -ErrorAction Stop
  return $result
 }catch{
  # Missing privileges, unreadable state or uncertain ICS/session ownership defer.
  return [pscustomobject]@{Allowed=$false;Reason='inspection-or-state-unavailable'}
 }
}
Export-ModuleMember -Function Get-AdapterRouteGuardDecision,Get-AdapterRouteGuardSnapshot,Get-AdapterRouteMutationGuard
