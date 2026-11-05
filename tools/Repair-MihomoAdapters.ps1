# Elevated targeted reconciliation; never restart the shared bridge service or WANs.
[CmdletBinding()]param([string[]]$Only, [switch]$CheckOnly)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$map=Get-Content "$root\config\mihomo-adapters.json" -Raw|ConvertFrom-Json
# Windows picks the lowest total metric (interface + route). Only an elevated process may change it.
$canAdjustRoutes=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$mutex=[Threading.Mutex]::new($false,'Global\MihomoAdapterRepair')
$held=$false
try {
 try {$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
 if(-not $held){Write-Output 'Adapter recovery already running';return}
# The watcher re-reads this script each loop; no service/config reload is needed.
$routeGuard=[pscustomobject]@{Allowed=$false;Reason='check-only'}
if(-not $CheckOnly -and @($map|Where-Object {$null -ne $_.routeMetric -or $null -ne $_.interfaceMetric -or $null -ne $_.ipv4Mtu -or $_.gateway}).Count){
 Import-Module "$root\src\NetStack\AdapterRouteGuard.psm1" -Force -ErrorAction Stop
 $routeGuard=Get-AdapterRouteMutationGuard -RepositoryRoot $root -Adapters $map -Nics @(Get-NetAdapter -ErrorAction Stop)
}
foreach($entry in $map){
 try {
 if($Only -and $entry.name -notin $Only){continue}
 # Phone tethering can randomize its MAC on reconnect. Match recorded hardware
 # identity as well; never guess using the friendly name or device description.
 $matches=@(Get-NetAdapter | Where-Object {
  ($entry.mac -and $_.MacAddress -eq $entry.mac) -or
  ($entry.interfaceGuid -and ([string]$_.InterfaceGuid).Trim('{}') -eq ([string]$entry.interfaceGuid).Trim('{}')) -or
  ($entry.pnpDeviceId -and $_.PnPDeviceID -eq $entry.pnpDeviceId)
 })
 if($matches.Count -ne 1){Write-Output "$($entry.name): absent or ambiguous; unchanged";continue}
 $nic=$matches[0]
 # Explicit dual-stack preference survives DHCP/link-speed changes. Automatic
 # recovery changes metrics only through the same stable-idle route guard.
 if(-not $CheckOnly -and $routeGuard.Allowed -and $canAdjustRoutes -and $null -ne $entry.interfaceMetric -and $nic.Status -eq 'Up'){
  foreach($ipInterface in @(Get-NetIPInterface -InterfaceIndex $nic.ifIndex -ErrorAction Stop)){
   if([int]$ipInterface.InterfaceMetric -eq [int]$entry.interfaceMetric -and [string]$ipInterface.AutomaticMetric -eq 'Disabled'){continue}
   Set-NetIPInterface -InterfaceIndex $nic.ifIndex -AddressFamily $ipInterface.AddressFamily -AutomaticMetric Disabled -InterfaceMetric ([int]$entry.interfaceMetric) -ErrorAction Stop
   Write-Output "Set $($entry.name) $($ipInterface.AddressFamily) interface metric $($entry.interfaceMetric)"
  }
 }
 # Optional measured IPv4 MTU; preserve active sessions with the same guard.
 if(-not $CheckOnly -and $routeGuard.Allowed -and $canAdjustRoutes -and $null -ne $entry.ipv4Mtu -and $nic.Status -eq 'Up'){
  $mtu=[int]$entry.ipv4Mtu
  if($mtu -lt 576 -or $mtu -gt 1500){throw 'Configured IPv4 MTU must be between 576 and 1500'}
  $ipInterface=Get-NetIPInterface -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction Stop
  if([int]$ipInterface.NlMtu -ne $mtu){
   Set-NetIPInterface -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -NlMtuBytes $mtu -ErrorAction Stop
   Write-Output "Set $($entry.name) IPv4 MTU $mtu"
  }
 }
 if($entry.ipv4Address -and $nic.Status -eq 'Up'){
  $address=Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object IPAddress -eq $entry.ipv4Address
  if($address -and $address.AddressState -eq 'Duplicate'){throw "Configured address collision on $($entry.name); preserving other adapters"}
  if(-not $address -and -not $CheckOnly){
   New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $entry.ipv4Address -PrefixLength $entry.prefixLength | Out-Null
   Write-Output "Restored configured IPv4 address on $($entry.name)"
  }
  if(-not $CheckOnly -and $routeGuard.Allowed -and -not (Get-NetRoute -InterfaceIndex $nic.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue|Where-Object NextHop -eq $entry.gateway)){
   $createMetric=if($null -ne $entry.routeMetric){[int]$entry.routeMetric}else{50}
   New-NetRoute -InterfaceIndex $nic.ifIndex -DestinationPrefix '0.0.0.0/0' -NextHop $entry.gateway -RouteMetric $createMetric|Out-Null
  }
 }
 # Declared Windows default-route preference: lower route metric ranks the adapter earlier.
 if(-not $CheckOnly -and $routeGuard.Allowed -and $canAdjustRoutes -and $null -ne $entry.routeMetric -and $nic.Status -eq 'Up' -and $nic.ifIndex){
  $desired=[int]$entry.routeMetric
  foreach($route in @(Get-NetRoute -InterfaceIndex $nic.ifIndex -ErrorAction SilentlyContinue | Where-Object DestinationPrefix -in @('0.0.0.0/0','::/0'))){
   if([int]$route.RouteMetric -eq $desired){continue}
   $previous=[int]$route.RouteMetric
   try{Set-NetRoute -InputObject $route -RouteMetric $desired -ErrorAction Stop;Write-Output "Set $($entry.name) default-route metric $desired (was $previous)"}
   catch{Write-Output "WARN $($entry.name): default-route metric unchanged: $($_.Exception.Message)"}
  }
 }
 if($CheckOnly){Write-Output "$($entry.name): name=$($nic.Name) status=$($nic.Status) mac=$($nic.MacAddress) native Windows recovery"}
 elseif($nic.Name -ne $entry.name){Rename-NetAdapter -InputObject $nic -NewName $entry.name;Write-Output "Restored name $($entry.name)"}
 }catch{Write-Output "ERROR $($entry.name): $($_.Exception.Message)"}
}

}finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
