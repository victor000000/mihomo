# Bounded, read-only post-logon capture. No repair or routing changes.
param([int]$Samples=8,[int]$IntervalSeconds=30)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module "$root\src\NetStack\RebootTrace.psm1" -Force
$trace=New-RebootTrace $root 'boot-observer'
$dir=Join-Path $root ("state\gateway-observations\{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'),$PID)
New-Item -ItemType Directory $dir -Force | Out-Null
Import-Module "$root\src\NetStack\Architecture.psm1" -Force
$paths=@('DISPATCH','aliyun-tokyo','aliyun-la','LINGODA')
for($i=1;$i -le $Samples;$i++){
 try {
  & "$PSScriptRoot\Write-MihomoBootSnapshot.ps1" -OutputPath "$dir\snapshot-$i.json"
  Write-RebootTrace $trace 'snapshot-saved' @{Sample=$i;Path="$dir\snapshot-$i.json"}
  foreach($name in $paths){
   $url=if($name -eq 'DISPATCH'){'https://www.baidu.com/'}elseif($name -eq 'LINGODA'){'https://learn.lingoda.com/en/account/practice/vocabulary'}else{'https://www.google.com/generate_204'}
   try {
    $r=Invoke-RestMethod ("http://127.0.0.1:9097/proxies/$name/delay?timeout=5000&url="+[uri]::EscapeDataString($url)) -TimeoutSec 7
    Write-RebootTrace $trace 'proxy-probe' @{Sample=$i;Proxy=$name;Success=$true;DelayMs=$r.delay}
    "$(Get-Date -Format o) sample=$i proxy=$name delay=$($r.delay)ms" | Add-Content "$dir\health.log" -Encoding UTF8
   }catch{Write-RebootTrace $trace 'proxy-probe' @{Sample=$i;Proxy=$name;Success=$false;Error=$_.Exception.Message};"$(Get-Date -Format o) sample=$i proxy=$name error=$($_.Exception.Message)" | Add-Content "$dir\health.log" -Encoding UTF8}
  }
  $p=Start-Process "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -WindowStyle Hidden -PassThru `
   -ArgumentList "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$root\src\hotspot\Hotspot.ps1`" status" `
   -RedirectStandardOutput "$dir\hotspot-$i.log" -RedirectStandardError "$dir\hotspot-$i.err"
  $null=$p.Handle
  if(-not $p.WaitForExit(15000)){$p.Kill();Write-RebootTrace $trace 'hotspot-probe' @{Sample=$i;TimedOut=$true};"Hotspot status timed out, sample=$i" | Add-Content "$dir\errors.log" -Encoding UTF8}
  else{Write-RebootTrace $trace 'hotspot-probe' @{Sample=$i;ExitCode=$p.ExitCode;DetailPath="$dir\hotspot-$i.log"}}
  try{$pac=Invoke-WebRequest 'http://127.0.0.1:8080/proxy.pac' -UseBasicParsing -TimeoutSec 3;Write-RebootTrace $trace 'pac-probe' @{Sample=$i;Status=$pac.StatusCode}}
  catch{Write-RebootTrace $trace 'pac-probe' @{Sample=$i;Error=$_.Exception.Message}}
 }catch{Write-RebootTrace $trace 'sample-error' @{Sample=$i;Error=$_.Exception.Message};"$(Get-Date -Format o) sample=$i error=$($_.Exception.Message)" | Add-Content "$dir\errors.log" -Encoding UTF8}
 if($i -lt $Samples){Start-Sleep -Seconds $IntervalSeconds}
}

Write-RebootTrace $trace 'observation-complete' @{Samples=$Samples;DetailDirectory=$dir}
