# =============================================================================
#  Mobile Hotspot controller  (start / stop / status / restart)
#
#  WHY THIS EXISTS
#  ---------------
#  HypoMux has a hotspot feature ("聚合热点") and stores its preferences, but it
#  exposes no auto-start setting - `start_saved_hotspot` is an internal JS method
#  the GUI calls, and `settings.json` carries no hotspot key.
#
#  However HypoMux's hotspot is really just the **Windows Mobile Hotspot**: the
#  saved SSID/band/password live in Windows and are readable back through the
#  WinRT tethering API. So the hotspot can be driven entirely from PowerShell,
#  with no GUI and no HypoMux dependency.
#
#  Verified on this machine:
#      internet profile : 以太网 2
#      saved SSID       : 'HypoMux'   5 GHz   WPA2   max 8 clients
#
#  The lifecycle policy lives in Hotspot.Core.psm1 and is tested with fake
#  Windows operations. This script is the WinRT/registry/ICS adapter. Band
#  settings are preferences: saved configuration is not on-air measurement.
#
#  The WinRT API needs a user session, so this is meant to run at LOGON, not at
#  boot. Register with register-hotspot-task.ps1.
#
#  Usage (WINDOWS POWERSHELL 5.1 - see below):
#      powershell -File hotspot.ps1 status
#      powershell -File hotspot.ps1 start
#      powershell -File hotspot.ps1 stop
#      powershell -File hotspot.ps1 restart
#      powershell -File hotspot.ps1 ensure     <- watchdog: repair if needed
#      powershell -File hotspot.ps1 diag       <- full diagnostic dump (also logged)
#      powershell -File hotspot.ps1 watch      <- sample traffic/chains every
#                                                 -IntervalSeconds for -Minutes
#
#  THIS ONE SCRIPT IS THE DOCUMENTED EXCEPTION to "pwsh 7 is the default shell"
#  (owner, 2026-10-11). It drives the hotspot through the WinRT tethering API
#  (NetworkOperatorTetheringManager), and PowerShell 7 cannot project WinRT types:
#  measured on this machine, `Add-Type System.Runtime.WindowsRuntime` loads but the
#  type lookup throws "Operation is not supported on this platform. (0x80131539)".
#  The MobileHotspot / MobileHotspotStatus tasks therefore stay on powershell.exe,
#  and every caller that reaches this file (start-network.bat, stop-network.bat,
#  start-network.ps1's status line) invokes powershell.exe explicitly.
#
#  WHY `ensure` EXISTS
#  -------------------
#  Measured on this machine 2026-10-11: Windows tore the AP down on its own at
#  11:26:11 because the Wi-Fi radio left AP mode to join a saved network as a
#  client (WLAN-AutoConfig 8008 "started stopping the hosted network", then 8000
#  association). Nothing restarted it - the `MobileHotspot` task only fires at
#  logon and `status` only observes - so the hotspot stayed dark.
#
#  Worse, `start` alone is not enough to recover: it reported state=On while ICS
#  was NOT sharing (the AP held only a 169.254.x address and nothing listened on
#  UDP 67), so clients could associate and then get no address and no internet.
#  One stop/start cycle brought back both the 192.168.137.1 private address and
#  the DHCP server. `ensure` therefore repairs by RESTART, and verifies ICS
#  rather than trusting the tethering state.
#
#  WHY THE IDLE-OFF FIX EXISTS (2026-10-13)
#  ----------------------------------------
#  Measured: with no client on the AP, Windows tore the hosted network down at
#  start + 5:00, every time, all day - WLAN-AutoConfig 8008 "stopping" at
#  :03:26, `ensure` reviving it at :04:26, stopped again at :09:26, ... a
#  perfect 6-minute cycle (5 min up, ~1 min dark). The timer follows the LAST
#  client: 13:04:05 start, a client joined 13:05:40, the AP was killed at
#  13:15:36 (5:00 after that client's traffic stopped); sessions with a live
#  client survived 65 and 159 minutes. That is the Mobile Hotspot "power
#  saving" auto-off, and its switch is
#
#      HKLM\SYSTEM\CurrentControlSet\Services\icssvc\Settings\PeerlessTimeoutEnabled
#
#  0 disables the auto-stop. The value does not exist by default, and creating
#  it needs elevation - which `start`/`ensure` have, because the MobileHotspot
#  and MobileHotspotStatus tasks run with RunLevel Highest. A device trying to
#  JOIN during the dark minute got "can't join the network"; that is the bug
#  this fixes. When the fix is applied while an AP session is already running,
#  that session keeps its old timer until restarted, so `ensure` does one
#  stop/start cycle after changing the value.
#
#  WHY THE UPLINK IS CHOSEN (2026-10-27)
#  -------------------------------------
#  Windows Mobile Hotspot shares whatever link Windows calls the default
#  internet connection. On this machine that was `win_turbo_phone`, the slowest
#  of the four tethered links: measured through an isolated engine on
#  2026-10-27, a 2 MB Tencent asset took 10.5 s there (0.20 MB/s) against 1.6 s
#  on `jd_5G` (1.30 MB/s); upload measured 0.18 MB/s against 0.52 MB/s. Client
#  traffic that ignores the PAC - WeChat's own sockets, most native apps - can
#  only use this shared path, so the default link set the ceiling for them.
#
#  NetworkOperatorTetheringManager can be created from a SPECIFIC connection
#  profile, so the access point can share a chosen adapter instead of the
#  default one. `config/network-architecture.json` -> `hotspotUplink.prefer`
#  is the ordered policy; the first usable link wins, the current one is kept
#  while it stays usable, and the Windows default remains the fallback when the
#  policy is disabled, empty, or a preferred start fails. Changing the selected
#  link restarts the AP once (clients reconnect); the choice is persisted in
#  hotspot-state.json so a healthy tick does not churn it.
#
#  LOG FORMAT (state\hotspot.log) - added 2026-10-13 for exactly this class of
#  bug, so a future "can't join" can be answered from the log alone; extended
#  2026-10-27 with the speed evidence:
#      ensure:   one line per watchdog tick - state, ICS facts, clients, uptime
#      uplink:   the policy, usable candidates, selected link, and why
#      ap:       AP lifecycle, config, and the passphrase FINGERPRINT (never
#                the secret) so a password rotation is visible
#      client:   joins and leaves, with the lease address from the ARP table
#      ics:      sharing health transitions
#      idle-off: the PeerlessTimeoutEnabled value and any change to it
#      link:     the AP adapter's link speed, written when it changes
#      traffic:  client bytes since the previous sample (up = client upload,
#                down = client download) with the interval, derived from the
#                AP adapter counters
#      proxy:    per-client proxied flows and the chain that carried them;
#                counts and bytes only, no destinations or payloads
#      wlan:     client association/authentication and AP stop events
#      diag():   full snapshot on every repair and by `diag` - tethering
#                state, ICS facts, neighbors, WLAN interfaces, saved-profile
#                connect modes, and the last WLAN-AutoConfig events with their
#                reasons (8008 stop, 20019 client join, 8000/8003 radio pulls)
# =============================================================================

param(
    [ValidateSet('status', 'start', 'stop', 'restart', 'ensure', 'diag', 'watch')]
    [string]$Action = 'status',
    [string]$ProjectRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    # `watch` only: sample interval and optional duration (0 = until stopped).
    [ValidateRange(5, 3600)] [int]$IntervalSeconds = 15,
    [ValidateRange(0, 1440)] [int]$Minutes = 0
)

$ProjectRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectRoot)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Hotspot.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\NetStack\StateStore.psm1') -Force
$LogFile   = Join-Path $ProjectRoot 'state\hotspot.log'
$StateFile = Join-Path $ProjectRoot 'state\hotspot-state.json'
$SnapshotFile = Join-Path $ProjectRoot 'state\hotspot-status.json'
$ArchitectureFile = Join-Path $ProjectRoot 'config\network-architecture.json'
$null = New-Item -ItemType Directory -Path (Split-Path $StateFile -Parent) -Force
# The controller now samples traffic, so the log needs a bound: one previous
# file, 4 MiB each, the same shape the reboot traces use.
$LogMaxBytes = 4194304
# The Mobile Hotspot service's settings key; PeerlessTimeoutEnabled lives here.
$IcsSvcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\icssvc\Settings'
# Prefer 5 GHz, but retain availability using Auto after radio restrictions.
# The core persists pending changes and a cooldown to avoid repeated disruption.
$PreferredBand = 'FiveGigahertz'

function Write-HLog([string]$m) {
    try {
        if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -ge $LogMaxBytes) {
            Move-Item -LiteralPath $LogFile -Destination "$LogFile.1" -Force
        }
        Add-Content -LiteralPath $LogFile -Encoding UTF8 `
            -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
    } catch { }
}

# ---------------------------------------------------------------------------
# WinRT plumbing - PS 5.1 needs an explicit awaiter for IAsyncOperation<T>
# ---------------------------------------------------------------------------
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
    $script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]
    $null = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking, ContentType = WindowsRuntime]
    $null = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]
} catch {
    Write-HLog "FATAL: WinRT unavailable - $($_.Exception.Message)"
    Write-Output "WinRT unavailable: $($_.Exception.Message)"
    exit 1
}

function Await($op, $type) {
    $m = $script:AsTaskGeneric.MakeGenericMethod($type)
    $t = $m.Invoke($null, @($op))
    return (Wait-HotspotTask -Task $t -Cancel { $op.Cancel() })
}

function Await-Action($op) {
    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'
    } | Select-Object -First 1
    if (-not $method) { throw 'AsTask(IAsyncAction) is unavailable' }
    $task = $method.Invoke($null, @($op))
    $null = Wait-HotspotTask -Task $task -Cancel { $op.Cancel() }
}

function Get-TetherManager {
    # Prefer a profile that actually reports internet connectivity; fall back to
    # the default profile so the script still works on a LAN-only machine.
    $profile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
    if (-not $profile) {
        $profile = [Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles() |
                   Where-Object { $_ -ne $null } | Select-Object -First 1
    }
    if (-not $profile) { return $null }
    return [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($profile)
}

<#
    Uplink policy. The tethering manager can be created from any connection
    profile, so the access point can share a chosen link instead of whatever
    Windows calls the default. The order lives in
    config/network-architecture.json -> hotspotUplink; a missing or broken block
    means "leave the Windows default alone", never a startup failure.
#>
function Get-HotspotUplinkPolicy {
    $policy = [pscustomobject]@{ Enabled = $false; Prefer = @() }
    try {
        if (-not (Test-Path -LiteralPath $ArchitectureFile)) { return $policy }
        $json = [IO.File]::ReadAllText($ArchitectureFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $block = $json.PSObject.Properties['hotspotUplink']
        if (-not $block -or -not $block.Value) { return $policy }
        $u = $block.Value
        $enabled = $u.PSObject.Properties['enabled']
        $prefer = $u.PSObject.Properties['prefer']
        if ($enabled) { $policy.Enabled = [bool]$enabled.Value }
        if ($prefer -and $prefer.Value) {
            $policy.Prefer = @($prefer.Value | ForEach-Object { [string]$_ } | Where-Object { $_ })
        }
    } catch {
        Write-HLog "uplink: policy unavailable - $($_.Exception.Message)"
    }
    return $policy
}

<#
    Connection profiles mapped onto adapter names, which is what the policy and
    the log speak. `available` requires both an Up adapter and InternetAccess:
    a profile that only reaches the LAN is not a usable shared uplink.
#>
function Get-UplinkCandidates {
    $out = New-Object System.Collections.ArrayList
    $adapters = @{}
    try {
        foreach ($a in @(Get-NetAdapter -ErrorAction Stop)) {
            # 5.1 returns InterfaceGuid as a braced string, 7 returns a Guid:
            # normalize both to the canonical lowercase form.
            try { $adapters[([guid]$a.InterfaceGuid).Guid] = $a } catch { }
        }
    } catch { }
    try {
        foreach ($p in @([Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles())) {
            if (-not $p) { continue }
            $guid = ''
            try { $guid = ([guid]$p.NetworkAdapter.NetworkAdapterId).Guid } catch { }
            $adapter = if ($guid -and $adapters.ContainsKey($guid)) { $adapters[$guid] } else { $null }
            $name = if ($adapter) { [string]$adapter.Name } else { [string]$p.ProfileName }
            $level = ''
            try { $level = [string]$p.GetNetworkConnectivityLevel() } catch { }
            [void]$out.Add([pscustomobject]@{
                name = $name; profile = $p; connectivity = $level
                available = ($level -eq 'InternetAccess' -and $adapter -and [string]$adapter.Status -eq 'Up')
            })
        }
    } catch {
        Write-HLog "uplink: profile enumeration failed - $($_.Exception.Message)"
    }
    return @($out)
}

function Get-TetherManagerFor([string]$Name, $Candidates) {
    if (-not $Name) { return $null }
    foreach ($c in @($Candidates)) {
        if ($c.name -ne $Name -or -not $c.available) { continue }
        try {
            return [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($c.profile)
        } catch {
            Write-HLog "uplink: cannot tether '$Name' - $($_.Exception.Message)"
            return $null
        }
    }
    return $null
}

<#
    The shared uplink as ICS actually configured it. ICS enables IPv4
    forwarding on its public interface (and on the AP adapter), so the
    non-AP adapter with forwarding on is the link client traffic leaves by.
    That is the only trustworthy readout: the tethering API reports success
    for either link, and the persisted choice can be stale after a manual
    start from Windows Settings.
#>
function Get-ObservedUplink {
    $apIndexes = @()
    try {
        $apIndexes = @(Get-NetIPAddress -AddressFamily IPv4 -IPAddress '192.168.137.1' -ErrorAction Stop |
            ForEach-Object { [int]$_.InterfaceIndex })
    } catch { }
    try {
        foreach ($i in @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop)) {
            if ([string]$i.Forwarding -ne 'Enabled') { continue }
            if ($apIndexes -contains [int]$i.InterfaceIndex) { continue }
            return [string]$i.InterfaceAlias
        }
    } catch { }
    return ''
}

function Format-HotspotBytes([long]$n) {
    if ([Math]::Abs($n) -ge 1048576) { return ('{0:N1}MB' -f ($n / 1048576)) }
    if ([Math]::Abs($n) -ge 1024) { return ('{0:N1}KB' -f ($n / 1024)) }
    return ('{0}B' -f $n)
}

<#
    Per-client flows as the proxy sees them. Deliberately no destinations and
    no payloads: the chain is what explains a slow client, and it is the only
    part the log keeps.
#>
function Get-ClientProxyTraffic {
    $out = @{}
    try {
        $c = Invoke-RestMethod -Uri 'http://127.0.0.1:9097/connections' -TimeoutSec 2 -ErrorAction Stop
        foreach ($x in @($c.connections)) {
            if ($null -eq $x -or $null -eq $x.metadata) { continue }
            $src = [string]$x.metadata.sourceIP
            if ($src -notlike '192.168.137.*') { continue }
            if (-not $out.ContainsKey($src)) {
                $out[$src] = @{ conns = 0; down = [long]0; up = [long]0; chains = @{} }
            }
            $e = $out[$src]
            $e.conns++
            $e.down += [long]$x.download
            $e.up += [long]$x.upload
            $chain = (@($x.chains) -join ' > ')
            if ($chain) { $e.chains[$chain] = 1 }
        }
    } catch { }
    return $out
}

<#
    The speed evidence. One call per observation writes only what changed:
    link speed on transition, client bytes since the previous sample, the
    proxy chain per active client, and WLAN join/stop events since the last
    look. Sampling must never throw into the lifecycle.
#>
function Write-HotspotSamples($State, $Facts, $Clients, $Adapter) {
    try {
        $now = Get-Date

        if ($Adapter) {
            $link = '{0} {1}' -f $Adapter.LinkSpeed, $Adapter.Status
            if ($State.ap_link -ne $link) {
                Write-HLog ("link: ap='{0}' status={1} speed={2}" -f $Adapter.Name, $Adapter.Status, $Adapter.LinkSpeed)
                $State.ap_link = $link
            }
        }

        $stats = $null
        try {
            if ($Facts.ApName) { $stats = Get-NetAdapterStatistics -Name $Facts.ApName -ErrorAction Stop }
        } catch { }
        if ($stats) {
            $prevAt = ConvertTo-IsoDate $State.traffic_at
            if ($prevAt) {
                $secs = ($now - $prevAt).TotalSeconds
                $dUp = [long]$stats.ReceivedBytes - [long]$State.traffic_rx
                $dDown = [long]$stats.SentBytes - [long]$State.traffic_tx
                # Counters restart with the adapter; a negative delta is a
                # re-baseline, not an event.
                if ($secs -gt 1 -and $dUp -ge 0 -and $dDown -ge 0 -and ($dUp + $dDown) -gt 0) {
                    Write-HLog ("traffic: client_up={0} client_down={1} up={2:N2}Mbit/s down={3:N2}Mbit/s clients={4} interval={5:N0}s" -f `
                        (Format-HotspotBytes $dUp), (Format-HotspotBytes $dDown),
                        (($dUp * 8 / $secs) / 1MB), (($dDown * 8 / $secs) / 1MB), @($Clients).Count, $secs)
                }
            }
            $State.traffic_at = $now.ToString('o')
            $State.traffic_rx = [long]$stats.ReceivedBytes
            $State.traffic_tx = [long]$stats.SentBytes
        }

        $proxy = Get-ClientProxyTraffic
        foreach ($ip in @($proxy.Keys | Sort-Object)) {
            $e = $proxy[$ip]
            $chains = @($e.chains.Keys | Select-Object -First 3)
            Write-HLog ("proxy: client={0} conns={1} down={2} up={3} chains={4}" -f `
                $ip, $e.conns, (Format-HotspotBytes $e.down), (Format-HotspotBytes $e.up), ($chains -join ', '))
        }

        $seen = ConvertTo-IsoDate $State.wlan_seen
        foreach ($ev in @(Get-WlanEvents -Minutes 15)) {
            if ($ev.Id -notin @(20019, 20020, 8008, 8000, 8003)) { continue }
            if ($seen -and $ev.At -le $seen) { continue }
            Write-HLog ("wlan: {0}" -f (Format-WlanEvent $ev))
        }
        $State.wlan_seen = $now.ToString('o')
    } catch {
        Write-HLog "sample: $($_.Exception.Message)"
    }
}

function Show-Status($mgr) {
    $state   = $mgr.TetheringOperationalState
    $cfg     = $mgr.GetCurrentAccessPointConfiguration()
    $clients = @($mgr.GetTetheringClients())
    $facts   = Get-IcsFacts
    $hl      = Read-HState
    $now     = Get-Date
    $apAdapter = $null
    if ($facts.ApIndex -gt 0) {
        try { $apAdapter = Get-NetAdapter -InterfaceIndex $facts.ApIndex -ErrorAction Stop } catch { }
    }

    # --- passphrase fingerprint: a rotation is visible, the secret never logged
    $pfp = ''
    try { $pfp = Get-Fingerprint([string]$cfg.Passphrase) } catch { }
    if ($pfp) {
        if ($hl.pass_fp -and $hl.pass_fp -ne $pfp) {
            Write-HLog ("ap: passphrase fingerprint {0} -> {1} - the hotspot password CHANGED; saved clients must re-enter it" -f $hl.pass_fp, $pfp)
        }
        $hl.pass_fp = $pfp
    }

    # WinRT exposes no AP start clock; record only observed On/Off transitions.
    $oldStarted = $hl.ap_started
    Update-HotspotSession -State $hl -ObservedState ([string]$state) -Now $now
    if (-not $oldStarted -and $hl.ap_started) { Write-HLog "ap: observed On (saved_band=$($cfg.Band))" }
    if ($oldStarted -and -not $hl.ap_started) { Write-HLog 'ap: observed Off' }

    # --- clients: arrivals and departures with the lease address from the ARP table
    $macIp = @{}
    foreach ($n in @($facts.Neighbors)) {
        $macIp[(([string]$n.LinkLayerAddress) -replace '[:-]', '').ToLowerInvariant()] = [string]$n.IPAddress
    }
    $seen = @{}
    foreach ($c in $clients) {
        $mac = [string]$c.MacAddress
        $k   = ($mac -replace '[:-]', '').ToLowerInvariant()
        $seen[$k] = $true
        $ip = ''
        if ($macIp.ContainsKey($k)) { $ip = $macIp[$k] }
        if ($hl.clients.ContainsKey($k)) {
            $hl.clients[$k].last = $now.ToString('o')
            if ($ip) { $hl.clients[$k].ip = $ip }
        } else {
            $hl.clients[$k] = @{ first = $now.ToString('o'); last = $now.ToString('o'); ip = $ip }
            $device = [string]$c.DeviceName
            Write-HLog ("client: + mac={0} ip={1} name='{2}' link={3} (now {4} client(s))" -f `
                $mac, $(if ($ip) { $ip } else { 'no lease yet' }), $device,
                $(if ($apAdapter) { $apAdapter.LinkSpeed } else { '?' }), $seen.Count)
        }
    }
    foreach ($k in @($hl.clients.Keys)) {
        if ($seen.ContainsKey($k)) { continue }
        $c = $hl.clients[$k]
        $f = ConvertTo-IsoDate $c.first
        $l = ConvertTo-IsoDate $c.last
        Write-HLog ("client: - mac={0} ip={1} (first {2} last {3})" -f $k, $(if ($c.ip) { $c.ip } else { '?' }),
            $(if ($f) { $f.ToString('HH:mm:ss') } else { '?' }), $(if ($l) { $l.ToString('HH:mm:ss') } else { '?' }))
        $hl.clients.Remove($k)
    }
    # Last tick at which somebody was connected; the preemptive-restart check
    # in `ensure` counts idle time from here.
    if ($clients.Count -gt 0) { $hl.last_client_at = $now.ToString('o') }

    $apUp = 0
    if ($state -eq 'On' -and $hl.ap_started) {
        $s = ConvertTo-IsoDate $hl.ap_started
        if ($s) { $apUp = [int]($now - $s).TotalSeconds }
    }
    $iov   = Get-IdleOffValue
    $icsOk = [bool]($facts.Addr -and $facts.Dhcp)

    Write-Output ("state        : {0}" -f $state)
    Write-Output ("ssid         : {0}" -f $cfg.Ssid)
    Write-Output ("band         : {0}" -f $cfg.Band)
    Write-Output ("auth         : {0}" -f $cfg.AuthenticationKind)
    Write-Output ("max clients  : {0}" -f $mgr.MaxClientCount)
    Write-Output ("clients now  : {0}" -f $clients.Count)
    foreach ($c in $clients) {
        $k = ([string]$c.MacAddress -replace '[:-]', '').ToLowerInvariant()
        Write-Output ("   - {0}  {1}  ip={2}" -f $c.DeviceName, $c.MacAddress,
            $(if ($macIp.ContainsKey($k)) { $macIp[$k] } else { '?' }))
    }
    Write-Output ("ics          : {0}" -f $(if ($icsOk) { 'sharing (192.168.137.1 + DHCP :67)' } else { "NOT SHARING (addr=$($facts.Addr) dhcp67=$($facts.Dhcp))" }))
    Write-Output ("ap uptime    : {0}" -f $(if ($apUp -gt 0) { '{0}m{1:d2}s' -f [int]($apUp / 60), ($apUp % 60) } else { '-' }))
    Write-Output ("idle auto-off: {0}" -f $(if ($null -eq $iov) { 'WINDOWS DEFAULT - stops 5 min after the last client (fix pending: needs an elevated run)' } elseif ($iov -eq 0) { 'disabled' } else { "enabled ($iov)" }))
    $configuredUplink = [string]$hl.uplink
    $observedUplink = Get-ObservedUplink
    $uplinkText = if ($observedUplink -and $configuredUplink) {
        if ($observedUplink -eq $configuredUplink) { $observedUplink } else { "$configuredUplink (observed $observedUplink)" }
    } elseif ($observedUplink) { "system default ($observedUplink)" }
    elseif ($configuredUplink) { "$configuredUplink (not observed)" }
    else { 'system default' }
    Write-Output ("uplink       : {0}" -f $uplinkText)

    # Speed evidence: link speed, client bytes, proxy chains, WLAN joins.
    Write-HotspotSamples -State $hl -Facts $facts -Clients $clients -Adapter $apAdapter

    # Snapshot for the dashboard. The dashboard collector runs as SYSTEM, where
    # the WinRT tethering API is unavailable (it needs a user session), so it
    # reads this file for SSID / band / client list and falls back to OS-level
    # adapter detection for the on/off state. Existing keys are kept verbatim;
    # the extra keys (ip, ics_ok, ap_uptime_s, last_stop, idle_off, pass_fp)
    # are additive, for the same "can't join" forensics this log serves.
    $clientArr = @(
        foreach ($c in $clients) {
            $mac = [string]$c.MacAddress
            $k = ($mac -replace '[:-]', '').ToLowerInvariant()
            [pscustomobject]@{
                name = [string]$c.DeviceName; mac = $mac
                ip = $(if ($macIp.ContainsKey($k)) { $macIp[$k] } else { '' })
            }
        }
    )
    $lastStop = ''
    if ($hl.ap_stopped) {
        $t = ConvertTo-IsoDate $hl.ap_stopped
        if ($t) { $lastStop = $t.ToString('HH:mm:ss') }
    }
    $idleLabel = if ($null -eq $iov) { 'default' } elseif ($iov -eq 0) { 'disabled' } else { [string]$iov }
    $snapshot = New-HotspotSnapshot -State ([string]$state) -Ssid $cfg.Ssid -Band ([string]$cfg.Band) `
        -Authentication ([string]$cfg.AuthenticationKind) -MaxClients $mgr.MaxClientCount -Clients $clientArr `
        -SharingHealthy $icsOk -UptimeSeconds $apUp -LastStop $lastStop -IdleOff $idleLabel -Fingerprint $pfp `
        -Uplink ([string]$hl.uplink) `
        -Enabled ([bool]$hl.enabled) -RestartPending ([bool]($hl.band_restart_pending -or $hl.restart_pending)) -Now $now
    Save-HState $hl
    try { Write-HotspotJson -Path $SnapshotFile -Value $snapshot }
    catch { Write-HLog "snapshot write failed: $($_.Exception.Message)" }
    return $state
}

<#
    ICS health, checked from the OS rather than from the WinRT state.

    The tethering state alone lies: measured on this machine, `start` reported
    state=On while internet sharing was not configured at all - the AP adapter
    held only a 169.254.x link-local address and nothing listened on UDP 67, so
    a client could associate and then get neither a lease nor internet.

    Two cheap facts, both required:
      * the ICS private address 192.168.137.1 is present
      * a DHCP server listens on it, UDP 67
#>
<#
    The same two facts as before, plus what the DIAG lines need: the AP adapter
    and the ARP neighbors (which is how a client's lease address is recovered
    without WinRT - the tethering client list carries only MACs).
#>
function Get-IcsFacts {
    $f = [ordered]@{
        Addr      = $false
        Dhcp      = $false
        ApIndex   = 0
        ApName    = ''
        ApStatus  = ''
        ApIp      = ''
        Neighbors = @()
    }
    try {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
              Where-Object { $_.IPAddress -eq '192.168.137.1' } | Select-Object -First 1
        if ($ip) {
            $f.Addr    = $true
            $f.ApIndex = [int]$ip.InterfaceIndex
            $f.ApIp    = ('{0}/{1}' -f $ip.IPAddress, $ip.PrefixLength)
        }
    } catch { }
    try {
        $dhcp = Get-NetUDPEndpoint -ErrorAction Stop |
                Where-Object { $_.LocalPort -eq 67 -and $_.LocalAddress -eq '192.168.137.1' }
        $f.Dhcp = [bool]$dhcp
    } catch { }
    if ($f.ApIndex -gt 0) {
        try {
            $a = Get-NetAdapter -InterfaceIndex $f.ApIndex -ErrorAction Stop
            if ($a) { $f.ApName = [string]$a.Name; $f.ApStatus = [string]$a.Status }
        } catch { }
        try {
            $f.Neighbors = @(Get-NetNeighbor -InterfaceIndex $f.ApIndex -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.State -in @('Reachable', 'Stale', 'Permanent') -and
                               $_.IPAddress -match '^192\.168\.137\.' -and
                               $_.LinkLayerAddress -ne 'FF-FF-FF-FF-FF-FF' -and
                               $_.IPAddress -notmatch '\.255$' })
        } catch { }
    }
    return $f
}

function Test-IcsHealthy {
    $address = @(Get-NetIPAddress -AddressFamily IPv4 -IPAddress '192.168.137.1' -ErrorAction SilentlyContinue)
    if (-not $address.Count) { return $false }
    $dhcp = @(Get-NetUDPEndpoint -LocalPort 67 -LocalAddress '192.168.137.1' -ErrorAction SilentlyContinue)
    return ($dhcp.Count -gt 0)
}

function Get-Fingerprint([string]$Text) {
    if (-not $Text) { return '' }
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) }
        finally { $sha.Dispose() }
        return (($h[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
    } catch { return '' }
}

function ConvertTo-IsoDate([string]$Text) {
    if (-not $Text) { return $null }
    try {
        return [datetime]::Parse($Text, [Globalization.CultureInfo]::InvariantCulture,
                                 [Globalization.DateTimeStyles]::RoundtripKind)
    } catch { return $null }
}

# ---------------------------------------------------------------------------
#  Persistent state: hotspot-state.json
#  What one tick cannot know on its own: when the AP came up or died, who the
#  clients were (and their leases), and the passphrase fingerprint that later
#  answers "did the password change?" without the secret ever hitting the log.
# ---------------------------------------------------------------------------
function Read-HState {
    $s = New-HotspotState
    try {
        if (Test-Path -LiteralPath $StateFile) {
            $j = [System.IO.File]::ReadAllText($StateFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($k in @('ap_started', 'ap_stopped', 'pass_fp', 'idle_fix_at', 'last_client_at', 'band_retry_after', 'fallback_band', 'uplink', 'traffic_at', 'ap_link', 'wlan_seen')) {
                if ($j.PSObject.Properties[$k] -and $j.$k) { $s[$k] = [string]$j.$k }
            }
            foreach ($k in 'enabled', 'band_restart_pending', 'restart_pending', 'uplink_policy') {
                if ($j.PSObject.Properties[$k]) { $s[$k] = [bool]$j.$k }
            }
            foreach ($k in 'traffic_rx', 'traffic_tx') {
                if ($j.PSObject.Properties[$k]) { $s[$k] = [long]$j.$k }
            }
            if ($j.PSObject.Properties['clients'] -and $j.clients) {
                $cl = @{}
                foreach ($p in @($j.clients.PSObject.Properties)) {
                    $c = @{ first = ''; last = ''; ip = '' }
                    foreach ($k in @('first', 'last', 'ip')) {
                        $pv = $p.Value.PSObject.Properties[$k]
                        if ($pv -and $pv.Value) { $c[$k] = [string]$pv.Value }
                    }
                    $cl[$p.Name] = $c
                }
                $s['clients'] = $cl
            }
        }
    } catch { Write-HLog "state read failed: $($_.Exception.Message)" }
    return $s
}

function Write-HotspotJson([string]$Path, $Value) {
    Write-AtomicJson -Path $Path -Value $Value
}

function Save-HState($s) {
    Write-HotspotJson -Path $StateFile -Value $s
}

# ---------------------------------------------------------------------------
#  Windows' 5-minute no-client auto-stop (the 6-minute flap cycle)
# ---------------------------------------------------------------------------
function Get-IdleOffValue {
    try {
        $p = Get-ItemProperty -LiteralPath $IcsSvcKey -Name 'PeerlessTimeoutEnabled' -ErrorAction Stop
        return [int]$p.PeerlessTimeoutEnabled
    } catch { return $null }
}

<#
    Returns $true when the value CHANGED (the caller must then restart the AP
    once so the running session picks the new behaviour up). A denied write is
    logged and never fatal - the watchdog must still repair the AP.
#>
function Disable-IdleOff {
    $cur = Get-IdleOffValue
    if ($null -ne $cur -and $cur -eq 0) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $IcsSvcKey)) {
            New-Item -Path $IcsSvcKey -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -LiteralPath $IcsSvcKey -Name 'PeerlessTimeoutEnabled' `
            -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
        Write-HLog ("idle-off: PeerlessTimeoutEnabled {0} -> 0 - the 5-minute no-client auto-stop (measured: killed the AP at last-client+5:00 in a 6-minute cycle) is now disabled" -f `
            $(if ($null -eq $cur) { 'missing' } else { $cur }))
        return $true
    } catch {
        Write-HLog "idle-off: cannot write PeerlessTimeoutEnabled=0 - $($_.Exception.Message) (needs elevation; the MobileHotspot/MobileHotspotStatus tasks run elevated)"
        return $false
    }
}

# ---------------------------------------------------------------------------
#  WLAN-AutoConfig events: the AP and radio story, in one place.
#   8005/8006/8008  hosted network starting/started/stopping (the AP)
#   20019/20020     a client associated/authenticated with the hosted network
#   8000/8001/8003  the Intel radio connecting/connected/disconnected (STA)
#   11010/11005/11004  security start/ok/stop
# ---------------------------------------------------------------------------
$script:WlanEventTags = @{
    8005 = 'ap-starting'; 8006 = 'ap-started'; 8008 = 'ap-stopping'
    20019 = 'client-assoc'; 20020 = 'client-auth'
    11010 = 'security-start'; 11005 = 'security-ok'; 11004 = 'security-stop'
    8000 = 'station-connecting'; 8001 = 'station-connected'; 8003 = 'station-disconnected'
}

<#
    Labels inside EVENT MESSAGES are localized (Chinese here), so they have to
    be matched. They are built from \uXXXX escapes instead of being written as
    literals: this file has no BOM (the repo convention), and Windows PowerShell
    5.1 decodes a BOM-less script as ANSI - measured 2026-10-13, a literal
    pattern came out mangled, and one mangled byte pair swallowed the ']' so
    the -match threw and the catch below silently returned nothing. Escapes are
    pure ASCII on disk and exact at run time under both engines.
#>
$script:RxProfileName = [regex]::Unescape('\u914D\u7F6E\u6587\u4EF6\u540D\u79F0')   # 配置文件名称
$script:RxReason      = [regex]::Unescape('\u539F\u56E0')                           # 原因
$script:RxPeerMac     = [regex]::Unescape('\u5BF9\u7B49 MAC \u5730\u5740')          # 对等 MAC 地址

function Get-WlanEvents([int]$Minutes = 60, [int]$Max = 80) {
    $out = New-Object System.Collections.ArrayList
    try {
        $ev = Get-WinEvent -FilterHashtable @{
                  LogName   = 'Microsoft-Windows-WLAN-AutoConfig/Operational'
                  StartTime = (Get-Date).AddMinutes(-$Minutes)
              } -MaxEvents $Max -ErrorAction SilentlyContinue
        foreach ($e in @($ev)) {
            if (-not $script:WlanEventTags.ContainsKey([int]$e.Id)) { continue }
            $m = ($e.Message -replace "`r?`n", ' ') -replace '\s+', ' '
            $ssid = ''; $profile = ''; $reason = ''; $peer = ''
            if ($m -match 'SSID\s*:\s*(\S+)') { $ssid = $matches[1] }
            if ($m -match ('(' + $script:RxProfileName + ')\s*:\s*(\S+)')) { $profile = $matches[2] }
            if ($m -match ('(' + $script:RxReason + ')\s*:\s*([^|]+)'))    { $reason = $matches[2].Trim() }
            if ($m -match ('(' + $script:RxPeerMac + ')\s*:\s*([0-9A-Fa-f:-]{17})')) { $peer = $matches[2] }
            [void]$out.Add([pscustomobject]@{
                At = $e.TimeCreated; Id = [int]$e.Id; Ssid = $ssid
                Profile = $profile; Reason = $reason; Peer = $peer
            })
        }
    } catch { }
    return @($out | Sort-Object At)
}

function Format-WlanEvent($e) {
    $s = ('wlan {0:HH:mm:ss} id={1} {2}' -f $e.At, $e.Id, $script:WlanEventTags[[int]$e.Id])
    if ($e.Ssid)    { $s += " ssid=$($e.Ssid)" }
    if ($e.Profile -and $e.Profile -ne $e.Ssid) { $s += " profile=$($e.Profile)" }
    if ($e.Peer)    { $s += " peer=$($e.Peer)" }
    if ($e.Reason)  { $s += " reason=$($e.Reason)" }
    return $s
}

function Get-WlanInterfaceSummary {
    $res = New-Object System.Collections.ArrayList
    try {
        $cur = $null
        # English labels only: netsh prints them in English on this machine
        # (observed in every capture). Chinese alternatives would have to be
        # written as literals and die to the 5.1 ANSI-decode trap above.
        foreach ($l in @(& netsh wlan show interfaces 2>$null)) {
            if ($l -match '^\s*Name\s*:\s*(.+?)\s*$') {
                if ($cur) { [void]$res.Add($cur) }
                $cur = @{ name = $matches[1]; state = ''; ssid = ''; bssid = '' }
                continue
            }
            if (-not $cur) { continue }
            if     ($l -match '^\s*State\s*:\s*(.+?)\s*$') { $cur.state = $matches[1] }
            elseif ($l -match '^\s*BSSID\s*:\s*(.+?)\s*$') { $cur.bssid = $matches[1] }
            elseif ($l -match '^\s*SSID\s*:\s*(.+?)\s*$')  { $cur.ssid  = $matches[1] }
        }
        if ($cur) { [void]$res.Add($cur) }
    } catch { }
    return @($res)
}

<#
    Saved profiles and their connect mode. A profile set to auto-connect will
    pull the radio into station mode the moment the AP goes down - the noise
    that entangled itself with the idle-off story on 2026-10-13.
#>
function Get-WlanProfileModes {
    $out = New-Object System.Collections.ArrayList
    try {
        $names = @()
        foreach ($l in @(& netsh wlan show profiles 2>$null)) {
            if ($l -match '^\s*All User Profile\s*:\s*(.+?)\s*$') { $names += $matches[1] }
        }
        foreach ($n in $names) {
            $mode = '?'
            try {
                foreach ($pl in @(& netsh wlan show profile name="$n" 2>$null)) {
                    if ($pl -match '^\s*Connection mode\s*:\s*(.+?)\s*$') { $mode = $matches[1]; break }
                }
            } catch { }
            [void]$out.Add(('{0}={1}' -f $n, $mode))
        }
    } catch { }
    return @($out)
}

<#
    The diagnostic block. Written to hotspot.log on every repair and by the
    `diag` action, so the next "the hotspot is broken" morning starts from
    facts: who stopped the AP (event + reason), whether ICS listened, what the
    radio was doing, and which sessions were fighting it.
#>
function Write-Diag([string]$Tag, $Mgr) {
    $emit = { param($m) Write-HLog ("diag($Tag): $m") }
    try {
        $st  = $Mgr.TetheringOperationalState
        $cfg = $Mgr.GetCurrentAccessPointConfiguration()
        $cl  = @($Mgr.GetTetheringClients())
        $pfp = ''
        try { $pfp = Get-Fingerprint([string]$cfg.Passphrase) } catch { }
        & $emit ("tethering state={0} ssid='{1}' band={2} auth={3} max_clients={4} clients={5} pass_fp={6}" -f `
            $st, $cfg.Ssid, $cfg.Band, $cfg.AuthenticationKind, $Mgr.MaxClientCount, $cl.Count,
            $(if ($pfp) { $pfp } else { 'n/a' }))
        foreach ($c in $cl) { & $emit ("client mac={0} name='{1}'" -f $c.MacAddress, ([string]$c.DeviceName)) }

        $iov = Get-IdleOffValue
        & $emit ("idle_off PeerlessTimeoutEnabled={0} (0 = Windows no-client auto-stop disabled; 'missing' = the stock 5-minute timer is active)" -f `
            $(if ($null -eq $iov) { 'missing' } else { $iov }))
        $wid = [Security.Principal.WindowsIdentity]::GetCurrent()
        $wp  = New-Object Security.Principal.WindowsPrincipal($wid)
        & $emit ("session user={0} elevated={1} powershell={2}" -f $wid.Name,
            $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator), $PSVersionTable.PSVersion)

        $f = Get-IcsFacts
        & $emit ("ics addr={0} dhcp67={1} ap_adapter='{2}' adapter_state={3} ap_ip={4}" -f `
            $f.Addr, $f.Dhcp, $f.ApName, $f.ApStatus, $f.ApIp)
        if (@($f.Neighbors).Count -gt 0) {
            foreach ($n in $f.Neighbors) { & $emit ("neighbor ip={0} mac={1} state={2}" -f $n.IPAddress, $n.LinkLayerAddress, $n.State) }
        } else { & $emit 'neighbor none - no lease holder visible on the AP subnet' }

        foreach ($i in Get-WlanInterfaceSummary) {
            & $emit ("wlan_if '{0}' state={1} ssid={2} bssid={3}" -f $i.name, $i.state,
                $(if ($i.ssid) { $i.ssid } else { '-' }), $(if ($i.bssid) { $i.bssid } else { '-' }))
        }
        $modes = Get-WlanProfileModes
        if (@($modes).Count -gt 0) { & $emit ('saved_profiles ' + ($modes -join ' | ')) }

        $hl = Read-HState
        & $emit ("tracked ap_started={0} ap_stopped={1} idle_fix_at={2}" -f `
            $(if ($hl.ap_started) { $hl.ap_started } else { '-' }),
            $(if ($hl.ap_stopped) { $hl.ap_stopped } else { '-' }),
            $(if ($hl.idle_fix_at) { $hl.idle_fix_at } else { '-' }))
        & $emit 'recent WLAN-AutoConfig events (oldest first):'
        foreach ($e in (@(Get-WlanEvents -Minutes 30) | Select-Object -Last 16)) { & $emit (Format-WlanEvent $e) }
    } catch { & $emit "diag failed: $($_.Exception.Message)" }
}

# The lifecycle adapter for one tethering manager. The caller decides which
# manager (which shared uplink) the access point should use, so a failed
# preferred link can be retried with the Windows default without duplicating
# the operations.
function New-HotspotAdapter($Manager) {
    $adapter = @{
        GetState = { [string]$Manager.TetheringOperationalState }
        GetBand = { [string]$Manager.GetCurrentAccessPointConfiguration().Band }
        SupportsBand = {
            param($Name)
            $cfg = $Manager.GetCurrentAccessPointConfiguration()
            $band = [Enum]::Parse([Windows.Networking.NetworkOperators.TetheringWiFiBand], $Name)
            return $cfg.IsBandSupported($band)
        }
        SetBand = {
            param($Name)
            $cfg = $Manager.GetCurrentAccessPointConfiguration()
            $cfg.Band = [Enum]::Parse([Windows.Networking.NetworkOperators.TetheringWiFiBand], $Name)
            Await-Action ($Manager.ConfigureAccessPointAsync($cfg))
        }
        Start = {
            $result = Await ($Manager.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
            [string]$result.Status
        }
        Stop = {
            $result = Await ($Manager.StopTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
            [string]$result.Status
        }
        SharingHealthy = { Test-IcsHealthy }
        Delay = { param($Seconds) Start-Sleep -Seconds $Seconds }
        Persist = { param($Value) Save-HState $Value }
        Log = { param($Message) Write-HLog $Message }
        Diagnose = { param($Tag) Write-Diag $Tag $Manager }
    }
    # PowerShell scriptblocks are not closures: without this the manager is
    # resolved in the CALLER's scope and every operation sees $null.
    foreach ($key in @($adapter.Keys)) { $adapter[$key] = $adapter[$key].GetNewClosure() }
    return $adapter
}

# --- `watch`: a sampling loop for speed diagnostics. Each sample is a short
# child `status` run, so the device and state locks are never held across a
# sleep and a repair request can still take them between samples.
if ($Action -eq 'watch') {
    $deadline = if ($Minutes -gt 0) { (Get-Date).AddMinutes($Minutes) } else { [datetime]::MaxValue }
    $count = 0
    while ((Get-Date) -lt $deadline) {
        $count++
        try {
            $null = & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive `
                -WindowStyle Hidden -ExecutionPolicy Bypass -File $PSCommandPath status 2>&1
        } catch {
            Write-HLog "watch: sample failed - $($_.Exception.Message)"
        }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds $IntervalSeconds
    }
    Write-HLog ("watch: {0} sample(s) at {1}s interval" -f $count, $IntervalSeconds)
    exit 0
}

$lock = $null
$deviceLock = $null
try {
    $deviceLock = Enter-StateMutex -Name 'Global\MihomoHotspotDevice' -TimeoutMilliseconds 20000
    $lockPath = Join-Path (Split-Path $StateFile -Parent) 'hotspot.lock'
    $lock = Enter-StateLock -Path $lockPath -TimeoutMilliseconds 20000

    $hs = Read-HState
    if (Set-HotspotIntent -State $hs -Action $Action) { Save-HState $hs }
    $mgr = Get-TetherManager
    if (-not $mgr) { throw 'No connection profile available - cannot tether' }
    if ($Action -eq 'status' -or $Action -eq 'diag') {
        if ($Action -eq 'diag') { Write-Diag 'manual' $mgr }
        Show-Status $mgr | Out-Host
        exit 0
    }

    $idleChanged = $false
    if ($Action -ne 'stop') {
        $idleChanged = Disable-IdleOff
        if ($idleChanged) { $hs.idle_fix_at = (Get-Date).ToString('o'); Save-HState $hs }
    }
    $now = Get-Date
    $fixPending = $idleChanged
    $preempt = $false
    if ($Action -ne 'stop' -and $hs.enabled) {
        $started = ConvertTo-IsoDate $hs.ap_started
        $fixedAt = ConvertTo-IsoDate $hs.idle_fix_at
        $fixPending = $idleChanged -or ($fixedAt -and (-not $started -or $started -lt $fixedAt))
        $clients = @($mgr.GetTetheringClients())
        $lastClient = ConvertTo-IsoDate $hs.last_client_at
        if (-not $lastClient -or ($started -and $lastClient -lt $started)) { $lastClient = $started }
        $idleOff = Get-IdleOffValue
        $preempt = $clients.Count -eq 0 -and ($null -eq $idleOff -or $idleOff -ne 0) -and $lastClient -and ($now - $lastClient).TotalSeconds -ge 270
    }
    # --- shared uplink: private-side traffic can only use this one path
    $uplinkPolicy = Get-HotspotUplinkPolicy
    $candidates = Get-UplinkCandidates
    $observedUplink = Get-ObservedUplink
    $currentUplink = if ($observedUplink) { $observedUplink } else { [string]$hs.uplink }
    $selection = Select-HotspotUplink -Candidates $candidates -Preference $uplinkPolicy.Prefer `
        -Current $currentUplink -Enabled ([bool]$uplinkPolicy.Enabled)
    $target = [string]$selection.Name
    # Move the access point only when the choice has never been applied or the
    # link it is actually using is broken. A transient probe blip must not
    # restart the AP (and drop every client) just to chase the next link;
    # a natural restart still re-picks the best link.
    $firstApply = (-not [string]$hs.uplink) -or ([bool]$hs.uplink_policy -ne [bool]$uplinkPolicy.Enabled)
    $currentUsable = [bool]($currentUplink -and @($candidates | Where-Object { $_.available -and $_.name -eq $currentUplink }))
    $uplinkChanged = ($Action -ne 'stop') -and ($target -ne $currentUplink) -and ($firstApply -or -not $currentUsable)
    $usable = @($candidates | Where-Object { $_.available } | ForEach-Object { $_.name })
    Write-HLog ("uplink: enabled={0} prefer={1} usable={2} selected='{3}' observed='{4}' saved='{5}' change={6} first={7} current_usable={8} source={9}" -f `
        $uplinkPolicy.Enabled, (@($uplinkPolicy.Prefer) -join ','), ($usable -join ','),
        $target, $observedUplink, ([string]$hs.uplink), $uplinkChanged, $firstApply, $currentUsable, $selection.Source)
    $uplinkMgr = $null
    if ($target) {
        $uplinkMgr = Get-TetherManagerFor $target $candidates
        if (-not $uplinkMgr) {
            Write-HLog "uplink: '$target' is not usable as a tethering profile; keeping the Windows default"
            $target = ''
            $uplinkChanged = ($Action -ne 'stop') -and ([string]$hs.uplink -ne '')
        }
    }
    $adapter = New-HotspotAdapter $(if ($uplinkMgr) { $uplinkMgr } else { $mgr })
    $outcome = Invoke-HotspotCommand -Action $Action -Adapter $adapter -State $hs -PreferredBand $PreferredBand -RestartRequired ([bool]($fixPending -or $preempt -or $uplinkChanged)) -Now $now
    if (-not $outcome.Success -and $target -and $Action -ne 'stop') {
        # Availability first: an AP on the slow default link beats a dead AP.
        Write-HLog ("uplink: '{0}' could not carry the access point ({1}); retrying on the Windows default link" -f $target, $outcome.Reason)
        $target = ''
        $adapter = New-HotspotAdapter $mgr
        $outcome = Invoke-HotspotCommand -Action $Action -Adapter $adapter -State $hs -PreferredBand $PreferredBand -RestartRequired $true -Now (Get-Date)
    }
    if ($outcome.Success -and $Action -ne 'stop') {
        $appliedUplink = Get-ObservedUplink
        if (-not $appliedUplink) { $appliedUplink = $target }
        $stateChanged = $false
        if ([string]$hs.uplink -ne $appliedUplink) {
            $hs.uplink = $appliedUplink
            $stateChanged = $true
            Write-HLog ("uplink: applied '{0}'" -f $(if ($appliedUplink) { $appliedUplink } else { 'system default' }))
        }
        if ([bool]$hs.uplink_policy -ne [bool]$uplinkPolicy.Enabled) {
            $hs.uplink_policy = [bool]$uplinkPolicy.Enabled
            $stateChanged = $true
        }
        if ($stateChanged) { Save-HState $hs }
        if ($target -and $appliedUplink -and $appliedUplink -ne $target) {
            Write-HLog ("uplink: requested '{0}' but ICS is sharing '{1}'" -f $target, $appliedUplink)
        }
    }
    Write-HLog ("{0}: success={1} reason={2} state={3} saved_band={4} fallback={5}" -f $Action, $outcome.Success, $outcome.Reason, $outcome.State, $outcome.SavedBand, $outcome.Fallback)
    Write-Output ("{0} -> {1} ({2})" -f $Action, $outcome.State, $outcome.Reason)
    if ($outcome.Reason -ne 'TimedOut') {
        try { Show-Status $mgr | Out-Host }
        catch { Write-HLog "status refresh failed after $Action`: $($_.Exception.Message)" }
    }
    if (-not $outcome.Success) { exit 1 }
} catch {
    Write-HLog ("{0}: failed - {1}" -f $Action, $_.Exception.Message)
    Write-Error $_
    exit 1
} finally {
    if ($lock) { $lock.Dispose() }
    if ($deviceLock) { $deviceLock.ReleaseMutex(); $deviceLock.Dispose() }
}
