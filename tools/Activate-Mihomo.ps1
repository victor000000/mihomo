param([Parameter(Mandatory)][string]$Candidate,[switch]$PreferWindowsDirect)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.Encoding]::UTF8
$root=Split-Path -Parent $PSScriptRoot
$live=Join-Path $root 'runtime\config.yaml'
$dir=Join-Path $root 'state\jd-handoff'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$id=(Get-Date -Format yyyyMMdd-HHmmss-fff)+'-'+$PID
$backup=Join-Path $dir "before-handoff-$id.yaml"
$commit=Join-Path $dir "handoff-$id.committed"
function Probe([string]$Url) {
 $r=[Net.HttpWebRequest]::Create($Url);$r.Proxy=[Net.WebProxy]::new('http://127.0.0.1:7897');$r.Timeout=12000;$r.ReadWriteTimeout=12000
 try{$v=$r.GetResponse();$code=[int]$v.StatusCode;$v.Close();return $code}
 catch{if($_.Exception.InnerException.Response){return [int]$_.Exception.InnerException.Response.StatusCode};return 0}
}
$p=Start-Process "$root\runtime\mihomo.exe" -ArgumentList "-t -d `"$root\runtime`" -f `"$Candidate`"" -WindowStyle Hidden -PassThru -RedirectStandardOutput "$dir\production-validation.log" -RedirectStandardError "$dir\production-validation.err"
$null=$p.Handle;if(-not $p.WaitForExit(20000)){$p.Kill();throw 'Configuration validation timed out'}
if($p.ExitCode -ne 0){throw 'Configuration validation failed'}
$baseline=Probe 'https://api.openai.com/v1/models'
"Model API baseline HTTP $baseline"
$previousSelections=@{}
$all=Invoke-RestMethod 'http://127.0.0.1:9097/proxies' -TimeoutSec 5
foreach($property in $all.proxies.PSObject.Properties){if($property.Value.now){$previousSelections[$property.Name]=$property.Value.now}}
$previousSelections|ConvertTo-Json|Set-Content "$backup.selections.json" -Encoding UTF8
Copy-Item $live $backup
$hash=(Get-FileHash $Candidate -Algorithm SHA256).Hash
$guard=Join-Path $root 'tools\Mihomo-RollbackGuard.ps1'
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$guard`" -BackupConfig `"$backup`" -ExpectedHash $hash -CommitFile `"$commit`"" | Out-Null
try {
 Copy-Item $Candidate $live -Force
 Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:9097/configs' -ContentType 'application/json' -Body (@{path=$live}|ConvertTo-Json) | Out-Null
 Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:9097/proxies/LOCAL' -ContentType 'application/json' -Body '{"name":"DISPATCH"}' | Out-Null
 if($PreferWindowsDirect){
  $preferred=@{DISPATCH='WAN-win_turbo_phone';CHATGPT='aliyun-tokyo';ANTHROPIC='aliyun-tokyo';GOOGLE='aliyun-tokyo';YOUTUBE='aliyun-tokyo';IB='aliyun-tokyo';DEV='aliyun-tokyo';ZOOM='aliyun-tokyo';AUTO='TOKYO-POOL';LINGODA='aliyun-tokyo';PROXY='AUTO'}
  foreach($name in $preferred.Keys){
   $current=Invoke-RestMethod ("http://127.0.0.1:9097/proxies/"+$name) -TimeoutSec 3
   if($current.type -notin @('Selector','Fallback')){continue}
   $selection=$preferred[$name]
   if($name -in @('LINGODA','ZOOM') -and $current.all.Count -gt 0 -and $current.all[0] -like 'WAN-*'){$selection=$current.all[0]}
   Invoke-RestMethod -Method Put -Uri ("http://127.0.0.1:9097/proxies/"+$name) -ContentType 'application/json' -Body (@{name=$selection}|ConvertTo-Json) | Out-Null
  }
 }
 foreach($item in @(@('https://www.google.com/generate_204',204),@('https://class.lingoda.com/en/diagnostics',200))) {
  $code=Probe $item[0];"After handoff $($item[0]) HTTP $code"
  if($code -ne $item[1]){throw 'Connectivity acceptance failed'}
 }
 $code=Probe 'https://api.openai.com/v1/models';"Model API after handoff HTTP $code"
 if($code -eq 0 -or ($baseline -ne 0 -and $code -ne $baseline)){throw 'Model API connectivity changed'}
 'verified' | Set-Content $commit
 "HANDOFF_COMMITTED backup=$backup"
} catch {
 Copy-Item $backup $live -Force
 Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:9097/configs' -ContentType 'application/json' -Body (@{path=$live}|ConvertTo-Json) | Out-Null
 foreach($name in $previousSelections.Keys){
  try{Invoke-RestMethod -Method Put -Uri ("http://127.0.0.1:9097/proxies/"+[uri]::EscapeDataString($name)) -ContentType 'application/json' -Body (@{name=$previousSelections[$name]}|ConvertTo-Json)|Out-Null}catch{}
 }
 'rolled back' | Set-Content $commit
 throw
}
