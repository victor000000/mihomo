# Cloud-only routing for Codex's native WebSocket, which bypasses Windows proxy settings.
[CmdletBinding()]param([switch]$FunctionsOnly)
$ErrorActionPreference='Stop'
function New-CodexCloudTunnelConfig {
 param([Parameter(Mandatory)]$Policy,[Parameter(Mandatory)][string[]]$Addresses)
 $routes=@(foreach($address in $Addresses){
  $ip=$null
  if(-not [Net.IPAddress]::TryParse($address,[ref]$ip)){continue}
  $b=$ip.GetAddressBytes()
  if($b.Length -eq 4){
   if($b[0] -eq 0 -or $b[0] -eq 10 -or $b[0] -eq 127 -or $b[0] -ge 224 -or
      ($b[0] -eq 169 -and $b[1] -eq 254) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or
      ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
      ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127)){continue}
   "$ip/32"
  }elseif(($b[0] -band 224) -eq 32){"$ip/128"}
 })
 $routes=@($routes | Sort-Object -Unique)
 if(-not $routes.Count){throw 'No public cloud addresses; existing routes preserved'}
 return @{
  'mixed-port'=[int]$Policy.mixedPort;'allow-lan'=$false;'bind-address'='127.0.0.1'
  mode='rule';'log-level'='warning';ipv6=$true;'external-controller'="127.0.0.1:$($Policy.controllerPort)"
  tun=@{enable=$true;device=[string]$Policy.device;stack='system';'auto-route'=$true;'auto-detect-interface'=$false;
   'auto-redirect'=$false;'strict-route'=$false;'dns-hijack'=@();mtu=1500;'route-address'=@($routes)}
  proxies=@(@{name='Main-Mihomo-Codex';type='socks5';server='127.0.0.1';port=[int]$Policy.egressPort;udp=$false})
  'proxy-groups'=@();rules=@('MATCH,Main-Mihomo-Codex')
 }
}
if($FunctionsOnly){return}
$root=Split-Path $PSScriptRoot -Parent
$dir=Join-Path $root 'state\codex-cloud-tunnel'
New-Item -ItemType Directory $dir -Force|Out-Null
$mutex=[Threading.Mutex]::new($false,'Local\MihomoCodexCloudTunnel')
$held=$false;$core=$null;$configPath=Join-Path $dir 'config.json';$previous=''
function Write-CloudTunnelLog([string]$Message){
 $log=Join-Path $dir 'watch.log'
 if((Test-Path $log) -and (Get-Item $log).Length -gt 1048576){Move-Item $log "$log.previous" -Force}
 "$(Get-Date -Format o) $Message"|Add-Content $log -Encoding UTF8
}
try {
 try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
 if(-not $held){return}
 do {
  $policy=Get-Content "$root\config\codex-cloud-tunnel.json" -Raw|ConvertFrom-Json
  if(-not $policy.enabled){break}
  try {
   $addresses=@(foreach($type in 'A','AAAA'){
    $response=Invoke-RestMethod ("http://127.0.0.1:9097/dns/query?name="+[Uri]::EscapeDataString($policy.hostname)+"&type=$type") -TimeoutSec 5
    @($response.Answer|Where-Object {$_.type -in @(1,28)}|Select-Object -ExpandProperty data)
   })
   $config=New-CodexCloudTunnelConfig -Policy $policy -Addresses $addresses
   $json=$config|ConvertTo-Json -Depth 12
   $fingerprint=@($config.tun.'route-address') -join ','
   if(-not $core -or $core.HasExited){
    if($core){Write-CloudTunnelLog "Engine exited code=$($core.ExitCode)"}
    $json|Set-Content $configPath -Encoding UTF8
    foreach($file in 'engine.log','engine.err'){
     $path=Join-Path $dir $file
     if((Test-Path $path) -and (Get-Item $path).Length -gt 1048576){Move-Item $path "$path.previous" -Force}
    }
    $core=Start-Process "$root\runtime\mihomo.exe" -WindowStyle Hidden -PassThru -ArgumentList "-d `"$dir`" -f `"$configPath`"" -RedirectStandardOutput "$dir\engine.log" -RedirectStandardError "$dir\engine.err"
    $core.Id|Set-Content "$dir\engine.pid"
    Write-CloudTunnelLog "Started engine pid=$($core.Id) hostRoutes=$(@($config.tun.'route-address').Count)"
    $previous=$fingerprint
   }elseif($fingerprint -ne $previous){
    $json|Set-Content $configPath -Encoding UTF8
    Invoke-RestMethod -Method Put -Uri "http://127.0.0.1:$($policy.controllerPort)/configs" -ContentType 'application/json' -Body (@{path=$configPath}|ConvertTo-Json) -TimeoutSec 10|Out-Null
    $previous=$fingerprint;Write-CloudTunnelLog 'Refreshed cloud host routes'
   }
   @{Time=(Get-Date -Format o);State='running';Pid=$core.Id;HostRoutes=@($config.tun.'route-address');EgressPort=$policy.egressPort}|ConvertTo-Json -Depth 4|Set-Content "$dir\status.json" -Encoding UTF8
  }catch{
   # Keep an existing working tunnel on transient DNS/controller errors.
   Write-CloudTunnelLog ("Refresh deferred type="+$_.Exception.GetType().Name)
  }
  Start-Sleep -Seconds ([Math]::Max(10,[int]$policy.refreshSeconds))
 }while($true)
}finally{
 if($core -and -not $core.HasExited){Stop-Process -Id $core.Id -Force -ErrorAction SilentlyContinue}
 if($held){$mutex.ReleaseMutex()};$mutex.Dispose()
}
