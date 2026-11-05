BeforeAll {
 $root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
 Import-Module "$root\src\NetStack\RebootTrace.psm1" -Force
}
Describe 'Non-blocking structured reboot diagnostics' {
 It 'writes independently parseable timestamped events' {
  $p=Join-Path $TestDrive 'events.jsonl'
  Write-RebootTrace $p 'ready' @{Pid=123;Success=$true}
  Write-RebootTrace $p 'failed' @{Success=$false}
  $rows=@(Get-Content $p|ForEach-Object {$_|ConvertFrom-Json})
  $rows.Count|Should -Be 2
  $rows[0].Event|Should -Be 'ready'
  $rows[0].Data.Pid|Should -Be 123
  $rows[1].Data.Success|Should -BeFalse
  # Newer PowerShell parses ISO JSON timestamps into DateTime values.
  ([datetime]$rows[0].Time).Year|Should -Be (Get-Date).Year
 }
 It 'does not break networking if log output is unavailable' {
  {Write-RebootTrace (Join-Path $TestDrive 'missing\events.jsonl') 'probe' @{}}|Should -Not -Throw
  {Write-RebootTrace $null 'probe' @{}}|Should -Not -Throw
 }
 It 'rotates a large process log before appending' {
  $p=Join-Path $TestDrive 'large.jsonl'
  [IO.File]::WriteAllText($p,('x'*4194304))
  Write-RebootTrace $p 'rotated' @{}
  Test-Path "$p.previous"|Should -BeTrue
  (Get-Content $p -Raw|ConvertFrom-Json).Event|Should -Be 'rotated'
 }
}
