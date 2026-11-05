# Logon launcher: keep the existing gateway config and start its proxy supervisor.
# Records enough context that a failed logon can be diagnosed from the transcript alone.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module "$root\src\NetStack\RebootTrace.psm1" -Force
$trace=New-RebootTrace $root 'proxy-startup'
$runDir=Join-Path $root ("state\gateway-logon-runs\{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'),$PID)
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
Start-Transcript -Path "$runDir\transcript.log" -Force | Out-Null
try {
Import-Module "$root\src\NetStack\Architecture.psm1" -Force
if((Get-NetworkArchitecture -RepositoryRoot $root) -ne 'mihomo'){exit 0}
$supervisor=Join-Path $root 'runtime\mihomo-supervisor.ps1'
if(-not (Test-Path $supervisor)){throw 'Mihomo supervisor missing'}

# --- logon context: boot time, uptime, adapters, proxy registry, listeners ---------------
$context=[ordered]@{Boot= $null;UptimeSeconds=$null;Adapters=@();SystemProxy=$null;Listeners=@();ConfigHash=$null}
try{
 $bootT=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
 $context.Boot=$bootT.ToString('o')
 $context.UptimeSeconds=[int]((Get-Date)-$bootT).TotalSeconds
}catch{Write-RebootTrace $trace 'logon-context-error' @{Step='boot';Message=$_.Exception.Message}}
try{
 $context.Adapters=@(Get-NetAdapter -ErrorAction Stop|Where-Object {$_.Status -eq 'Up'}|Select-Object Name,MacAddress,LinkSpeed,ifIndex)
}catch{Write-RebootTrace $trace 'logon-context-error' @{Step='adapters';Message=$_.Exception.Message}}
try{
 $p=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
 $context.SystemProxy=[ordered]@{ProxyEnable=$p.ProxyEnable;ProxyServer=$p.ProxyServer}
}catch{Write-RebootTrace $trace 'logon-context-error' @{Step='proxy';Message=$_.Exception.Message}}
try{
 $context.Listeners=@(Get-NetTCPConnection -State Listen -LocalPort 7897,9097,8080 -ErrorAction Stop|ForEach-Object {"$($_.LocalPort)=$($_.OwningProcess)"})
}catch{Write-RebootTrace $trace 'logon-context-error' @{Step='listeners';Message=$_.Exception.Message}}
try{$context.ConfigHash=(Get-FileHash "$root\runtime\config.yaml").Hash}catch{Write-RebootTrace $trace 'logon-context-error' @{Step='config';Message=$_.Exception.Message}}
Write-RebootTrace $trace 'logon-context' $context
Write-Output ("{0} Logon context: boot={1} uptime={2}s proxy={3}/{4} listeners={5} adapters={6}" -f (Get-Date -Format o),$context.Boot,$context.UptimeSeconds,$context.SystemProxy.ProxyEnable,$context.SystemProxy.ProxyServer,($context.Listeners -join ','),(($context.Adapters|ForEach-Object {"$($_.Name)"}) -join ','))
if($context.SystemProxy.ProxyEnable -ne 1){
 Write-RebootTrace $trace 'system-proxy-disabled' @{ProxyEnable=$context.SystemProxy.ProxyEnable}
 Write-Output 'WARNING user system proxy is disabled; applications that rely on it will bypass Mihomo'
}

# --- single supervisor, started hidden and detached -------------------------------------
$existing=Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('pwsh.exe','powershell.exe') -and $_.CommandLine -like '*-File*' -and $_.CommandLine -like "*$supervisor*" }
Write-Output "$(Get-Date -Format o) Existing supervisor count=$(@($existing).Count); configSHA256=$($context.ConfigHash)"
Write-RebootTrace $trace 'supervisor-check' @{ExistingCount=@($existing).Count;ExistingPids=@($existing|ForEach-Object {$_.ProcessId});ConfigHash=$context.ConfigHash}
if(-not $existing){
 $pwsh='C:\Program Files\PowerShell\7\pwsh.exe'
 Start-Process "$env:WINDIR\System32\conhost.exe" -WindowStyle Hidden -ArgumentList "--headless `"$pwsh`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$supervisor`"" | Out-Null
 Write-RebootTrace $trace 'supervisor-dispatched' @{Path=$supervisor;PowerShell=$pwsh}
}
Add-Content "$root\state\gateway-startup.log" -Encoding UTF8 "$(Get-Date -Format s) Gateway supervisor ensured; current runtime config retained."

# --- controller readiness: bounded, logged, never fatal ---------------------------------
$ready=$false
$readyWait=[Diagnostics.Stopwatch]::StartNew()
$deadline=(Get-Date).AddSeconds(20)
while((Get-Date) -lt $deadline){
 try{Invoke-RestMethod 'http://127.0.0.1:9097/version' -TimeoutSec 2|Out-Null;$ready=$true;break}catch{Start-Sleep -Milliseconds 750}
}
$readyWait.Stop()
$readyAfterMs=[int]$readyWait.ElapsedMilliseconds
Write-Output "$(Get-Date -Format o) Controller ready=$ready waitedMs=$readyAfterMs"
Write-RebootTrace $trace 'controller-readiness' @{Ready=$ready;WaitedMs=$readyAfterMs;AttemptsDeadlineSeconds=20}

# --- PAC server: separate process, started at logon, needed by hotspot/phone clients ----
try{
 $pacListening=@(Get-NetTCPConnection -State Listen -LocalPort 8080 -ErrorAction SilentlyContinue).Count -gt 0
 if(-not $pacListening){
  Start-Process "$env:WINDIR\System32\conhost.exe" -WindowStyle Hidden -ArgumentList "--headless `"C:\Program Files\PowerShell\7\pwsh.exe`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$root\tools\Serve-Pac.ps1`"" | Out-Null
  Write-RebootTrace $trace 'pac-dispatched' @{Port=8080}
 }else{Write-RebootTrace $trace 'pac-already-listening' @{Port=8080}}
}catch{Write-RebootTrace $trace 'pac-dispatch-error' @{Message=$_.Exception.Message}}

# --- observers: bounded boot capture plus continuous diagnostics ------------------------
Start-Process "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -WindowStyle Hidden `
 -ArgumentList "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$root\tools\Watch-MihomoBoot.ps1`"" | Out-Null
# Diagnostic launch failure must not prevent network startup.
try {
 Start-Process 'C:\Program Files\PowerShell\7\pwsh.exe' -WindowStyle Hidden `
  -ArgumentList "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$root\tools\Watch-NetworkDiagnostics.ps1`"" | Out-Null
 Write-RebootTrace $trace 'diagnostics-dispatched' @{Script='Watch-NetworkDiagnostics.ps1'}
}catch{Write-RebootTrace $trace 'diagnostics-launch-error' @{Message=$_.Exception.Message}}

# --- post-logon boot report: delayed so it sees the started proxy, then a steady sample --
try {
 foreach($sample in @(@{Delay=45;Label='logon';Probe='-Probe'},@{Delay=300;Label='steady';Probe=''})){
  $arguments='--headless "C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -DelaySeconds {1} -Label {2} {3}' -f `
   (Join-Path $root 'tools\Write-BootReport.ps1'),$sample.Delay,$sample.Label,$sample.Probe
  Start-Process "$env:WINDIR\System32\conhost.exe" -WindowStyle Hidden -ArgumentList $arguments | Out-Null
 }
 Write-RebootTrace $trace 'boot-report-dispatched' @{Delays=@(45,300)}
}catch{Write-RebootTrace $trace 'boot-report-launch-error' @{Message=$_.Exception.Message}}

Write-RebootTrace $trace 'startup-dispatched' @{Observer='Watch-MihomoBoot.ps1';Supervisor='mihomo-supervisor.ps1';Diagnostics='Watch-NetworkDiagnostics.ps1';PacServer='Serve-Pac.ps1'}
Write-Output "$(Get-Date -Format o) Started bounded post-logon health capture"
} catch {
 Write-RebootTrace $trace 'startup-error' @{Message=$_.Exception.Message;Line=$_.InvocationInfo.ScriptLineNumber}
 "$(Get-Date -Format o) ERROR $($_.Exception.Message) line=$($_.InvocationInfo.ScriptLineNumber)" |
  Add-Content "$runDir\error.log" -Encoding UTF8
 throw
} finally {
 Stop-Transcript | Out-Null
}
