$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module "$root\src\NetStack\RebootTrace.psm1" -Force
$trace=New-RebootTrace $root 'hotspot-startup'
$dir=Join-Path $root ("state\gateway-hotspot-runs\{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'),$PID)
New-Item -ItemType Directory $dir -Force | Out-Null
Start-Transcript "$dir\transcript.log" -Force | Out-Null
try {
 # Use a child process: Hotspot.ps1 uses exit codes for failed recovery.
 $p=Start-Process "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -ArgumentList "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$root\src\hotspot\Hotspot.ps1`" ensure" `
  -WindowStyle Hidden -PassThru -RedirectStandardOutput "$dir\stdout.log" -RedirectStandardError "$dir\stderr.log"
 Write-RebootTrace $trace 'hotspot-child-started' @{Pid=$p.Id}
 $null=$p.Handle
 if(-not $p.WaitForExit(180000)){
  $p.Kill()
  throw 'Hotspot recovery exceeded 180 seconds; child stopped so task retries remain possible'
 }
 [ordered]@{Time=(Get-Date -Format o);ExitCode=$p.ExitCode;Pid=$p.Id} |
  ConvertTo-Json | Set-Content "$dir\result.json" -Encoding UTF8
 Write-RebootTrace $trace 'hotspot-result' @{ExitCode=$p.ExitCode;Pid=$p.Id;DetailDirectory=$dir}
 exit $p.ExitCode
}catch{
 Write-RebootTrace $trace 'hotspot-error' @{Message=$_.Exception.Message;DetailDirectory=$dir}
 $_.Exception.Message | Set-Content "$dir\error.log" -Encoding UTF8
 exit 1
}finally{Stop-Transcript | Out-Null}
