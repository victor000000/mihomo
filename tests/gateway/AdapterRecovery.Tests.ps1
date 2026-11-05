BeforeAll {
 $script:Root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}
Describe 'Per-adapter gateway recovery' {
 BeforeEach {
  $script:fixture=Join-Path $TestDrive 'repo'
  New-Item "$fixture\tools","$fixture\config" -ItemType Directory -Force|Out-Null
  (Get-Content "$Root\tools\Repair-MihomoAdapters.ps1" -Raw).Replace('Global\MihomoAdapterRepair','Local\MihomoRecoveryTest') | Set-Content "$fixture\tools\Repair-MihomoAdapters.ps1"
  '[{"name":"jd_5G","mac":"02-00-00-00-00-01","vmnet":12}]'|Set-Content "$fixture\config\mihomo-adapters.json"
  $global:recoveryTestChanges=[Collections.Generic.List[string]]::new()
  $global:recoveryTestNics=@([pscustomobject]@{Name='jd_5G';MacAddress='02-00-00-00-00-01';InterfaceGuid='bb913287-8698-4825-9371-7c3b14d714d5';Status='Up'})
  $global:recoveryTestMapping=12
  function Get-NetAdapter { $global:recoveryTestNics }
  function Get-NetAdapterBinding { param($Name,$ComponentID) [pscustomobject]@{Enabled=$true} }
  function Rename-NetAdapter { param($InputObject,$NewName) $global:recoveryTestChanges.Add("rename:$NewName") }
  function Disable-NetAdapterBinding { param($Name,$ComponentID) $global:recoveryTestChanges.Add("disable:$Name") }
  function Enable-NetAdapterBinding { param($Name,$ComponentID) $global:recoveryTestChanges.Add("enable:$Name") }
  function Restart-Service { throw 'Shared bridge restart forbidden' }
  Mock Get-ChildItem { @() } -ParameterFilter { $Path -like 'HKLM:*' }
  Mock Get-ItemProperty { [pscustomobject]@{VMnet=$global:recoveryTestMapping} } -ParameterFilter { $Path -like 'HKLM:*' }
  Mock Test-Path { $true } -ParameterFilter { $Path -like 'HKLM:*' }
  Mock Join-Path { "$Path\$ChildPath" } -ParameterFilter { $Path -like 'HKLM:*' }
  Mock New-ItemProperty { $global:recoveryTestChanges.Add('map') } -ParameterFilter { $Path -like 'HKLM:*' }
 }
 It 'does nothing to an already healthy mapping' {
  & "$fixture\tools\Repair-MihomoAdapters.ps1"
  $global:recoveryTestChanges.Count | Should -Be 0
 }
 It 'repairs a replacement identity and refreshes only that adapter' {
  $global:recoveryTestNics[0].Name='Ethernet 4';$global:recoveryTestMapping=$null
  & "$fixture\tools\Repair-MihomoAdapters.ps1"
  ($global:recoveryTestChanges -join ',') | Should -Be 'rename:jd_5G'
 }
 It 'keeps native recovery working when VMware is retired' {
  '{"mode":"gateway","ordinaryTransport":"windows-direct","omrRole":"retired"}' | Set-Content "$fixture\config\network-architecture.json"
  $global:recoveryTestNics[0].Name='Ethernet 4'
  function Get-NetAdapterBinding { throw 'VMware must not be accessed after retirement' }
  & "$fixture\tools\Repair-MihomoAdapters.ps1"
  ($global:recoveryTestChanges -join ',') | Should -Be 'rename:jd_5G'
 }
 It 'recognizes a changed MAC using the recorded interface identity' {
  '[{"name":"jd_5G","mac":"old-mac","interfaceGuid":"{bb913287-8698-4825-9371-7c3b14d714d5}"}]'|Set-Content "$fixture\config\mihomo-adapters.json"
  $global:recoveryTestNics[0].Name='Ethernet 4'
  & "$fixture\tools\Repair-MihomoAdapters.ps1"
  ($global:recoveryTestChanges -join ',') | Should -Be 'rename:jd_5G'
 }
 It 'refuses conflicting device identity matches' {
  '[{"name":"jd_5G","mac":"02-00-00-00-00-01","interfaceGuid":"different-guid"}]'|Set-Content "$fixture\config\mihomo-adapters.json"
  $global:recoveryTestNics+= [pscustomobject]@{Name='Other';MacAddress='other';InterfaceGuid='different-guid';Status='Up'}
  $report=& "$fixture\tools\Repair-MihomoAdapters.ps1"
  $report | Should -Match 'absent or ambiguous'
  $global:recoveryTestChanges.Count | Should -Be 0
 }
 It 'leaves missing devices alone' {
  $global:recoveryTestNics=@()
  & "$fixture\tools\Repair-MihomoAdapters.ps1"
  $global:recoveryTestChanges.Count | Should -Be 0
 }
}

AfterAll { Remove-Variable recoveryTestChanges,recoveryTestNics,recoveryTestMapping -Scope Global -ErrorAction SilentlyContinue }
