# Read-only continuous diagnostics. Never repairs adapters or changes proxy selections.
# Every loop iteration is guarded: a transient WMI/DNS/HTTP failure is logged and the
# observer keeps running, because a dead observer is invisible exactly when it is needed.
[CmdletBinding()]
param([switch]$Once,[ValidateRange(15,3600)][int]$IntervalSeconds=60,[ValidateRange(60,86400)][int]$ProbeIntervalSeconds=300)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module "$root\src\NetStack\RebootTrace.psm1" -Force
$managedAdapters=@('jd_5G','pisen_2026_03','pisen_2026_10','win_turbo_phone')
try{$managedAdapters=@(Get-Content "$root\config\mihomo-adapters.json" -Raw|ConvertFrom-Json|ForEach-Object {$_.name}|Where-Object {$_})}catch{}
# File lock prevents duplicate observers across logon/manual launches and releases on exit.
$dir=Join-Path $root 'state\network-diagnostics'
New-Item $dir -ItemType Directory -Force|Out-Null
try{$lock=[IO.File]::Open((Join-Path $dir 'observer.lock'),'OpenOrCreate','ReadWrite','None')}catch{
 "$(Get-Date -Format o) observer already running (lock held): $($_.Exception.Message)"|Add-Content (Join-Path $dir 'observer.log') -Encoding UTF8
 return
}
$trace=$null
try {
 try{$trace=New-RebootTrace $root 'network-diagnostics'}catch{}
 $lastProbe=[datetime]::MinValue
 $previousSelection=''
 $previousHelperState=''
 $bootReported=$false
 $groups=@('DISPATCH','WAN-ACTIVE','AUTO','CHATGPT','GOOGLE','GMAIL','DEV','ANTHROPIC','LINGODA','ZOOM','TOS','TWS','FUTU-DIRECT','TOKYO-POOL','LA-POOL')
 do {
  $timer=[Diagnostics.Stopwatch]::StartNew()
  try {
   $sample=[ordered]@{Time=(Get-Date -Format o);ControllerError=$null;Nodes=@();Routes=@();Errors=@()}
   # --- Fail-safe fallback: if logon startup could not write its report, write one from here. ---
   if(-not $bootReported){
    $bootReported=$true
    try{
     $boot=([datetime](Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToString('yyyyMMdd-HHmmss')
     if(-not (Test-Path (Join-Path $root "state\reboot-tests\$boot\boot-report.json"))){
      & "$PSScriptRoot\Write-BootReport.ps1" -OutputDirectory (Join-Path $root "state\reboot-tests\$boot") | Out-Null
      Write-RebootTrace $trace 'boot-report-fallback' @{Boot=$boot;Reason='missing at observer start'}
     }
    }catch{Write-RebootTrace $trace 'boot-report-fallback-error' @{Error=$_.Exception.Message}}
   }
   try {
    $nodes=(Invoke-RestMethod 'http://127.0.0.1:9097/proxies' -TimeoutSec 4).proxies
    $names=@($groups)+@('aliyun-tokyo','aliyun-la')+@($nodes.PSObject.Properties.Name|Where-Object {$_ -match '^(BALANCED-|LA-|WAN-|ADAPTIVE-PATH-)'})
    # Follow selected members so a group can be traced to its actual egress node.
    for($depth=0;$depth -lt 8;$depth++){
     $extra=@($names|ForEach-Object {$nodes.$_.now}|Where-Object {$_ -and $_ -notin $names}|Select-Object -Unique)
     if(-not $extra.Count){break};$names+=$extra
    }
    foreach($name in ($names|Sort-Object -Unique)){
     $node=$nodes.$name
     if(-not $node){continue}
     $last=@($node.history)|Select-Object -Last 1
     $sample.Nodes+= [ordered]@{Name=$name;Type=$node.type;Selected=$node.now;Alive=$node.alive;ProbeTime=$last.time;DelayMs=$last.delay}
    }
    $selection=ConvertTo-Json -InputObject @($sample.Nodes|Where-Object {$_.Selected}|ForEach-Object {"$($_.Name)=$($_.Selected)"}) -Compress
    if($selection -ne $previousSelection){Write-RebootTrace $trace 'selection-change' @{Before=$previousSelection;After=$selection};$previousSelection=$selection}
   }catch{$sample.ControllerError=$_.Exception.Message}
   # --- Local plumbing: routing, proxy registry, config identity. ---
   try {
    $interfaces=Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop
    $sample.Routes=@(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop|ForEach-Object {
     $route=$_;$iface=$interfaces|Where-Object InterfaceIndex -eq $route.InterfaceIndex|Select-Object -First 1
     [ordered]@{Interface=$route.InterfaceAlias;Index=$route.InterfaceIndex;NextHop=$route.NextHop;RouteMetric=$route.RouteMetric;InterfaceMetric=$iface.InterfaceMetric;State=[string]$iface.ConnectionState}
    })
    $proxy=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    $sample.SystemProxy=@{Enabled=$proxy.ProxyEnable;Server=$proxy.ProxyServer}
    $sample.ConfigHash=(Get-FileHash "$root\runtime\config.yaml" -Algorithm SHA256).Hash
   }catch{$sample.Errors+= $_.Exception.Message}
   # --- Processes and listeners: proves which component is actually running. ---
   try {
    $procs=@(Get-CimInstance Win32_Process -Filter "Name='mihomo.exe' OR Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction Stop)
    $mihomo=@($procs|Where-Object Name -eq 'mihomo.exe')
    $helper=@($procs|Where-Object {$_.CommandLine -and $_.CommandLine -like '*-File*' -and $_.CommandLine -like '*mihomo\*'})
    $sample.Processes=[ordered]@{
     Mihomo=@($mihomo|ForEach-Object {$_.ProcessId})
     Supervisor=@($procs|Where-Object {$_.CommandLine -like '*mihomo-supervisor.ps1*'}|ForEach-Object {$_.ProcessId})
     PacServer=@($procs|Where-Object {$_.CommandLine -like '*Serve-Pac.ps1*'}|ForEach-Object {$_.ProcessId})
     Observer=@($procs|Where-Object {$_.CommandLine -like '*-File*' -and $_.CommandLine -like '*Watch-NetworkDiagnostics.ps1*'}|ForEach-Object {$_.ProcessId})
    }
    if($mihomo.Count){try{$m=Get-Process -Id $mihomo[0].ProcessId -ErrorAction Stop;$sample.Processes.MihomoWorkingSetMB=[int]($m.WorkingSet64/1MB);$sample.Processes.MihomoCpuSeconds=[int]$m.CPU}catch{}}
    $sample.Listeners=@(Get-NetTCPConnection -State Listen -LocalPort 7897,9097,8080 -ErrorAction Stop|ForEach-Object {
     [ordered]@{Port=$_.LocalPort;Address=$_.LocalAddress;Pid=$_.OwningProcess}
    })
   }catch{$sample.Errors+= "processes: $($_.Exception.Message)"}
   # --- PAC server and hotspot: both are separate from the proxy and fail independently. ---
   try {
    $pacState=[ordered]@{Listening=@($sample.Listeners|Where-Object Port -eq 8080).Count -gt 0;Status=$null;Error=$null;Ms=$null}
    if($pacState.Listening){
     $sw=[Diagnostics.Stopwatch]::StartNew()
     try{$pacState.Status=(Invoke-WebRequest 'http://127.0.0.1:8080/proxy.pac' -UseBasicParsing -TimeoutSec 3).StatusCode}
     catch{$pacState.Error=$_.Exception.Message}
     finally{$sw.Stop();$pacState.Ms=$sw.ElapsedMilliseconds}
    }
    $sample.Pac=$pacState
   }catch{$sample.Errors+= "pac: $($_.Exception.Message)"}
   try {
    $hotspot=[ordered]@{Ics=@{};Address=$null;Task=$null}
    try{$hotspot.Ics=@{Services=@(Get-Service SharedAccess,icssvc -ErrorAction SilentlyContinue|ForEach-Object {"$($_.Name)=$($_.Status)"})}}catch{}
    try{$hotspot.Address=@(Get-NetIPAddress -AddressFamily IPv4 -IPAddress '192.168.137.1' -ErrorAction SilentlyContinue|ForEach-Object {$_.InterfaceAlias})}catch{}
    try{$task=Get-ScheduledTask -TaskName MihomoHotspot -ErrorAction Stop;$hotspot.Task=[string]$task.State}catch{$hotspot.Task='missing'}
    $sample.Hotspot=$hotspot
   }catch{$sample.Errors+= "hotspot: $($_.Exception.Message)"}
   # --- Managed adapters: link state is not reachability, but a Down link explains traffic loss. ---
   try {
    $adapters=@(Get-NetAdapter -ErrorAction Stop)
    $sample.Adapters=@($adapters|Where-Object {$_.Name -in $managedAdapters}|ForEach-Object {
     $ip=@(Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue|ForEach-Object {$_.IPAddress})
     [ordered]@{Name=$_.Name;Status=[string]$_.Status;Mac=$_.MacAddress;Ipv4=$ip}
    })
   }catch{$sample.Errors+= "adapters: $($_.Exception.Message)"}
   # --- Name resolution: a resolver failure breaks applications before any proxy rule matches. ---
   try {
    $sample.Dns=@()
    foreach($name in 'www.baidu.com','api.openai.com'){
     $sw=[Diagnostics.Stopwatch]::StartNew()
     $row=[ordered]@{Name=$name;Ok=$false;Count=0;Ms=$null;Error=$null}
     try{
      $answers=@(Resolve-DnsName $name -Type A -DnsOnly -QuickTimeout -ErrorAction Stop)
      $row.Count=$answers.Count;$row.Ok=$answers.Count -gt 0
     }catch{$row.Error=$_.Exception.Message}
     finally{$sw.Stop();$row.Ms=$sw.ElapsedMilliseconds}
     $sample.Dns+=$row
    }
   }catch{$sample.Errors+= "dns: $($_.Exception.Message)"}
   $sample.CollectionMs=$timer.ElapsedMilliseconds
   Write-RebootTrace $trace 'network-sample' $sample
   $helperState='m={0} s={1} pac={2} obs={3}' -f $sample.Processes.Mihomo.Count,$sample.Processes.Supervisor.Count,$sample.Processes.PacServer.Count,$sample.Processes.Observer.Count
   if($helperState -ne $previousHelperState){
    Write-RebootTrace $trace 'helper-process-change' @{Before=$previousHelperState;After=$helperState;Listeners=@($sample.Listeners|ForEach-Object {$_.Port})}
    $previousHelperState=$helperState
   }
   $sample|ConvertTo-Json -Depth 6|Set-Content (Join-Path $dir 'latest.json') -Encoding UTF8
   # Compact human summary: fastest way to read the newest state without parsing JSON.
   try{
    $summary=@(
     ('{0} mihomo={1} supervisor={2} pac={3} observer={4} proxies={5} controller={6}' -f $sample.Time,$sample.Processes.Mihomo.Count,$sample.Processes.Supervisor.Count,$sample.Processes.PacServer.Count,$sample.Processes.Observer.Count,@($sample.Nodes).Count,$(if($sample.ControllerError){'ERROR'}else{'ok'})),
     ('proxy={0} server={1} pac={2} hotspot={3}' -f $sample.SystemProxy.Enabled,$sample.SystemProxy.Server,$sample.Pac.Status,$sample.Hotspot.Task),
     ('routes={0}' -f (@($sample.Routes|ForEach-Object {"$($_.Interface)(metric $($_.InterfaceMetric)/$($_.RouteMetric),$($_.State))"}) -join ' ')),
     ('adapters={0}' -f (@($sample.Adapters|ForEach-Object {"$($_.Name)=$($_.Status)[$($_.Ipv4 -join ',')]"}) -join ' ')),
     ('dns={0}' -f (@($sample.Dns|ForEach-Object {"$($_.Name)=$(if($_.Ok){'ok'}else{'FAIL'})/$($_.Ms)ms"}) -join ' '))
    )
    if($sample.Errors.Count){$summary+=('errors='+($sample.Errors -join ' | '))}
    Set-Content (Join-Path $dir 'latest.txt') -Value ($summary -join [Environment]::NewLine) -Encoding UTF8
   }catch{}
   if(((Get-Date)-$lastProbe).TotalSeconds -ge $ProbeIntervalSeconds){
    # Real HTTP transport through the application's proxy, not just controller "alive".
    $probeResults=@()
    foreach($target in @(
     @{Name='google';Url='https://www.gstatic.com/generate_204'},
     @{Name='openai';Url='https://api.openai.com/v1/models'},
     @{Name='gmail';Url='https://mail.google.com/'},
     @{Name='domestic';Url='https://www.baidu.com/'}
    )){
     try {
      $out=Join-Path $dir 'curl.stdout'
      $err=Join-Path $dir 'curl.stderr'
      $arguments='--silent --show-error --output NUL --noproxy localhost --proxy http://127.0.0.1:7897 --connect-timeout 4 --max-time 8 --write-out "%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}" '+$target.Url
      $process=Start-Process "$env:WINDIR\System32\curl.exe" -WindowStyle Hidden -PassThru -ArgumentList $arguments -RedirectStandardOutput $out -RedirectStandardError $err
      $null=$process.Handle
      $timedOut=-not $process.WaitForExit(12000)
      if($timedOut){$process.Kill();$process.WaitForExit()}
      $result=(Get-Content $out -Raw -ErrorAction SilentlyContinue)
      $detail=(Get-Content $err -Raw -ErrorAction SilentlyContinue)
      Write-RebootTrace $trace 'http-probe' @{Target=$target.Name;CurlExit=$process.ExitCode;TimedOut=$timedOut;HttpAndSeconds=($result -join '');Error=($detail -join '');Fields='http_code dns connect tls first_byte total';Proxy='127.0.0.1:7897'}
      $probeResults+=[ordered]@{Target=$target.Name;Exit=$process.ExitCode;TimedOut=$timedOut;Result=($result -join '').Trim();Error=($detail -join '').Trim()}
      $process.Dispose()
     }catch{Write-RebootTrace $trace 'http-probe' @{Target=$target.Name;Error=$_.Exception.Message;Line=$_.InvocationInfo.ScriptLineNumber};$probeResults+=[ordered]@{Target=$target.Name;Error=$_.Exception.Message}}
    }
    # Verdict: reachability that fails on every target is the actionable signal; 401/403 are reachable.
    $reachable=@($probeResults|Where-Object {$_.Exit -eq 0 -and -not $_.TimedOut}).Count
    $verdict=if($reachable -eq 0){'unhealthy'}elseif($reachable -lt @($probeResults).Count){'degraded'}else{'healthy'}
    Write-RebootTrace $trace 'http-probe-summary' @{Verdict=$verdict;Reachable=$reachable;Total=@($probeResults).Count;Probes=$probeResults}
    try{Set-Content (Join-Path $dir 'latest-probes.txt') -Value (@(('{0} verdict={1} reachable={2}/{3}' -f (Get-Date -Format o),$verdict,$reachable,@($probeResults).Count))+@($probeResults|ForEach-Object {"$($_.Target): $(if($_.HttpAndSeconds){$_.HttpAndSeconds}else{"exit=$($_.Exit) $($_.Error)"})"})) -Encoding UTF8}catch{}
    $lastProbe=Get-Date
   }
   if(-not $Once){Start-Sleep -Seconds $IntervalSeconds}
  } catch {
   # Never let one failed probe or WMI hiccup kill the observer.
   try{Write-RebootTrace $trace 'loop-error' @{Message=$_.Exception.Message;Type=$_.Exception.GetType().Name;Line=$_.InvocationInfo.ScriptLineNumber;Script=$_.InvocationInfo.ScriptName}}catch{}
   try{"$(Get-Date -Format o) loop error: $($_.Exception.Message) line=$($_.InvocationInfo.ScriptLineNumber)"|Add-Content (Join-Path $dir 'observer.log') -Encoding UTF8}catch{}
   if(-not $Once){Start-Sleep -Seconds 15}
  }
 }while(-not $Once)
}finally{
 try{if($trace){Write-RebootTrace $trace 'observer-exit' @{Pid=$PID;Once=[bool]$Once}}}catch{}
 try{$lock.Dispose()}catch{}
}
