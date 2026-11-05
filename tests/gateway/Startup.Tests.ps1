BeforeAll {
 $script:Root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
 Import-Module "$Root\src\NetStack\Architecture.psm1" -Force
}
Describe 'Mihomo-only startup policy' {
 It 'accepts the sole design and rejects old VM mode' {
  New-Item "$TestDrive\config" -ItemType Directory -Force|Out-Null
  '{"mode":"mihomo"}'|Set-Content "$TestDrive\config\network-architecture.json"
  Get-NetworkArchitecture $TestDrive|Should -Be 'mihomo'
  Get-OrdinaryTransport $TestDrive|Should -Be 'windows-direct'
  '{"mode":"gateway"}'|Set-Content "$TestDrive\config\network-architecture.json"
  {Get-NetworkArchitecture $TestDrive}|Should -Throw '*Invalid network architecture*'
 }
 It 'registers only native startup responsibilities' {
  $s=Get-Content "$Root\tools\Register-MihomoStartup.ps1" -Raw
  $s|Should -Match 'Register-MihomoAdapterRecovery'
  $s|Should -Match 'Register-MihomoHotspot'
  $s|Should -Not -Match 'Start.*Vm|Register.*Boot|HypoMux'
 }
 It 'keeps PAC outside removed VM files' {
  $s=Get-Content "$Root\tools\Serve-Pac.ps1" -Raw
  $s|Should -Not -Match 'OpenMPTCProuter_test'
  Test-Path "$Root\tools\Serve-Pac.ps1"|Should -BeTrue
 }
}
