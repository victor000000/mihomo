BeforeAll {
 $root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
 Import-Module "$root\src\NetStack\AdapterRecoveryHealth.psm1" -Force
}
Describe 'Conservative adapter stall recovery' {
 BeforeEach {
  $case=@{Healthy=$false;AlternativeHealthy=$true;Failures=4;FailureSeconds=100;SinceAttemptSeconds=1800;AttemptsLastHour=0;ActiveConnections=$false;HotspotPublic=$false;DirectReachable=$false}
 }
 It 'requires a sustained outage and a working alternative' {
  $case.FailureSeconds=60
  Get-AdapterRecoveryDecision @case|Should -Be 'waiting-for-persistent-failure'
  $case.FailureSeconds=100;$case.AlternativeHealthy=$false
  Get-AdapterRecoveryDecision @case|Should -Be 'no-working-alternative'
 }
 It 'preserves established sessions and the hotspot upstream' {
  $case.ActiveConnections=$true
  Get-AdapterRecoveryDecision @case|Should -Be 'preserving-active-connections'
  $case.ActiveConnections=$false;$case.HotspotPublic=$true
  Get-AdapterRecoveryDecision @case|Should -Be 'preserving-hotspot'
 }
 It 'does not reset a working adapter just because proxy servers fail' {
  $case.DirectReachable=$true
  Get-AdapterRecoveryDecision @case|Should -Be 'proxy-path-failure-only'
 }
 It 'rate limits attempts across watcher restarts' {
  $case.SinceAttemptSeconds=300
  Get-AdapterRecoveryDecision @case|Should -Be 'cooldown'
  $case.SinceAttemptSeconds=1800;$case.AttemptsLastHour=3
  Get-AdapterRecoveryDecision @case|Should -Be 'cooldown'
 }
 It 'permits a reset only after all safety conditions pass' {
  Get-AdapterRecoveryDecision @case|Should -Be 'restart-eligible'
  $case.Healthy=$true
  Get-AdapterRecoveryDecision @case|Should -Be 'healthy'
 }
}
Describe 'Shared adapter recovery roles' {
 It 'does not treat the reserved hotspot uplink as a broken proxy adapter' {
  $fixture=Join-Path $TestDrive 'shared-role'
  New-Item "$fixture\config","$fixture\state\adapter-recovery" -ItemType Directory -Force|Out-Null
  '[{"name":"shared-test","mac":"test-mac"}]'|Set-Content "$fixture\config\mihomo-adapters.json"
  Mock Get-NetAdapter { [pscustomobject]@{Name='shared-test';MacAddress='test-mac';ifIndex=99;Status='Up'} } -ModuleName AdapterRecoveryHealth
  Mock Restart-NetAdapter { throw 'A shared uplink must not be restarted' } -ModuleName AdapterRecoveryHealth
  Invoke-AdapterStallRecovery -RepositoryRoot $fixture -Health @(@{Adapter='shared-test';ProxyReachable=$false;ProxyRequired=$false})
  $state=Get-Content "$fixture\state\adapter-recovery\stall-state.json" -Raw|ConvertFrom-Json
  $state.'shared-test'.Decision|Should -Be 'reserved-for-hotspot'
  $state.'shared-test'.Failures|Should -Be 0
  Should -Invoke Restart-NetAdapter -ModuleName AdapterRecoveryHealth -Times 0 -Exactly
 }
}
