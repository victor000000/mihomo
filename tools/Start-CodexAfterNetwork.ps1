# User-logon launcher. Wait for the configured proxy, without changing network state.
[CmdletBinding()]param([switch]$CheckOnly,[int]$Attempts=30)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$dir=Join-Path $root ("state\codex-startup\{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'),$PID)
New-Item -ItemType Directory $dir -Force | Out-Null
function Log($message){"$(Get-Date -Format o) $message" | Add-Content "$dir\events.log" -Encoding UTF8}
Log 'Waiting for HTTPS through Windows Mihomo proxy'
Import-Module "$root\src\NetStack\Architecture.psm1" -Force
$ready=$false
for($i=1;$i -le $Attempts;$i++){
 try {
  $p=Start-Process "$env:WINDIR\System32\curl.exe" -WindowStyle Hidden -PassThru `
   -ArgumentList '--silent --show-error --head --connect-timeout 3 --max-time 8 --proxy http://127.0.0.1:7897 --output NUL --write-out %{http_code} https://chatgpt.com/' `
   -RedirectStandardOutput "$dir\http-status.txt" -RedirectStandardError "$dir\curl-error.log"
  $null=$p.Handle
  if(-not $p.WaitForExit(12000)){$p.Kill();throw 'HTTPS probe exceeded deadline'}
  $status=(Get-Content "$dir\http-status.txt" -Raw).Trim()
  # Transport check only; authenticated app policy is checked by the app.
  # A 403 does not prove authenticated organization policy can be loaded.
  $ready=$p.ExitCode -eq 0 -and $status -match '^[234]\d\d$' -and $status -ne '407'
  Log "Attempt=$i curlExit=$($p.ExitCode) HTTP=$status ready=$ready"
  if($ready){break}
 }catch{Log "Attempt=$i error=$($_.Exception.Message)"}
 if($i -lt $Attempts){Start-Sleep -Seconds 5}
}
if($CheckOnly){if($ready){exit 0}else{exit 1}}
if(-not $ready){Log 'Network deadline reached; opening Codex so the user can inspect connectivity'}
if(Get-Process Codex -ErrorAction SilentlyContinue){Log 'Codex already running; no additional launch';exit 0}
Start-Process "$env:WINDIR\explorer.exe" -ArgumentList 'shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App'
Log 'Requested Codex launch'
