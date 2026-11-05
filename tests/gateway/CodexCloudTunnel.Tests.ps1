BeforeAll {
 $root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
 . "$root\tools\Watch-CodexCloudTunnel.ps1" -FunctionsOnly
 $policy=[pscustomobject]@{device='CodexCloud';mixedPort=19990;controllerPort=19997;egressPort=19989}
}
Describe 'Codex cloud tunnel boundaries' {
 It 'creates only host routes for the supplied public IPv4 and IPv6 addresses' {
  $config=New-CodexCloudTunnelConfig $policy @('104.18.32.47','2606:4700:4408::ac40:9bd1')
  $config.tun.'route-address' | Should -Contain '104.18.32.47/32'
  $config.tun.'route-address' | Should -Contain '2606:4700:4408::ac40:9bd1/128'
  $config.tun.'route-address'.Count | Should -Be 2
  $config.tun.'dns-hijack'.Count | Should -Be 0
 }
 It 'never turns loopback, private or invalid answers into routes' {
  $config=New-CodexCloudTunnelConfig $policy @('127.0.0.1','192.168.137.1','172.20.10.1','100.64.0.1','::1','fd00::1','garbage','104.18.32.47')
  $config.tun.'route-address'.Count | Should -Be 1
  $config.tun.'route-address'[0] | Should -Be '104.18.32.47/32'
 }
 It 'fails closed instead of creating a default route when DNS has no usable answer' {
  {New-CodexCloudTunnelConfig $policy @('0.0.0.0','::','127.0.0.1')} | Should -Throw
 }
 It 'uses only the loopback Codex egress and does not duplicate server credentials' {
  $config=New-CodexCloudTunnelConfig $policy @('104.18.32.47')
  $config.'etag-support' | Should -BeFalse
  $config.proxies[0].server | Should -Be '127.0.0.1'
  $config.proxies[0].port | Should -Be 19989
  $config.'external-controller' | Should -Be '127.0.0.1:19997'
  ($config|ConvertTo-Json -Depth 12) | Should -Not -Match 'password|private-key'
 }
}
