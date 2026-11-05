# Read-only diagnostics. Deliberately omit command lines, environment and proxy secrets.
[CmdletBinding()]param([Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
$data=[ordered]@{SchemaVersion=2;Time=(Get-Date -Format o);Pid=$PID;CaptureTimingsMs=[ordered]@{}}
function Capture($name,[scriptblock]$action){
 $timer=[Diagnostics.Stopwatch]::StartNew()
 try{$data[$name]=@(& $action)}catch{$data[$name]=@{Error=$_.Exception.Message}}
 finally{$data.CaptureTimingsMs[$name]=$timer.ElapsedMilliseconds}
}
Capture Identity { [Security.Principal.WindowsIdentity]::GetCurrent().Name }
Capture LastBoot { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o') }
Capture Adapters { Get-NetAdapter | Select-Object Name,ifIndex,Status,MacAddress,InterfaceGuid,LinkSpeed }
Capture AdapterIdentity {
 $adapters=@(Get-NetAdapter)
 foreach($entry in (Get-Content "$PSScriptRoot\..\config\mihomo-adapters.json" -Raw | ConvertFrom-Json)){
  $matches=@($adapters | Where-Object { $_.InterfaceGuid -eq $entry.interfaceGuid -or $_.MacAddress -eq $entry.mac -or $_.Name -eq $entry.name })
  [pscustomobject]@{ConfiguredName=$entry.name;ConfiguredMac=$entry.mac;MatchCount=$matches.Count;Observed=@($matches | Select-Object Name,MacAddress,InterfaceGuid,Status);MacMatches=(@($matches | Where-Object MacAddress -eq $entry.mac).Count -gt 0)}
 }
}
Capture IpInterfaces { Get-NetIPInterface -AddressFamily IPv4 | Select-Object InterfaceAlias,InterfaceIndex,InterfaceMetric,ConnectionState,Dhcp,AutomaticMetric }
Capture ConfigFingerprint { Get-FileHash "$PSScriptRoot\..\runtime\config.yaml" -Algorithm SHA256 | Select-Object Hash }
Capture Addresses { Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias,IPAddress,PrefixLength,AddressState }
Capture DefaultRoutes { Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object InterfaceAlias,NextHop,RouteMetric }
Capture DnsServers { Get-DnsClientServerAddress -AddressFamily IPv4 | Select-Object InterfaceAlias,ServerAddresses }
Capture LocalListeners {
 Get-NetTCPConnection -State Listen | Where-Object LocalPort -in @(7897,9097,8080) |
 Select-Object LocalAddress,LocalPort,OwningProcess
}
Capture Services {
 Get-Service | Where-Object Name -match 'SharedAccess|icssvc' |
 Select-Object Name,@{N='Status';E={[string]$_.Status}},@{N='StartType';E={[string]$_.StartType}}
}
Capture Tasks {
 Get-ScheduledTask | Where-Object TaskName -match 'Mihomo|Hotspot' |
 ForEach-Object {
  $info=$_ | Get-ScheduledTaskInfo
  [pscustomobject]@{Name=$_.TaskName;State=[string]$_.State;Enabled=$_.Settings.Enabled;LastRun=$info.LastRunTime;LastResult=$info.LastTaskResult}
 }
}
Capture SystemProxy {
 Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' | Select-Object ProxyEnable,ProxyServer
}
Capture MihomoProcess { Get-Process mihomo -ErrorAction SilentlyContinue | Select-Object Id,StartTime,CPU,WorkingSet64 }
Capture RecoveryHeartbeat { Get-Content "$PSScriptRoot\..\state\adapter-recovery\status.json" -Raw | ConvertFrom-Json }
Capture ProxySelection {
 $all=(Invoke-RestMethod 'http://127.0.0.1:9097/proxies' -TimeoutSec 3).proxies
 foreach($group in 'DISPATCH','AUTO','CHATGPT','ANTHROPIC','GOOGLE','DEV','IB','STORE','YOUTUBE','VIMEO','LINGODA','ZOOM','TOKYO-POOL','LA-POOL'){
  $g=$all.$group
  [pscustomobject]@{Group=$group;Type=$g.type;Selected=$g.now;Alive=$g.alive;MemberCount=@($g.all).Count}
 }
}
Capture AdapterProxyHealth {
 $all=(Invoke-RestMethod 'http://127.0.0.1:9097/proxies' -TimeoutSec 3).proxies
 foreach($p in $all.PSObject.Properties | Where-Object Name -match '^(BALANCED|LA)-'){
  [pscustomobject]@{Name=$p.Name;Alive=$p.Value.alive;History=$p.Value.history}
 }
}
$data | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
