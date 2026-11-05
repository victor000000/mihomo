param([Parameter(Mandatory)][string]$BackupConfig,[Parameter(Mandatory)][string]$ExpectedHash,[Parameter(Mandatory)][string]$CommitFile,[int]$TimeoutSec=90)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$live=Join-Path $root 'runtime\config.yaml'
$log="$CommitFile.guard.log"
for($i=0;$i -lt $TimeoutSec;$i++) {
 if(Test-Path -LiteralPath $CommitFile){'Activation committed; rollback disarmed' | Set-Content $log;exit 0}
 Start-Sleep -Seconds 1
}
if((Get-FileHash $live -Algorithm SHA256).Hash -ne $ExpectedHash){'Config changed outside this activation; refusing to overwrite it' | Set-Content $log;exit 1}
Copy-Item -LiteralPath $BackupConfig -Destination $live -Force
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:9097/configs' -ContentType 'application/json' -Body (@{path=$live}|ConvertTo-Json) | Out-Null
if(Test-Path "$BackupConfig.selections.json"){
 $selections=Get-Content "$BackupConfig.selections.json" -Raw -Encoding UTF8 | ConvertFrom-Json
 foreach($property in $selections.PSObject.Properties){
  try{Invoke-RestMethod -Method Put -Uri ("http://127.0.0.1:9097/proxies/"+[uri]::EscapeDataString($property.Name)) -ContentType 'application/json' -Body (@{name=$property.Value}|ConvertTo-Json)|Out-Null}catch{}
 }
}
'Rollback restored previous Mihomo configuration and selections; HypoMux remains closed'  | Set-Content $log
