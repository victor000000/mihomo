BeforeAll {
 $root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
 . "$root\tools\Test-NetworkHealth.ps1" -FunctionsOnly
}
Describe 'Verified recovery health baseline' {
 BeforeEach {
  $config=Join-Path $TestDrive 'config.yaml'
  'mode: rule'|Set-Content $config
  $marker=Join-Path $TestDrive 'verified.json'
  $now=[datetime]::UtcNow
  $proof=@{VerifiedAtUtc=$now.AddMinutes(-1).ToString('o');ConfigSha256=(Get-FileHash $config).Hash;EgressPassed=$true;CodexConnected=$true;HotspotSharing=$true}
 }
 It 'accepts a proven recovery for the current configuration' {
  $proof|ConvertTo-Json|Set-Content $marker
  Get-VerifiedRecoveryTime $marker $config $now | Should -Not -BeNullOrEmpty
 }
 It 'preserves the exact UTC instant across JSON date handling' {
  $expected=[datetimeoffset]::Parse('2024-01-02T03:04:05.1234567+08:00').UtcDateTime
  $proof.VerifiedAtUtc='2024-01-02T03:04:05.1234567+08:00'
  $proof|ConvertTo-Json|Set-Content $marker
  $actual=Get-VerifiedRecoveryTime $marker $config $now
  $actual.Ticks | Should -Be $expected.Ticks
  $actual.Kind | Should -Be 'Utc'
 }
 It 'rejects a stale configuration hash' {
  $proof.ConfigSha256='different';$proof|ConvertTo-Json|Set-Content $marker
  Get-VerifiedRecoveryTime $marker $config $now | Should -BeNullOrEmpty
 }
 It 'rejects future timestamps' {
  $proof.VerifiedAtUtc=$now.AddMinutes(1).ToString('o');$proof|ConvertTo-Json|Set-Content $marker
  Get-VerifiedRecoveryTime $marker $config $now | Should -BeNullOrEmpty
 }
 It 'normalizes offset timestamps before checking the future boundary' {
  $proof.VerifiedAtUtc=([datetimeoffset]$now.AddMinutes(1)).ToOffset([timespan]::FromHours(8)).ToString('o')
  $proof|ConvertTo-Json|Set-Content $marker
  Get-VerifiedRecoveryTime $marker $config $now | Should -BeNullOrEmpty
 }
 It 'requires successful live connectivity evidence' {
  $proof.CodexConnected=$false;$proof|ConvertTo-Json|Set-Content $marker
  Get-VerifiedRecoveryTime $marker $config $now | Should -BeNullOrEmpty
 }
 It 'counts new errors while retaining the earlier log entries' {
  $log=Join-Path $TestDrive 'network.log'
  @((('time="{0}" level=warning old') -f $now.AddMinutes(-2).ToString('o')),
    (('time="{0}" level=warning new') -f $now.AddSeconds(-30).ToString('o')))|Set-Content $log
  Get-CountInWindow $log 15 'level=warning' | Should -Be 2
  Get-CountInWindow $log 15 'level=warning' -SinceUtc $now.AddSeconds(-90) | Should -Be 1
  @(Get-Content $log).Count | Should -Be 2
 }
}
