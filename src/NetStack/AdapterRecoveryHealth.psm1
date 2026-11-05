function Get-AdapterRecoveryDecision {
 param([bool]$Healthy,[bool]$AlternativeHealthy,[int]$Failures,[double]$FailureSeconds,[double]$SinceAttemptSeconds,[int]$AttemptsLastHour,[bool]$ActiveConnections,[bool]$HotspotPublic,[bool]$DirectReachable)
 if($Healthy){return 'healthy'}
 if(-not $AlternativeHealthy){return 'no-working-alternative'}
 if($Failures -lt 3 -or $FailureSeconds -lt 90){return 'waiting-for-persistent-failure'}
 if($SinceAttemptSeconds -lt 900 -or $AttemptsLastHour -ge 3){return 'cooldown'}
 if($ActiveConnections){return 'preserving-active-connections'}
 if($HotspotPublic){return 'preserving-hotspot'}
 if($DirectReachable){return 'proxy-path-failure-only'}
 return 'restart-eligible'
}
function Test-AdapterDirectTcp {
 param([string]$SourceAddress,[string]$HostName)
 $ips=[Net.Dns]::GetHostAddresses($HostName)|Where-Object AddressFamily -eq InterNetwork
 if(-not $ips){throw "No IPv4 address for probe host"}
 $client=[Net.Sockets.TcpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
 try {
  $client.Client.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Parse($SourceAddress),0))
  $t=$client.ConnectAsync($ips[0],443)
  try{return ($t.Wait(2500) -and $client.Connected)}catch{return $false}
 }finally{$client.Dispose()}
}
function Invoke-AdapterStallRecovery {
 param([string]$RepositoryRoot,[array]$Health)
 $ErrorActionPreference='Stop'
 $file=Join-Path $RepositoryRoot 'state\adapter-recovery\stall-state.json'
 $states=@{}
 if(Test-Path $file){
  $saved=Get-Content $file -Raw|ConvertFrom-Json
  foreach($property in $saved.PSObject.Properties){$states[$property.Name]=$property.Value}
 }
 $now=Get-Date
 foreach($entry in (Get-Content "$RepositoryRoot\config\mihomo-adapters.json" -Raw|ConvertFrom-Json)){
  $name=$entry.name
  if(-not $states.ContainsKey($name)){$states[$name]=[pscustomobject]@{Failures=0;FirstFailure=$null;Attempts=@();Decision='new'}}
  $s=$states[$name]
  $s.Attempts=@($s.Attempts|Where-Object {($now-[datetime]$_).TotalSeconds -lt 3600})
  $h=@($Health|Where-Object Adapter -eq $name)
  $nic=@(Get-NetAdapter|Where-Object {
   ($entry.mac -and $_.MacAddress -eq $entry.mac) -or
   ($entry.interfaceGuid -and ([string]$_.InterfaceGuid).Trim('{}') -eq ([string]$entry.interfaceGuid).Trim('{}')) -or
   ($entry.pnpDeviceId -and $_.PnPDeviceID -eq $entry.pnpDeviceId)
  })
  if($nic.Count -ne 1 -or $nic[0].Status -ne 'Up'){$s.Failures=0;$s.FirstFailure=$null;$s.Decision='absent-ambiguous-or-disconnected';continue}
  if($h.Count -ne 1){$s.Decision='health-unknown';continue}
  if($h[0].ProxyRequired -eq $false){$s.Failures=0;$s.FirstFailure=$null;$s.Decision='reserved-for-hotspot';continue}
  if($h[0].ProxyReachable){$s.Failures=0;$s.FirstFailure=$null;$s.Decision='healthy';continue}
  $s.Failures++;if(-not $s.FirstFailure){$s.FirstFailure=$now.ToString('o')}
  $last=@($s.Attempts)|Select-Object -Last 1
  $since=if($last){($now-[datetime]$last).TotalSeconds}else{999999}
  $argsForDecision=@{Healthy=$false;AlternativeHealthy=(@($Health|Where-Object ProxyReachable).Count -gt 0);Failures=$s.Failures;FailureSeconds=($now-[datetime]$s.FirstFailure).TotalSeconds;SinceAttemptSeconds=$since;AttemptsLastHour=@($s.Attempts).Count;ActiveConnections=$false;HotspotPublic=$false;DirectReachable=$false}
  $decision=Get-AdapterRecoveryDecision @argsForDecision
  if($decision -eq 'restart-eligible'){
   try {
    $ips=@(Get-NetIPAddress -InterfaceIndex $nic[0].ifIndex -AddressFamily IPv4|Where-Object AddressState -eq Preferred|Select-Object -ExpandProperty IPAddress)
    if(-not $ips){throw 'No preferred IPv4 address; normal reconciliation must restore it first'}
    $active=@(Get-NetTCPConnection -State Established -ErrorAction Stop|Where-Object LocalAddress -in $ips)
    $udp=@(Get-NetUDPEndpoint -ErrorAction Stop|Where-Object LocalAddress -in $ips)
    $argsForDecision.ActiveConnections=($active.Count -gt 0 -or $udp.Count -gt 0)
    if(-not $argsForDecision.ActiveConnections){
     # If ICS cannot be inspected, refuse to reset rather than risk the hotspot.
     $sharing=New-Object -ComObject HNetCfg.HNetShare
     foreach($connection in $sharing.EnumEveryConnection()){
      $cfg=$sharing.INetSharingConfigurationForINetConnection($connection)
      if($cfg.SharingEnabled -and $cfg.SharingConnectionType -eq 0){
       $props=$sharing.NetConnectionProps($connection)
       if(([string]$props.Guid).Trim('{}') -eq ([string]$nic[0].InterfaceGuid).Trim('{}')){$argsForDecision.HotspotPublic=$true}
      }
     }
     if(-not $argsForDecision.HotspotPublic){
      $argsForDecision.DirectReachable=(Test-AdapterDirectTcp $ips[0] 'www.baidu.com') -or (Test-AdapterDirectTcp $ips[0] 'www.qq.com')
     }
    }
    $decision=Get-AdapterRecoveryDecision @argsForDecision
    if($decision -eq 'restart-eligible'){
     # Persist the attempt BEFORE touching hardware so crashes cannot cause reset loops.
     $s.Attempts+= $now.ToString('o');$s.Decision='restart-started'
     $states|ConvertTo-Json -Depth 6|Set-Content $file -Encoding UTF8
     Restart-NetAdapter -InputObject $nic[0] -Confirm:$false
     & "$RepositoryRoot\tools\Repair-MihomoAdapters.ps1" -Only $name|Out-Null
     $s.Failures=0;$s.FirstFailure=$null;$decision='restarted-awaiting-health'
    }
   }catch{$decision='deferred: '+$_.Exception.Message}
  }
  if($s.Decision -ne $decision){Write-Output "$name recovery: $decision"}
  $s.Decision=$decision
 }
 $states|ConvertTo-Json -Depth 6|Set-Content $file -Encoding UTF8
}
Export-ModuleMember -Function Get-AdapterRecoveryDecision,Invoke-AdapterStallRecovery
