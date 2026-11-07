BeforeAll {
 $script:Root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
 Import-Module "$Root\src\NetStack\AdapterRouteGuard.psm1" -Force
}
Describe 'Default route stability decisions' {
 BeforeEach {
  $script:now=[datetime]'2026-10-30T00:00:00Z'
  $script:snapshot=[pscustomobject]@{InspectionSucceeded=$true;Fingerprint='same';ActiveConnections=$false;HotspotPublic=$false}
 }
 It 'defers the first observation' {
  (Get-AdapterRouteGuardDecision $snapshot $null $now).Allowed | Should -BeFalse
 }
 It 'allows only a continuously observed stable idle interval' {
  $prior=$null
  foreach($second in 0,30,60,90,120){$d=Get-AdapterRouteGuardDecision $snapshot $prior ($now.AddSeconds($second));$prior=$d.State}
  $d.Allowed | Should -BeTrue
 }
 It 'does not consider a gap in observations stable' {
  $prior=(Get-AdapterRouteGuardDecision $snapshot $null $now).State
  (Get-AdapterRouteGuardDecision $snapshot $prior ($now.AddSeconds(121))).Reason | Should -Be 'waiting-for-stable-idle-inventory'
 }
 It 'restarts the quiet period on disappearance or route changes' {
  $prior=[pscustomobject]@{Fingerprint='different';StableSinceUtc=$now.AddMinutes(-10).ToString('o');LastObservedUtc=$now.AddSeconds(-10).ToString('o');Observations=50}
  (Get-AdapterRouteGuardDecision $snapshot $prior $now).Allowed | Should -BeFalse
 }
 It 'preserves active transfers even after a stable interval' {
  $snapshot.ActiveConnections=$true
  $prior=[pscustomobject]@{Fingerprint='same';StableSinceUtc=$now.AddMinutes(-10).ToString('o');LastObservedUtc=$now.AddSeconds(-10).ToString('o');Observations=50}
  $d=Get-AdapterRouteGuardDecision $snapshot $prior $now
  $d.Reason | Should -Be 'preserving-active-connections'
  $d.State.StableSinceUtc | Should -Be $now.ToUniversalTime().ToString('o')
 }
 It 'preserves a shared hotspot even without a local transfer' {
  $snapshot.HotspotPublic=$true
  (Get-AdapterRouteGuardDecision $snapshot $null $now).Reason | Should -Be 'preserving-hotspot'
 }
 It 'fails closed when inspection fails' {
  $snapshot.InspectionSucceeded=$false
  (Get-AdapterRouteGuardDecision $snapshot $null $now).Reason | Should -Be 'inspection-unavailable'
 }
 It 'does not trust a backwards clock' {
  $prior=(Get-AdapterRouteGuardDecision $snapshot $null $now.AddSeconds(10)).State
  (Get-AdapterRouteGuardDecision $snapshot $prior $now).Allowed | Should -BeFalse
 }
 It 'fails closed on corrupted persisted state before native inspection' {
  $dir=Join-Path $TestDrive 'corrupt\state\adapter-recovery'
  New-Item $dir -ItemType Directory -Force|Out-Null
  '{broken'|Set-Content "$dir\route-guard.json"
  (Get-AdapterRouteMutationGuard -RepositoryRoot (Join-Path $TestDrive 'corrupt') -Adapters @() -Nics @()).Allowed | Should -BeFalse
 }
}

Describe 'Native state inspection remains conservative' {
 BeforeEach {
  Import-Module "$Root\src\NetStack\AdapterRouteGuard.psm1" -Force
  $script:map=@([pscustomobject]@{name='test';mac='test-mac'})
  $script:nics=@([pscustomobject]@{Name='test';MacAddress='test-mac';InterfaceGuid='test-guid';ifIndex=99;Status='Up'})
  Mock Get-NetIPAddress { [pscustomobject]@{IPAddress='192.0.2.2';AddressState='Preferred'} } -ModuleName AdapterRouteGuard
  Mock Get-NetIPInterface { [pscustomobject]@{AddressFamily='IPv4';InterfaceMetric=30;ConnectionState='Connected'} } -ModuleName AdapterRouteGuard
  Mock Get-NetRoute { [pscustomobject]@{DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.1';RouteMetric=30} } -ModuleName AdapterRouteGuard
  Mock Get-NetTCPConnection { @() } -ModuleName AdapterRouteGuard
  Mock Get-NetUDPEndpoint { @() } -ModuleName AdapterRouteGuard
  Mock New-Object { throw 'ICS inspection unavailable in test' } -ModuleName AdapterRouteGuard -ParameterFilter { $ComObject -eq 'HNetCfg.HNetShare' }
 }
 It 'protects native TCP transfers and needs no ICS query to defer' {
  Mock Get-NetTCPConnection { [pscustomobject]@{LocalAddress='192.0.2.2'} } -ModuleName AdapterRouteGuard
  (Get-AdapterRouteGuardSnapshot -Adapters $map -Nics $nics).ActiveConnections | Should -BeTrue
  Should -Invoke New-Object -ModuleName AdapterRouteGuard -Times 0 -Exactly
 }
 It 'protects wildcard UDP even when no TCP session is present' {
  Mock Get-NetUDPEndpoint { [pscustomobject]@{LocalAddress='0.0.0.0'} } -ModuleName AdapterRouteGuard
  (Get-AdapterRouteGuardSnapshot -Adapters $map -Nics $nics).ActiveConnections | Should -BeTrue
 }
 It 'refuses mutations when ICS cannot be inspected on an idle machine' {
  $d=Get-AdapterRouteMutationGuard -RepositoryRoot (Join-Path $TestDrive 'unavailable-ics') -Adapters $map -Nics $nics
  $d.Allowed | Should -BeFalse
  $d.Reason | Should -Be 'inspection-or-state-unavailable'
 }
}

Describe 'Route reconciliation obeys the guard without touching native networking' {
 BeforeEach {
  $script:fixture=Join-Path $TestDrive 'candidate'
  New-Item "$fixture\tools","$fixture\config","$fixture\src\NetStack" -ItemType Directory -Force|Out-Null
  $source="$Root\tools\Repair-MihomoAdapters.ps1"
  if($env:MIHOMO_ROUTE_GUARD_CANDIDATE){$source=$env:MIHOMO_ROUTE_GUARD_CANDIDATE}
  $text=(Get-Content $source -Raw).Replace('Global\MihomoAdapterRepair',('Local\MihomoRouteGuardTest-'+[guid]::NewGuid().ToString('N')))
  # Hermetic fixture exercises the privileged branch without elevation.
  $text=[regex]::Replace($text,'(?m)^\$canAdjustRoutes=.*$','$canAdjustRoutes=$true')
  $text|Set-Content "$fixture\tools\Repair-MihomoAdapters.ps1"
  'function Get-AdapterRouteMutationGuard { param($RepositoryRoot,$Adapters,$Nics) [pscustomobject]@{Allowed=$global:routeGuardTestAllowed;Reason="test-deferred"} }; Export-ModuleMember Get-AdapterRouteMutationGuard'|Set-Content "$fixture\src\NetStack\AdapterRouteGuard.psm1"
  '[{"name":"test-uplink","mac":"test-mac","routeMetric":30,"ipv4Address":"192.0.2.2","prefixLength":24,"gateway":"192.0.2.1"}]'|Set-Content "$fixture\config\mihomo-adapters.json"
  $global:routeGuardTestAllowed=$false
  $global:routeGuardTestChanges=[Collections.Generic.List[string]]::new()
  $global:routeGuardTestMissing=$false
  Mock Get-NetAdapter { [pscustomobject]@{Name='test-uplink';MacAddress='test-mac';InterfaceGuid='test-guid';ifIndex=99;Status='Up'} }
  Mock Get-NetIPAddress { [pscustomobject]@{IPAddress='192.0.2.2';AddressState='Preferred'} }
  Mock Get-NetRoute { if(-not $global:routeGuardTestMissing){New-CimInstance -ClassName MSFT_NetRoute -Namespace root/StandardCimv2 -ClientOnly -Property @{DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.1';RouteMetric=[uint32]0}} }
  Mock Set-NetRoute { $global:routeGuardTestChanges.Add('metric') }
  Mock Get-NetIPInterface { [pscustomobject]@{AddressFamily='IPv4';InterfaceMetric=99;AutomaticMetric='Enabled'} }
  Mock Set-NetIPInterface { $global:routeGuardTestChanges.Add('interface-metric') }
  Mock New-NetRoute { $global:routeGuardTestChanges.Add('create-route') }
  Mock New-NetIPAddress { throw 'Address mutation is not part of these tests' }
  Mock Rename-NetAdapter { throw 'Unexpected rename' }
 }
 It 'does not change a mismatched metric when deferred' {
  & "$fixture\tools\Repair-MihomoAdapters.ps1"
  $global:routeGuardTestChanges.Count | Should -Be 0
 }
 It 'does not create a default route when deferred' {
  $global:routeGuardTestMissing=$true
  & "$fixture\tools\Repair-MihomoAdapters.ps1"
  $global:routeGuardTestChanges.Count | Should -Be 0
 }
 It 'can reconcile an idle stable metric when allowed' {
  $global:routeGuardTestAllowed=$true
  $report=& "$fixture\tools\Repair-MihomoAdapters.ps1"
  ($report -join ',') | Should -Not -Match 'ERROR|WARN'
  ($global:routeGuardTestChanges -join ',') | Should -Be 'metric'
 }
 It 'can create a missing route when allowed' {
  $global:routeGuardTestAllowed=$true;$global:routeGuardTestMissing=$true
  & "$fixture\tools\Repair-MihomoAdapters.ps1"
  ($global:routeGuardTestChanges -join ',') | Should -Be 'create-route'
 }
 It 'keeps check-only mode free of route mutations' {
  $global:routeGuardTestAllowed=$true
  & "$fixture\tools\Repair-MihomoAdapters.ps1" -CheckOnly
  $global:routeGuardTestChanges.Count | Should -Be 0
 }
 It 'preserves interface priority while the route guard defers changes' {
  $map=Get-Content "$fixture\config\mihomo-adapters.json" -Raw|ConvertFrom-Json
  $map[0]|Add-Member interfaceMetric 10
  ConvertTo-Json -InputObject @($map)|Set-Content "$fixture\config\mihomo-adapters.json"
  & "$fixture\tools\Repair-MihomoAdapters.ps1"
  Should -Invoke Set-NetIPInterface -Times 0 -Exactly
 }
 It 'reconciles explicit interface priority only when stable and idle' {
  $map=Get-Content "$fixture\config\mihomo-adapters.json" -Raw|ConvertFrom-Json
  $map[0]|Add-Member interfaceMetric 10
  ConvertTo-Json -InputObject @($map)|Set-Content "$fixture\config\mihomo-adapters.json"
  $global:routeGuardTestAllowed=$true
  & "$fixture\tools\Repair-MihomoAdapters.ps1"
  Should -Invoke Set-NetIPInterface -Times 1 -Exactly -ParameterFilter { $InterfaceIndex -eq 99 -and $InterfaceMetric -eq 10 -and $AutomaticMetric -eq 'Disabled' }
 }
 It 'defers measured MTU changes while connections are active' {
  $map=Get-Content "$fixture\config\mihomo-adapters.json" -Raw|ConvertFrom-Json
  $map[0]|Add-Member ipv4Mtu 1400
  ConvertTo-Json -InputObject @($map)|Set-Content "$fixture\config\mihomo-adapters.json"
  & "$fixture\tools\Repair-MihomoAdapters.ps1"
  Should -Invoke Set-NetIPInterface -Times 0 -Exactly
 }
 It 'repairs the measured IPv4 MTU without altering IPv6' {
  $map=Get-Content "$fixture\config\mihomo-adapters.json" -Raw|ConvertFrom-Json
  $map[0]|Add-Member ipv4Mtu 1400
  ConvertTo-Json -InputObject @($map)|Set-Content "$fixture\config\mihomo-adapters.json"
  $global:routeGuardTestAllowed=$true
  Mock Get-NetIPInterface { [pscustomobject]@{NlMtu=1500} }
  & "$fixture\tools\Repair-MihomoAdapters.ps1"
  Should -Invoke Set-NetIPInterface -Times 1 -Exactly -ParameterFilter { $InterfaceIndex -eq 99 -and $AddressFamily -eq 'IPv4' -and $NlMtuBytes -eq 1400 }
 }
 It 'does not accept an invalid measured MTU' {
  $map=Get-Content "$fixture\config\mihomo-adapters.json" -Raw|ConvertFrom-Json
  $map[0]|Add-Member ipv4Mtu 0
  ConvertTo-Json -InputObject @($map)|Set-Content "$fixture\config\mihomo-adapters.json"
  $global:routeGuardTestAllowed=$true
  $report=& "$fixture\tools\Repair-MihomoAdapters.ps1"
  ($report -join ',') | Should -Match 'ERROR'
  Should -Invoke Set-NetIPInterface -Times 0 -Exactly
 }
 It 'reconciles IPv6 default route priority through the same guard' {
  $global:routeGuardTestAllowed=$true
  Mock Get-NetRoute { New-CimInstance -ClassName MSFT_NetRoute -Namespace root/StandardCimv2 -ClientOnly -Property @{DestinationPrefix='::/0';NextHop='fe80::1';RouteMetric=[uint32]256} }
  & "$fixture\tools\Repair-MihomoAdapters.ps1"
  Should -Invoke Set-NetRoute -Times 1 -Exactly -ParameterFilter { $RouteMetric -eq 30 }
 }
}
AfterAll {
 Remove-Module AdapterRouteGuard -Force -ErrorAction SilentlyContinue
 Remove-Variable routeGuardTestAllowed,routeGuardTestChanges,routeGuardTestMissing -Scope Global -ErrorAction SilentlyContinue
}
