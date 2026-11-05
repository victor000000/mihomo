# Best-effort, per-process JSONL diagnostics. Never block networking on a log failure.
function New-RebootTrace {
 [CmdletBinding()]param([string]$RepositoryRoot,[string]$Component)
 try{
  $boot=(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
  $id=$boot.ToString('yyyyMMdd-HHmmss')
  $dir=Join-Path $RepositoryRoot "state\reboot-tests\$id"
  New-Item $dir -ItemType Directory -Force -ErrorAction Stop|Out-Null
  $path=Join-Path $dir ("$Component-$PID-"+(Get-Date -Format 'HHmmssfff')+'.jsonl')
  Write-RebootTrace $path 'process-start' @{Component=$Component;Pid=$PID;Boot=$boot.ToString('o');UptimeSeconds=[int]((Get-Date)-$boot).TotalSeconds;User=[Security.Principal.WindowsIdentity]::GetCurrent().Name;PowerShell=$PSVersionTable.PSVersion.ToString()}
  return $path
 }catch{return $null}
}
function Write-RebootTrace {
 [CmdletBinding()]param([AllowNull()][string]$Path,[string]$Event,[object]$Data)
 if(-not $Path){return}
 try{
  if((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -ge 4194304){Move-Item -LiteralPath $Path -Destination "$Path.previous" -Force}
  $record=[ordered]@{Time=(Get-Date -Format o);Event=$Event;Data=$Data}
  $line=ConvertTo-Json -InputObject $record -Depth 8 -Compress
  [IO.File]::AppendAllText($Path,$line+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
 }catch{} # Logging must not cause a network outage.
}
Export-ModuleMember -Function New-RebootTrace,Write-RebootTrace
