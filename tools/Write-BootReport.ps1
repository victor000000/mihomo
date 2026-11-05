# Read-only post-boot diagnostic report. Never repairs adapters, selections, or the proxy.
# Writes one JSON + one text file per invocation so a post-reboot failure is explainable
# from a single artifact. Safe to run at any time; every section is independently guarded.
[CmdletBinding()]
param(
 [switch]$Probe,
 [string]$OutputDirectory,
 [ValidateRange(3,30)][int]$ProbeTimeoutSeconds=8,
 [ValidateRange(0,600)][int]$DelaySeconds=0,
 [ValidatePattern('^[A-Za-z0-9._-]*$')][string]$Label=''
)
if($DelaySeconds -gt 0){Start-Sleep -Seconds $DelaySeconds}
$ErrorActionPreference='Continue'
$root=Split-Path -Parent $PSScriptRoot
$managedNames=@('jd_5G','pisen_2026_03','pisen_2026_10','win_turbo_phone')
try{
 $identity=Get-Content (Join-Path $root 'config\mihomo-adapters.json') -Raw -ErrorAction Stop|ConvertFrom-Json
 $managedNames=@($identity|ForEach-Object {$_.name}|Where-Object {$_})
}catch{}
$trace=$null
try{
 Import-Module "$root\src\NetStack\RebootTrace.psm1" -Force
 $trace=New-RebootTrace $root 'boot-report'
}catch{}

$now=Get-Date
$boot=$now
try{$boot=(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime}catch{}
if(-not $OutputDirectory){
 $OutputDirectory=Join-Path $root ("state\reboot-tests\{0}" -f $boot.ToString('yyyyMMdd-HHmmss'))
}
try{New-Item $OutputDirectory -ItemType Directory -Force|Out-Null}catch{}

$warnings=New-Object System.Collections.ArrayList
$notes=New-Object System.Collections.ArrayList
function Add-Warning([string]$text){if($text){[void]$warnings.Add($text)}}
function Add-Note([string]$text){if($text){[void]$notes.Add($text)}}
# Null-tolerant count: @($null).Count is 1 in PowerShell 7, which would report phantom processes.
function Count-Of($value){@($value|Where-Object {$_}).Count}

$report=[ordered]@{
 SchemaVersion=1
 Time=$now.ToString('o')
 BootTime=$boot.ToString('o')
 UptimeSeconds=[int]($now-$boot).TotalSeconds
 Pid=$PID
 User=''
 Elevated=$false
 OutputDirectory=$OutputDirectory
 TimingsMs=[ordered]@{}
 Sections=@()
 Warnings=@()
 Notes=@()
 Verdict='unknown'
}
try{
 $report.User=[Security.Principal.WindowsIdentity]::GetCurrent().Name
 $report.Elevated=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}catch{}

$data=[ordered]@{}
function Add-Section([string]$name,[scriptblock]$action){
 $sw=[Diagnostics.Stopwatch]::StartNew()
 try{$data[$name]=@(& $action)}
 catch{$data[$name]=@([ordered]@{Error=$_.Exception.Message;Line=$_.InvocationInfo.ScriptLineNumber})}
 finally{$report.TimingsMs[$name]=[int]$sw.ElapsedMilliseconds}
}

Add-Section Host {
 [ordered]@{
  Computer=$env:COMPUTERNAME
  Os=(Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,LastBootUpTime)
  PowerShell=$PSVersionTable.PSVersion.ToString()
  PowerShellEdition=$PSVersionTable.PSEdition
  Culture=[Globalization.CultureInfo]::CurrentCulture.Name
  TimeZone=[TimeZoneInfo]::Local.Id
  SessionName=$env:SESSIONNAME
 }
}

# One process snapshot, reused by every section (CIM access to SYSTEM processes may be limited).
$allProcs=@()
try{$allProcs=@(Get-CimInstance Win32_Process -ErrorAction Stop)}catch{}
function Select-Proc([string]$pattern,[string]$namePattern='^(pwsh|powershell)\.exe$'){
 # Project helpers are always launched with -File; requiring it avoids matching this report's
 # own -Command harness wrapper (whose command line can contain the script name being queried).
 @($allProcs|Where-Object {
   $_.CommandLine -and $_.CommandLine -like "*$pattern*" -and $_.Name -match $namePattern -and
   $_.CommandLine -like '*-File*' -and $_.ProcessId -ne $PID
  }|ForEach-Object {
  [ordered]@{Pid=$_.ProcessId;Name=$_.Name;ParentPid=$_.ParentProcessId;Started=$_.CreationDate}
 })
}
$mihomoProcs=@($allProcs|Where-Object {$_.Name -eq 'mihomo.exe'}|ForEach-Object {
 [ordered]@{Pid=$_.ProcessId;Executable=$_.ExecutablePath;CommandLine=$_.CommandLine;Started=$_.CreationDate}
})

$mihomoPid=0
try{$mihomoPid=[int](@(Get-Process mihomo -ErrorAction SilentlyContinue)[0].Id)}catch{}

Add-Section Processes {
 # try/catch is a statement, not an expression: compute values before the hashtable.
 $runtimeInfo=$null
 if($mihomoPid){
  try{$runtimeInfo=Get-Process -Id $mihomoPid -ErrorAction Stop|Select-Object Id,StartTime,@{N='WorkingSetMB';E={[int]($_.WorkingSet64/1MB)}},@{N='CpuSeconds';E={[int]$_.CPU}}}
  catch{$runtimeInfo=[ordered]@{Error=$_.Exception.Message}}
 }
 [ordered]@{
  Mihomo=$mihomoProcs
  MihomoRuntime=$runtimeInfo
  Supervisor=Select-Proc 'mihomo-supervisor.ps1'
  PacServer=Select-Proc 'Serve-Pac.ps1'
  NetworkDiagnostics=Select-Proc 'Watch-NetworkDiagnostics.ps1'
  AdapterRecovery=Select-Proc 'Watch-MihomoAdapters.ps1'
  BootObserver=Select-Proc 'Watch-MihomoBoot.ps1'
  ManagedAdapterCount=$managedNames.Count
 }
}

Add-Section Listeners {
 @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue|
  Where-Object {$_.LocalPort -in 7897,9097,8080}|
  ForEach-Object {
   $owner=''
   try{$owner=(Get-Process -Id $_.OwningProcess -ErrorAction Stop).ProcessName}catch{}
   [ordered]@{Port=$_.LocalPort;Address=$_.LocalAddress;Pid=$_.OwningProcess;Process=$owner}
  })
}

Add-Section Controller {
 $result=[ordered]@{Version=$null;Meta=$null;Config=$null;Selection=@();Error=$null}
 try{
  $v=Invoke-RestMethod 'http://127.0.0.1:9097/version' -TimeoutSec 4
  $result.Version=$v.version;$result.Meta=$v.meta
 }catch{$result.Error=$_.Exception.Message}
 try{
  $c=Invoke-RestMethod 'http://127.0.0.1:9097/configs' -TimeoutSec 4
  $result.Config=[ordered]@{Port=$c.port;Mode=$c.mode;AllowLan=$c.'allow-lan';BindAddress=$c.'bind-address';TunEnabled=$c.tun.enable;DnsEnabled=$c.dns.enable;LogLevel=$c.'log-level';Ipv6=$c.ipv6}
 }catch{if(-not $result.Error){$result.Error=$_.Exception.Message}}
 if(-not $result.Error){
  try{
   $all=(Invoke-RestMethod 'http://127.0.0.1:9097/proxies' -TimeoutSec 5).proxies
   foreach($g in 'DISPATCH','WAN-ACTIVE','LOCAL','AUTO','CHATGPT','ANTHROPIC','GOOGLE','DEV','IB','STORE','YOUTUBE','LINGODA','ZOOM','TOS','TWS','FUTU-DIRECT','TOKYO-POOL','LA-POOL'){
    $node=$all.$g
    if($node){$result.Selection+=[ordered]@{Group=$g;Type=$node.type;Selected=$node.now;Alive=$node.alive;Members=@($node.all).Count}}
   }
  }catch{$result.Error=$_.Exception.Message}
 }
 $result
}

Add-Section RuntimeFiles {
 $cfg=Join-Path $root 'runtime\config.yaml'
 $files=@()
 foreach($rel in @('runtime\config.yaml','runtime\mihomo.exe','runtime\mihomo-supervisor.ps1','tools\Serve-Pac.ps1','tools\Mihomo-Startup.ps1','tools\Watch-NetworkDiagnostics.ps1','tools\Write-BootReport.ps1','state\proxy.pac')){
  $path=Join-Path $root $rel
  $item=Get-Item $path -ErrorAction SilentlyContinue
  $hash=$null
  if($item -and $item.Length -lt 20MB){try{$hash=(Get-FileHash $path -Algorithm SHA256 -ErrorAction Stop).Hash}catch{}}
  $files+=[ordered]@{Path=$rel;Exists=(-not -not $item);Bytes=if($item){$item.Length}else{0};Modified=if($item){$item.LastWriteTime.ToString('o')}else{$null};Sha256=$hash}
 }
 [ordered]@{ConfigSha256=(Get-FileHash $cfg -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash;Files=$files}
}

Add-Section Adapters {
 $adapters=@(Get-NetAdapter -ErrorAction SilentlyContinue)
 $rows=@()
 foreach($a in $adapters){
  $rows+=[ordered]@{Name=$a.Name;Description=$a.InterfaceDescription;Status=[string]$a.Status;Mac=$a.MacAddress;IfIndex=$a.ifIndex;LinkSpeed=$a.LinkSpeed;Guid=$a.InterfaceGuid}
 }
 $identityRows=@()
 try{
  foreach($entry in $identity){
   $match=@($adapters|Where-Object {$_.InterfaceGuid -eq $entry.interfaceGuid -or $_.MacAddress -eq $entry.mac -or $_.Name -eq $entry.name})
   $identityRows+=[ordered]@{Configured=$entry.name;ConfiguredMac=$entry.mac;Matches=$match.Count;Observed=@($match|Select-Object Name,MacAddress,Status)}
  }
 }catch{}
 [ordered]@{All=$rows;Managed=@($rows|Where-Object {$_.Name -in $managedNames});ConfiguredIdentity=$identityRows}
}

Add-Section Network {
 $ipv4=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue|Select-Object InterfaceAlias,IPAddress,PrefixLength,AddressState)
 $ifaces=@(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue)
 $routes=@(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue|ForEach-Object {
  $r=$_;$i=$ifaces|Where-Object InterfaceIndex -eq $r.InterfaceIndex|Select-Object -First 1
  [ordered]@{Interface=$r.InterfaceAlias;Index=$r.InterfaceIndex;NextHop=$r.NextHop;RouteMetric=$r.RouteMetric;InterfaceMetric=if($i){$i.InterfaceMetric}else{$null};State=if($i){[string]$i.ConnectionState}else{$null}}
 })
 [ordered]@{Addresses=$ipv4;DefaultRoutes=$routes;DnsServers=@(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue|Select-Object InterfaceAlias,ServerAddresses)}
}

Add-Section SystemProxy {
 $key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
 $p=Get-ItemProperty $key -ErrorAction SilentlyContinue
 $envProxies=@()
 foreach($n in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','http_proxy','https_proxy','all_proxy','no_proxy'){
  $v=[Environment]::GetEnvironmentVariable($n)
  if($v){$envProxies+="$n=$v"}
 }
 [ordered]@{ProxyEnable=$p.ProxyEnable;ProxyServer=$p.ProxyServer;ProxyOverride=$p.ProxyOverride;AutoConfigURL=$p.AutoConfigURL;Environment=$envProxies;PacUrl='http://127.0.0.1:8080/proxy.pac'}
}

Add-Section Pac {
 $result=[ordered]@{Listening=$false;Status=$null;Error=$null;Ms=$null}
 $listen=@(Get-NetTCPConnection -State Listen -LocalPort 8080 -ErrorAction SilentlyContinue)
 $result.Listening=$listen.Count -gt 0
 $sw=[Diagnostics.Stopwatch]::StartNew()
 try{
  $r=Invoke-WebRequest 'http://127.0.0.1:8080/proxy.pac' -UseBasicParsing -TimeoutSec 3
  $result.Status=$r.StatusCode
 }catch{$result.Error=$_.Exception.Message}
 finally{$sw.Stop();$result.Ms=$sw.ElapsedMilliseconds}
 $result
}

Add-Section Hotspot {
 $result=[ordered]@{Services=@();IcsAddress=$null;Task=$null;Snapshot=$null}
 try{$result.Services=@(Get-Service SharedAccess,icssvc -ErrorAction SilentlyContinue|Select-Object Name,@{N='Status';E={[string]$_.Status}},@{N='StartType';E={[string]$_.StartType}})}catch{}
 try{$result.IcsAddress=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue|Where-Object {$_.IPAddress -eq '192.168.137.1'}|Select-Object InterfaceAlias,IPAddress)}catch{}
 try{
  $task=Get-ScheduledTask -TaskName MihomoHotspot -ErrorAction Stop
  $info=Get-ScheduledTaskInfo -TaskName MihomoHotspot -ErrorAction SilentlyContinue
  $result.Task=[ordered]@{State=[string]$task.State;Enabled=$task.Settings.Enabled;LastRunTime=$info.LastRunTime;LastResult=$info.LastTaskResult;Trigger=if($task.Triggers){$task.Triggers[0].CimClass.CimClassName}else{$null}}
 }catch{$result.Task=[ordered]@{Error=$_.Exception.Message}}
 try{
  if(Test-Path (Join-Path $root 'state\hotspot.json')){
   $result.Snapshot=(Get-Content (Join-Path $root 'state\hotspot.json') -Raw|ConvertFrom-Json)
  }
 }catch{}
 $result
}

Add-Section Startup {
 $startup=Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
 $result=[ordered]@{StartupFolder=@();Tasks=@();RunKey=@()}
 try{
  foreach($f in @(Get-ChildItem $startup -File -ErrorAction SilentlyContinue)){
   $content=''
   if($f.Extension -in '.vbs','.cmd','.bat'){try{$content=(Get-Content $f.FullName -Raw -ErrorAction Stop).Trim()}catch{}}
   $result.StartupFolder+=[ordered]@{Name=$f.Name;Bytes=$f.Length;Content=$content}
  }
 }catch{}
 try{
  $result.Tasks=@(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object TaskName -match 'Mihomo|Hotspot'|ForEach-Object {
   $info=$_|Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
   [ordered]@{Name=$_.TaskName;State=[string]$_.State;Enabled=$_.Settings.Enabled;LastRunTime=$info.LastRunTime;LastResult=$info.LastTaskResult;User=$_.Principal.UserId;Triggers=@($_.Triggers|ForEach-Object {$_.CimClass.CimClassName})}
  })
 }catch{}
 try{
  $run=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
  if($run){$run.PSObject.Properties|Where-Object {$_.Name -notlike 'PS*'}|ForEach-Object {$result.RunKey+="$($_.Name)=$($_.Value)"}}
 }catch{}
 $result
}

Add-Section Dns {
 $result=[ordered]@{Resolve=@()}
 foreach($name in 'www.baidu.com','api.openai.com','class.lingoda.com'){
  $sw=[Diagnostics.Stopwatch]::StartNew()
  $row=[ordered]@{Name=$name;Ok=$false;Count=0;First=$null;Ms=$null;Error=$null}
  try{
   $answers=@([System.Net.Dns]::GetHostAddresses($name))
   $row.Ok=$answers.Count -gt 0;$row.Count=$answers.Count
   if($answers.Count){$row.First=$answers[0].IPAddressToString}
  }catch{$row.Error=$_.Exception.Message}
  finally{$sw.Stop();$row.Ms=$sw.ElapsedMilliseconds}
  $result.Resolve+=$row
 }
 $result
}

Add-Section RecoveryHeartbeat {
 # The boot-triggered recovery watcher runs as SYSTEM, so its command line is unreadable to a
 # normal user; its heartbeat file is the reliable evidence that it is alive.
 $path=Join-Path $root 'state\adapter-recovery\status.json'
 $result=[ordered]@{Path='state\adapter-recovery\status.json';Exists=$false;AgeSeconds=$null;Time=$null;Status=$null;ProxyHealth=@();Error=$null}
 try{
  $item=Get-Item $path -ErrorAction Stop
  $result.Exists=$true
  $result.AgeSeconds=[int]((Get-Date)-$item.LastWriteTime).TotalSeconds
  $heartbeat=Get-Content $path -Raw -ErrorAction Stop|ConvertFrom-Json
  $result.Time=$heartbeat.Time
  $result.Status=$heartbeat.Status
  $result.ProxyHealth=$heartbeat.ProxyHealth
 }catch{$result.Error=$_.Exception.Message}
 $result
}

Add-Section Probes {
 if(-not $Probe){return [ordered]@{Skipped='Pass -Probe to run transport probes'}}
 $targets=@(
  @{Name='google-proxied';Url='https://www.gstatic.com/generate_204';Proxy=$true},
  @{Name='openai-proxied';Url='https://api.openai.com/v1/models';Proxy=$true},
  @{Name='baidu-proxied';Url='https://www.baidu.com/';Proxy=$true},
  @{Name='google-direct';Url='https://www.gstatic.com/generate_204';Proxy=$false}
 )
 $rows=@()
 $curl=Join-Path $env:WINDIR 'System32\curl.exe'
 foreach($t in $targets){
  $row=[ordered]@{Target=$t.Name;Proxy=$t.Proxy;Exit=$null;TimedOut=$false;HttpCode=$null;Timings='';Error=$null;Ms=$null}
  $sw=[Diagnostics.Stopwatch]::StartNew()
  $stdout=Join-Path $env:TEMP ("bootreport-{0}-{1}.out" -f $t.Name,$PID)
  $stderr=Join-Path $env:TEMP ("bootreport-{0}-{1}.err" -f $t.Name,$PID)
  try{
   $proxyArg=if($t.Proxy){'--proxy http://127.0.0.1:7897'}else{'--noproxy *'}
   $arguments='--silent --show-error --output NUL '+$proxyArg+' --connect-timeout 4 --max-time '+$ProbeTimeoutSeconds+' --write-out "%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}" '+$t.Url
   $proc=Start-Process $curl -WindowStyle Hidden -PassThru -ArgumentList $arguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr
   $null=$proc.Handle
   if(-not $proc.WaitForExit(($ProbeTimeoutSeconds+4)*1000)){$proc.Kill();$proc.WaitForExit();$row.TimedOut=$true}
   $row.Exit=$proc.ExitCode
   $text=(Get-Content $stdout -Raw -ErrorAction SilentlyContinue)
   if($text){$parts=$text.Trim() -split '\s+';$row.HttpCode=$parts[0];$row.Timings=($parts|Select-Object -Skip 1) -join ' '}
   $row.Error=(Get-Content $stderr -Raw -ErrorAction SilentlyContinue)
   $proc.Dispose()
  }catch{$row.Error=$_.Exception.Message}
  finally{$sw.Stop();$row.Ms=$sw.ElapsedMilliseconds}
  foreach($f in $stdout,$stderr){Remove-Item $f -Force -ErrorAction SilentlyContinue}
  $rows+=$row
 }
 $rows
}

$report.Sections=$data

# ---- Verdict and warnings: computed from collected sections, never from assumptions ----
try{
 $proc=$data['Processes']
 $listen=@($data['Listeners'])
 $ports=@($listen|ForEach-Object {$_.Port})
 $proxy=$data['SystemProxy']
 $hasProxyListener=$ports -contains 7897
 if((Count-Of $proc.Mihomo) -eq 0){Add-Warning 'mihomo.exe is not running'}
 if((Count-Of $proc.Supervisor) -eq 0){Add-Warning 'mihomo supervisor is not running (nothing will restart mihomo)'}
 if(-not $hasProxyListener){Add-Warning 'no listener on port 7897 (applications using the system proxy cannot connect)'}
 if($proxy.ProxyEnable -eq 1 -and -not $hasProxyListener){Add-Warning 'system proxy is enabled but 7897 has no listener; applications will fail until the proxy starts or the proxy is disabled'}
 if($proxy.ProxyEnable -ne 1){Add-Warning 'user system proxy is disabled (ProxyEnable=0); applications that rely on it bypass mihomo'}
 if($proxy.ProxyServer -and $proxy.ProxyServer -ne '127.0.0.1:7897'){Add-Warning "system proxy target is $($proxy.ProxyServer), expected 127.0.0.1:7897"}
 $controller=$data['Controller']
 if($controller.Error){Add-Warning "controller API error: $($controller.Error)"}
 if(-not ($ports -contains 9097)){Add-Warning 'no controller listener on port 9097'}
 if(-not ($ports -contains 8080)){Add-Warning 'PAC server is not listening on port 8080 (hotspot clients and PAC clients have no proxy config)'}
 if((Count-Of $proc.NetworkDiagnostics) -eq 0){Add-Warning 'continuous diagnostics observer is not running (Watch-NetworkDiagnostics.ps1)'}
 $adapters=$data['Adapters']
 foreach($row in @($adapters.Managed)){
  if($row -and $row.Status -ne 'Up'){Add-Warning "managed adapter $($row.Name) is $($row.Status)"}
 }
 foreach($row in @($adapters.ConfiguredIdentity)){
  if($row -and [int]$row.Matches -eq 0){Add-Warning "configured adapter '$($row.Configured)' does not match any present adapter (name/MAC/GUID)"}
 }
 $hotspot=$data['Hotspot']
 if($hotspot.Task -and $hotspot.Task.Error){Add-Warning "hotspot task unavailable: $($hotspot.Task.Error)"}
 elseif($hotspot.Task -and -not $hotspot.Task.Enabled){Add-Warning 'MihomoHotspot scheduled task is disabled'}
 foreach($svc in @($hotspot.Services)){if($svc -and $svc.Status -ne 'Running'){Add-Warning "service $($svc.Name) is $($svc.Status) (Windows Internet Connection Sharing)"}}
 $routes=@($data['Network'].DefaultRoutes)
 if(-not $routes.Count){Add-Warning 'no IPv4 default route present'}
 $defaultRoute=@($routes|Sort-Object {[int]$_.InterfaceMetric+[int]$_.RouteMetric}|Select-Object -First 1)
 if($defaultRoute.Count){Add-Note ("Windows default route prefers {0} (total metric {1})" -f $defaultRoute[0].Interface,([int]$defaultRoute[0].InterfaceMetric+[int]$defaultRoute[0].RouteMetric))}
 $dns=@($data['Dns'].Resolve)
 foreach($row in $dns){if($row -and -not $row.Ok){Add-Warning "DNS resolution failed for $($row.Name): $($row.Error)"}}
 if($Probe){
  $probes=@($data['Probes'])
  $proxiedOk=@($probes|Where-Object {$_.Proxy -and $_.Exit -eq 0}).Count
  $directOk=@($probes|Where-Object {-not $_.Proxy -and $_.Exit -eq 0}).Count
  if(-not $proxiedOk){Add-Warning 'every proxied HTTP probe failed (127.0.0.1:7897 cannot reach the Internet)'}
  if(-not $directOk){Add-Warning 'the direct HTTP probe failed (this machine may have no working default route/DNS)'}
  if($proxiedOk -and $directOk){Add-Note 'both proxied and direct probes answered'}
 }
 $recovery=$data['RecoveryHeartbeat']
 if($recovery.Exists -and $recovery.AgeSeconds -gt 300){Add-Warning "adapter recovery heartbeat is $($recovery.AgeSeconds)s old (boot-time recovery watcher may have stopped)"}
 if($recovery.Exists){
  foreach($row in @($recovery.ProxyHealth)){if($row -and $row.ProxyReachable -eq $false){Add-Warning "adapter $($row.Adapter) is not reachable through its bound proxy path"}}
 }else{Add-Warning 'adapter recovery heartbeat file is missing (boot-time adapter recovery has never run)'}
}catch{Add-Warning "verdict computation failed: $($_.Exception.Message)"}

$report.Warnings=@($warnings)
$report.Notes=@($notes)
$report.Verdict=if($warnings.Count){'issues'}else{'ok'}

# ---- Previous boot comparison: a config or boot-time regression is visible here ----
try{
 $previousPath=Join-Path $root 'state\last-boot-report.json'
 if(Test-Path $previousPath){
  $previous=Get-Content $previousPath -Raw -ErrorAction Stop|ConvertFrom-Json
  $currentHash=($data['RuntimeFiles']).ConfigSha256
  $previousHash=($previous.Sections.RuntimeFiles).ConfigSha256
  $report['Previous']=[ordered]@{
   ReportedAt=$previous.Time
   BootTime=$previous.BootTime
   ConfigSha256=$previousHash
   ConfigChanged=($previousHash -and $currentHash -and $previousHash -ne $currentHash)
   SameBoot=($previous.BootTime -eq $report.BootTime)
  }
  if($previousHash -and $currentHash -and $previousHash -ne $currentHash){Add-Note "runtime config changed since $($previous.Time) (hash $($previousHash.Substring(0,12)) -> $($currentHash.Substring(0,12)))"}
  $report.Notes=@($notes)
 }else{
  Add-Note 'first boot report on this machine (no state/last-boot-report.json yet)'
  $report.Notes=@($notes)
 }
}catch{}

$report['Verdict']=if($warnings.Count){'issues'}else{'ok'}

$suffix=if($Label){"-$Label"}else{''}
$jsonPath=Join-Path $OutputDirectory "boot-report$suffix.json"
$textPath=Join-Path $OutputDirectory "boot-report$suffix.txt"
try{$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $jsonPath -Encoding UTF8}catch{}
try{$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $root 'state\last-boot-report.json') -Encoding UTF8}catch{}

$lines=New-Object System.Collections.ArrayList
[void]$lines.Add(('BOOT REPORT {0}  boot={1:o}  uptime={2}s  user={3}  elevated={4}' -f $report.Time,$boot,$report.UptimeSeconds,$report.User,$report.Elevated))
[void]$lines.Add(('VERDICT: {0}  issues={1}' -f $report.Verdict.ToUpperInvariant(),$warnings.Count))
foreach($w in $warnings){[void]$lines.Add("  [!] $w")}
foreach($n in $notes){[void]$lines.Add("  [i] $n")}
try{
 $proxy=$data['SystemProxy']
 [void]$lines.Add(('proxy: ProxyEnable={0} server={1} override={2}' -f $proxy.ProxyEnable,$proxy.ProxyServer,$proxy.ProxyOverride))
 $ports=@($data['Listeners']|ForEach-Object {('{0}(pid {1} {2})' -f $_.Port,$_.Pid,$_.Process)}) -join ' '
 [void]$lines.Add("listeners: $ports")
 $controller=$data['Controller']
 [void]$lines.Add(('controller: version={0} mode={1} tun={2} dns={3} error={4}' -f $controller.Version,$controller.Config.Mode,$controller.Config.TunEnabled,$controller.Config.DnsEnabled,$controller.Error))
 $proc=$data['Processes']
 [void]$lines.Add(('processes: mihomo={0} supervisor={1} pac={2} diagnostics={3} recovery={4}' -f (Count-Of $proc.Mihomo),(Count-Of $proc.Supervisor),(Count-Of $proc.PacServer),(Count-Of $proc.NetworkDiagnostics),(Count-Of $proc.AdapterRecovery)))
 $adapterText=@($data['Adapters'].Managed|ForEach-Object {"$($_.Name)=$($_.Status)($($_.Mac))"}) -join ' '
 [void]$lines.Add("adapters: $adapterText")
 $routeText=@($data['Network'].DefaultRoutes|ForEach-Object {"$($_.Interface) metric=$($_.InterfaceMetric)/$($_.RouteMetric) state=$($_.State)"}) -join ' | '
 [void]$lines.Add("default routes: $routeText")
 $dnsText=@($data['Dns'].Resolve|ForEach-Object {"$($_.Name)=$(if($_.Ok){"ok $($_.Ms)ms $($_.First)"}else{"FAIL $($_.Error)"})"}) -join ' | '
 [void]$lines.Add("dns: $dnsText")
 $recoverySample=$data['RecoveryHeartbeat']
 $recoveryAdapters=@($recoverySample.ProxyHealth|ForEach-Object {"$($_.Adapter)=$($_.ProxyReachable)"}) -join ' '
 [void]$lines.Add(('recovery: heartbeat={0} age={1}s status={2} adapters={3}' -f $recoverySample.Time,$recoverySample.AgeSeconds,$recoverySample.Status,$recoveryAdapters))
 if($Probe){
  $probeText=@($data['Probes']|ForEach-Object {"$($_.Target)=$(if($_.HttpCode){$_.HttpCode}else{'ERR'}) exit=$($_.Exit) $($_.Ms)ms"}) -join ' | '
  [void]$lines.Add("probes: $probeText")
 }
 $cfg=$data['RuntimeFiles']
 [void]$lines.Add("config: sha256=$($cfg.ConfigSha256) bytes=$((@($cfg.Files)|Where-Object Path -eq 'runtime\config.yaml').Bytes)")
 [void]$lines.Add("report: $jsonPath")
}catch{}
try{[void]$lines.Add(('section timings ms: '+(($report.TimingsMs.GetEnumerator()|ForEach-Object {"$($_.Key)=$($_.Value)"}) -join ' ')))}catch{}
$text=($lines -join [Environment]::NewLine)
try{Set-Content -LiteralPath $textPath -Value $text -Encoding UTF8}catch{}
if($trace){try{Write-RebootTrace $trace 'boot-report' @{Verdict=$report.Verdict;Warnings=$report.Warnings;JsonPath=$jsonPath;TextPath=$textPath;BootTime=$report.BootTime;UptimeSeconds=$report.UptimeSeconds}}catch{}}
$text
