# =============================================================================
#  Network Stack Dashboard - COLLECTOR
#
#  Standalone process. Rebuilds status.json every few seconds.
#
#  WHY THIS FILE EMITS JSON BY HAND
#  --------------------------------
#  PowerShell 5.1's ConvertTo-Json is unusable here:
#    * Windows cmdlets return rich .NET objects (ServiceController, PSProvider,
#      ErrorRecord ...). ConvertTo-Json expands them into megabytes of
#      reflection metadata - status.json reached 6.6 MB.
#    * On some of that data it does not merely fail: it hangs forever, which
#      took down the whole /api/status endpoint.
#  So every value below goes through JStr/JNum/JBool. Predictable, fast, small.
#
#  OTHER TRAPS ALREADY HIT (documented so they are not repeated):
#    * Get-NetTCPConnection ~3.8 s PER CALL (2300+ sockets) -> netstat -ano (~47 ms)
#    * Get-ScheduledTask    ~1.4 s                         -> schtasks      (~34 ms)
#    * PowerShell variables are CASE-INSENSITIVE. $s and $S are the SAME
#      variable; a loop variable silently destroyed the status object.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Root = '',
    [string] $MihomoApi = 'http://127.0.0.1:9097',
    [string] $HypoSettings = '',
    [ValidateRange(1, 3600)][int] $RefreshSec = 3
)
if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot '..\NetStack\NetStack.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\NetStack\StateStore.psm1') -Force
$StateDir     = Join-Path $Root 'state'
$LogFile      = Join-Path $StateDir 'collector.log'
$StatusFile   = Join-Path $StateDir 'status.json'
$MihomoDir    = Join-Path $Root 'runtime'
if (-not $HypoSettings) {
    # The scheduled collector is SYSTEM, not the interactive repo owner. Prefer
    # the owner's existing sibling .hypomux over SYSTEM's empty user profile.
    # Relocated installs can pass -HypoSettings explicitly.
    $ownerSettings = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($Root))) '.hypomux\settings.json'
    $HypoSettings = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.hypomux\settings.json'
    if (Test-Path -LiteralPath $ownerSettings) { $HypoSettings = $ownerSettings }
}
$TunnelLog    = Join-Path $StateDir 'aliyun-tunnel.log'

function Write-CLog([string]$msg) {
    try {
        Add-Content -LiteralPath $LogFile -Encoding UTF8 `
            -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
    } catch { }
}

# JSON and route classification are shared with the tested NetStack helpers.
Set-Alias JStr ConvertTo-NSJsonString
Set-Alias JNum ConvertTo-NSJsonNumber
Set-Alias JBool ConvertTo-NSJsonBool

function Get-J($url, $t = 5) {
    try { return Invoke-RestMethod -Uri $url -TimeoutSec $t -ErrorAction Stop } catch { return $null }
}

function Probe-Nic([string]$srcIp, [int]$port, [int]$count) {
    $samples = @()
    for ($i = 0; $i -lt $count; $i++) {
        $sock = New-Object System.Net.Sockets.Socket(
            [System.Net.Sockets.AddressFamily]::InterNetwork,
            [System.Net.Sockets.SocketType]::Stream,
            [System.Net.Sockets.ProtocolType]::Tcp)
        if ($srcIp) {
            try { $sock.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($srcIp), 0))) } catch { }
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $iar = $sock.BeginConnect('223.5.5.5', $port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(3000)) { $sock.EndConnect($iar); $sw.Stop(); $samples += $sw.Elapsed.TotalMilliseconds }
        } catch { }
        $sock.Close()
    }
    if ($samples.Count -gt 0) { return [int](($samples | Measure-Object -Average).Average) }
    return $null
}

# ---------------------------------------------------------------------------
# Single-instance guard. Two collectors writing the same file race on the
# rename and can publish a corrupted status.json (observed: the API served
# 141 MB). A global mutex makes the second instance exit immediately.
# ---------------------------------------------------------------------------
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\NetDashCollector', [ref]$createdNew)
if (-not $createdNew) {
    Write-CLog "another collector already holds the mutex - exiting (pid $PID)"
    $mutex.Dispose()
    exit 0
}

try {
# A fresh clone has no runtime state directory. Do this before the first log or
# temporary status write, under the existing single-writer guard.
[void][IO.Directory]::CreateDirectory($StateDir)
Write-CLog "collector starting (pid $PID, refresh ${RefreshSec}s)"

# Cache for the expensive blocking probes (see the links section). Declared
# outside the loop so values survive between iterations.
$linkCache = $null
$linkCacheAge = 99
$tunProbeCache = $null
$tunProbeAge = 99
$taskCache = $null
$taskAge = 99

while ($true) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $now = (Get-Date).ToString('HH:mm:ss')
    $observedAt = [datetimeoffset]::UtcNow.ToString('o')
    $errMsg = ''

    try {
        # ============================ mihomo ============================
        $miState = 'bad'
        $miVersion = 'n/a'; $miUptime = 'n/a'; $miMem = 'n/a'
        $miConns = 0; $miDown = 0; $miUp = 0; $miNativeAlive = $false
        $miCarried = 0; $miLegacyCarried = 0; $miDialer = 0; $routeAgg = @{}
        $localPick = ''
        $grpNames = @(); $grpTypes = @(); $grpNow = @(); $grpCounts = @(); $grpOrders = @()

        $verObj = Get-J "$MihomoApi/version" 5
        if ($verObj) {
            $miState = 'ok'
            $miVersion = "$($verObj.version)"
            $mp = Get-Process mihomo -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($mp) {
                $upSpan = (Get-Date) - $mp.StartTime
                $miUptime = '{0}h {1}m' -f [int]$upSpan.TotalHours, $upSpan.Minutes
                $miMem = '{0} MB' -f [math]::Round($mp.WorkingSet64 / 1MB, 0)
            }
            $cnObj = Get-J "$MihomoApi/connections" 6
            if ($cnObj) {
                $miConns = @($cnObj.connections).Count
                $miDown = $cnObj.downloadTotal
                $miUp = $cnObj.uploadTotal
                # One pass over already-polled chains: classify expected policy
                # paths separately from explicit legacy SOCKS-hop observations.
                # A proxy node name does NOT prove the HypoMux TUN carried it.
                foreach ($cxConn in @($cnObj.connections)) {
                    if ($null -eq $cxConn) { continue }
                    $cxRoute = Get-ChainRoute $cxConn.chains
                    if ($cxRoute.carried) { $miCarried++ }
                    if ($cxRoute.LegacyCarried) { $miLegacyCarried++ }
                    if ($cxRoute.dialer) { $miDialer++ }
                    if ($routeAgg.ContainsKey($cxRoute.label)) {
                        $routeAgg[$cxRoute.label]['count'] = [int]$routeAgg[$cxRoute.label]['count'] + 1
                    } else {
                        $routeAgg[$cxRoute.label] = @{ kind = $cxRoute.kind; count = 1 }
                    }
                }
            }
            # One snapshot discovers all selector groups, including current
            # STORE/LINGODA/CHATGPT/DEV groups and future additions. No per-group
            # requests or hard-coded AUTO/LOCAL-only view.
            $proxyObj = Get-J "$MihomoApi/proxies" 5
            $proxies = Get-SafeProperty $proxyObj 'proxies' $null
            if ($proxies) {
                foreach ($gname in @($proxies.PSObject.Properties.Name | Sort-Object)) {
                    $gObj = Get-SafeProperty $proxies $gname $null
                    $members = Get-SafeProperty $gObj 'all' $null
                    if ($null -eq $members) { continue }
                    $all = @($members)
                    $ord = ((@($all | Select-Object -First 3)) -join ' > ')
                    if ($all.Count -gt 3) { $ord = $ord + ' > ...' }
                    $grpNames += $gname
                    $grpTypes += "$(Get-SafeProperty $gObj 'type' '')"
                    $grpNow += "$(Get-SafeProperty $gObj 'now' '')"
                    $grpCounts += $all.Count
                    $grpOrders += $ord
                    if ($gname -eq 'LOCAL') { $localPick = "$(Get-SafeProperty $gObj 'now' '')" }
                }
                $naObj = Get-SafeProperty $proxies 'aliyun-native' $null
                $miNativeAlive = [bool](Get-SafeProperty $naObj 'alive' $false)
            }
        }

        # =================== one netstat pass ===================
        $nsMaps = ConvertFrom-NetstatOutput -Lines (& netstat.exe -ano 2>$null)
        $listenMap = $nsMaps.Listen
        $estabMap = $nsMaps.Established

        # =================== services ===================
        $svcStatus = @{}
        foreach ($svcName in @('HypoMuxCore')) {
            $svcObj = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svcObj) { $svcStatus[$svcName] = "$($svcObj.Status)" } else { $svcStatus[$svcName] = 'absent' }
        }

        # =================== scheduled tasks ===================
        # NOTE: `schtasks /fo LIST` output is LOCALIZED. The collector runs as
        # SYSTEM, whose UI language differs from the interactive user's, so the
        # "Status:" label we matched on was never present and EVERY task read
        # back as 'absent' (this silently affected the tunnel panel too).
        # Get-ScheduledTask is locale-independent; it costs ~1.6s for four
        # tasks so it is cached and refreshed every 5th pass.
        $taskStatus = @{}
        $taskAge++
        if (($null -eq $taskCache) -or ($taskAge -ge 5)) {
            $taskCache = @{}
            foreach ($t in (Get-ScheduledTask -TaskName 'AliyunTunnel', 'MihomoSplitter', 'MobileHotspot', 'MobileHotspotStatus' -ErrorAction SilentlyContinue)) {
                $taskCache[$t.TaskName] = "$($t.State)"
            }
            $taskAge = 0
        }
        foreach ($taskName in @('AliyunTunnel', 'MihomoSplitter', 'MobileHotspot', 'MobileHotspotStatus')) {
            if ($taskCache.ContainsKey($taskName)) { $taskStatus[$taskName] = $taskCache[$taskName] }
            else { $taskStatus[$taskName] = 'absent' }
        }

        # =================== processes ===================
        $procCount = @{}; $procMem = @{}; $procPid = @{}
        foreach ($pn in @('mihomo', 'ssh', 'hypomux', 'hypomux-engine')) {
            $plist = @(Get-Process -Name $pn -ErrorAction SilentlyContinue)
            $memSum = 0; $firstPid = 0
            foreach ($pp in $plist) { $memSum += $pp.WorkingSet64 }
            if ($plist.Count -gt 0) { $firstPid = $plist[0].Id }
            $procCount[$pn] = $plist.Count
            $procMem[$pn] = [int][math]::Round($memSum / 1MB, 0)
            $procPid[$pn] = $firstPid
        }

        # =================== hypomux ===================
        $portsUp = 0
        if ($listenMap.ContainsKey('10800')) { $portsUp++ }
        if ($listenMap.ContainsKey('10801')) { $portsUp++ }
        $hypoStrategy = 'n/a'; $hypoBypass = $false; $hypoAdapters = @()
        if (Test-Path -LiteralPath $HypoSettings) {
            try {
                $hypoCfg = [System.IO.File]::ReadAllText($HypoSettings, [Text.Encoding]::UTF8) | ConvertFrom-Json
                $hypoStrategy = "$($hypoCfg.strategy)"
                $hypoBypass = [bool]$hypoCfg.blocked_domain_bypass
                $hypoAdapters = @($hypoCfg.selected_adapter_ids)
            } catch { }
        }
        # 2026-10-14 egress-TUN revision: TUN mode closes 10800/10801 BY DESIGN -
        # the engine serves the HypoMux-Tun adapter instead. "OK" now = service
        # Running + engine process + TUN adapter up; the 10800/10801 test stays
        # for the old proxy-mode shape.
        $hyTunUp = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'HypoMux-Tun' -and $_.Status -eq 'Up' }).Count -gt 0
        $hState = 'bad'
        if ($portsUp -eq 2) { $hState = 'ok' }
        elseif ($hyTunUp -and $svcStatus['HypoMuxCore'] -eq 'Running' -and $procCount['hypomux-engine'] -ge 1) { $hState = 'ok' }
        elseif ($svcStatus['HypoMuxCore'] -eq 'Running') { $hState = 'warn' }
        $hyCarrying = Get-HypoMuxCarryingState -TunUp $hyTunUp -ExpectedConnections $miCarried -LegacyConnections $miLegacyCarried

        # SmartDNS was retired in favour of mihomo DNS. Keep its legacy fields
        # for consumers, but do not probe it or report an absent service as broken.
        $sdSvc = 'retired'; $sdState = 'retired'
        $qTotal = 0; $qFailPct = 0; $hitMs = -1; $missMs = -1; $topJson = '[]'

        # =================== ssh tunnel ===================
        $has1080 = $listenMap.ContainsKey('1080')
        $tnState = 'bad'
        if ($has1080) { $tnState = 'ok' } elseif ("$($taskStatus['AliyunTunnel'])" -eq 'Running') { $tnState = 'warn' }
        $sshUp = 'n/a'
        $sshProc = Get-Process ssh -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($sshProc) { $uu = (Get-Date) - $sshProc.StartTime; $sshUp = '{0}h {1}m' -f [int]$uu.TotalHours, $uu.Minutes }
        $probeOk = $false; $probeCode = '-'; $probeMs = $null
        # This probe is a blocking HTTPS request through the tunnel. It gets its
        # own 6s cap and runs only every 5th iteration (cached in between), so a
        # dead tunnel cannot stall the whole status refresh.
        $tunProbeAge++
        if (($null -eq $tunProbeCache) -or ($tunProbeAge -ge 5)) {
            try {
                $prOut = & curl.exe -sS -o NUL -w '%{http_code}|%{time_total}' --max-time 6 `
                            --proxy socks5h://127.0.0.1:1080 'https://www.google.com/generate_204' 2>$null
                if ($prOut) {
                    $pparts = ($prOut | Out-String).Trim() -split '\|'
                    $probeCode = "$($pparts[0])"
                    $probeOk = ($pparts[0] -eq '204' -or $pparts[0] -eq '200')
                    if ($pparts[1] -match '^[\d.]+$') { $probeMs = [int]([double]$pparts[1] * 1000) }
                }
            } catch { }
            $tunProbeCache = @{ ok = $probeOk; code = $probeCode; ms = $probeMs }
            $tunProbeAge = 0
        } else {
            $probeOk = $tunProbeCache.ok; $probeCode = $tunProbeCache.code; $probeMs = $tunProbeCache.ms
        }
        $tunLogJson = '[]'
        try {
            $tunLines = @(Get-Content -LiteralPath $TunnelLog -Tail 3 -ErrorAction SilentlyContinue)
            $tunItems = @()
            foreach ($tl in $tunLines) { $tunItems += (JStr $tl) }
            $tunLogJson = '[' + ($tunItems -join ',') + ']'
        } catch { }

        # =================== mobile hotspot ===================
        # The collector runs as SYSTEM, where the WinRT tethering API is
        # unavailable (it needs a user session). So:
        #   * on/off + adapter IP -> detected via the Wi-Fi Direct virtual adapter
        #   * SSID / band / client list -> read from hotspot-status.json, written
        #     by hotspot.ps1 in a user session (MobileHotspotStatus task)
        $hsAdapter = $null
        foreach ($ad in (Get-NetAdapter -ErrorAction SilentlyContinue)) {
            if ($ad.InterfaceDescription -match 'Wi-Fi Direct Virtual') { $hsAdapter = $ad; break }
        }
        $hsOn = ($null -ne $hsAdapter -and $hsAdapter.Status -eq 'Up')
        $hsIp = ''
        if ($hsAdapter) {
            $hIp = Get-NetIPAddress -InterfaceIndex $hsAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hIp) { $hsIp = "$($hIp.IPAddress)" }
        }
        # ARP on the hotspot subnet gives a client count even without WinRT
        $hsArp = 0
        if ($hsAdapter -and $hsIp) {
            $hsArp = @(Get-NetNeighbor -InterfaceIndex $hsAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                       Where-Object { $_.State -in @('Reachable', 'Stale', 'Permanent') -and $_.IPAddress -notmatch '\.255$|^224\.|^239\.' }).Count
        }
        $hsAge = -1; $hj = $null; $hsJsonClients = '[]'
        $hsSnap = Join-Path $StateDir 'hotspot-status.json'
        if (Test-Path -LiteralPath $hsSnap) {
            try {
                $fi = Get-Item -LiteralPath $hsSnap
                $hsAge = [int]([datetime]::UtcNow - $fi.LastWriteTimeUtc).TotalSeconds
                # Always read source provenance, even when the payload is stale.
                $hj = [IO.File]::ReadAllText($hsSnap, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            } catch { $hj = $null }
        }
        $hsTask = "$($taskStatus['MobileHotspot'])"
        $hsHealth = Get-HotspotState -AdapterUp $hsOn -Snapshot $hj -SnapshotAgeSec $hsAge -TaskState $hsTask
        $hsState = $hsHealth.State; $hsAge = $hsHealth.SnapshotAge
        $hsSsid = $hsHealth.Ssid; $hsBand = $hsHealth.Band; $hsAuth = $hsHealth.Auth
        $hsMax = $hsHealth.MaxClients; $hsClientCount = $hsHealth.ClientCount
        $ci = @()
        foreach ($c in $hsHealth.Clients) {
            $nm = [string](Get-SafeProperty $c 'name' '(unnamed)')
            $ci += ('{{"name":{0},"mac":{1}}}' -f (JStr $nm), (JStr (Get-SafeProperty $c 'mac' '')))
        }
        $hsJsonClients = '[' + ($ci -join ',') + ']'
        if ($hsClientCount -eq 0 -and $hsArp -gt 0) { $hsClientCount = $hsArp }

        # =================== links ===================
        # The probes below are BLOCKING network calls. Measured worst case on a
        # degraded link: Test-Connection 2x4s + curl --max-time 8 x2 NICs +
        # Probe-Nic 3x3s x2 NICs ~= 45s, which pushed build_ms to 48307 and made
        # status.json effectively stop refreshing (the browser polls every 2s).
        # So: shorten every timeout, and only re-probe on every Nth iteration,
        # reusing the cached values in between (connection counts stay live).
        $linkCacheAge++
        $reProbe = ($null -eq $linkCache) -or ($linkCacheAge -ge 5)
        $linkItems = @()
        foreach ($ipa in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
            if ($ipa.IPAddress -match '^(127\.|169\.254\.)') { continue }
            $ad = Get-NetAdapter -InterfaceIndex $ipa.InterfaceIndex -ErrorAction SilentlyContinue
            if (-not $ad -or $ad.Status -ne 'Up' -or $ad.Name -match 'vEthernet') { continue }
            $rt = Get-NetRoute -InterfaceIndex $ipa.InterfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1
            $gwAddr = ''; $gwLat = $null; $pubIp = ''; $probeVal = $null
            if ($reProbe) {
                if ($rt) {
                    $gwAddr = "$($rt.NextHop)"
                    $pingRes = Test-Connection -ComputerName $gwAddr -Count 1 -ErrorAction SilentlyContinue
                    if ($pingRes) { $gwLat = [int](($pingRes | Measure-Object -Property ResponseTime -Average).Average) }
                }
                try {
                    $curlOut = & curl.exe -sS --max-time 4 --noproxy '*' --interface $ipa.IPAddress 'https://ipinfo.io/ip' 2>$null
                    if ($curlOut) { $pubIp = ($curlOut | Out-String).Trim() }
                } catch { }
                $probeVal = Probe-Nic $ipa.IPAddress 443 2
            } else {
                # reuse the previous probe results for this NIC
                foreach ($c in $linkCache) {
                    if ($c.ip -eq $ipa.IPAddress) {
                        $gwAddr = $c.gateway; $gwLat = $c.gw_ms; $pubIp = $c.public_ip; $probeVal = $c.probe_ms
                        break
                    }
                }
            }
            $connCount = 0
            if ($estabMap.ContainsKey($ipa.IPAddress)) { $connCount = $estabMap[$ipa.IPAddress] }
            $linkItems += [ordered]@{
                name = $ad.Name; ip = $ipa.IPAddress; gateway = $gwAddr; gw_ms = $gwLat
                probe_ms = $probeVal; public_ip = $pubIp; conns = $connCount; default = [bool]$rt
            }
        }
        if ($reProbe) { $linkCache = $linkItems; $linkCacheAge = 0 }

        # serialise the link objects (they are cached as dictionaries, not strings)
        $linkJson = @()
        foreach ($l in $linkItems) {
            $linkJson += ('{{"name":{0},"ip":{1},"gateway":{2},"gw_ms":{3},"probe_ms":{4},"public_ip":{5},"conns":{6},"default":{7}}}' -f `
                (JStr $l.name), (JStr $l.ip), (JStr $l.gateway), (JNum $l.gw_ms), (JNum $l.probe_ms),
                (JStr $l.public_ip), (JNum $l.conns), (JBool $l.default))
        }

        # =================== routing feed ===================
        $feedItems = @()
        try {
            $logTail = @(Get-Content -LiteralPath (Join-Path $MihomoDir 'mihomo.log') -Tail 400 -ErrorAction SilentlyContinue)
            foreach ($line in $logTail) {
                if ($line -match '--> ([^:]+):\d+ match (\S+) using (\S+)') {
                    # save the captures FIRST (-match replaces $Matches) and drop the
                    # double quote the log line wraps the target in: AUTO[x]" -> AUTO[x]
                    $fDom = $Matches[1]; $fRule = $Matches[2]; $fOut = "$($Matches[3])".TrimEnd('"')
                    $feedItems += ('{{"domain":{0},"rule":{1},"out":{2}}}' -f (JStr $fDom), (JStr $fRule), (JStr $fOut))
                }
            }
        } catch { }
        if ($feedItems.Count -gt 22) { $feedItems = $feedItems[($feedItems.Count - 22)..($feedItems.Count - 1)] }

        # =================== pills ===================
        $pM = 'bad'; if ($miState -eq 'ok') { $pM = 'ok' }
        $pSS = 'bad'
        if ($miNativeAlive) { $pSS = 'ok' } elseif ($listenMap.ContainsKey('443')) { $pSS = 'warn' }

        $sw.Stop()
        $buildMs = $sw.ElapsedMilliseconds

        # =================== assemble ===================
        $grpItems = @()
        for ($gi = 0; $gi -lt $grpNames.Count; $gi++) {
            $grpItems += ('{{"name":{0},"type":{1},"now":{2},"members":{3},"order":{4}}}' -f `
                (JStr $grpNames[$gi]), (JStr $grpTypes[$gi]), (JStr $grpNow[$gi]), (JNum $grpCounts[$gi]), (JStr $grpOrders[$gi]))
        }

        $adapterItems = @()
        foreach ($adp in $hypoAdapters) { $adapterItems += (JStr $adp) }

        # route accounting: biggest bucket first, name breaks ties so the file is stable
        $routeItems = @()
        foreach ($rv in ($routeAgg.GetEnumerator() | Sort-Object -Property @{ Expression = { $_.Value.count }; Descending = $true }, @{ Expression = { $_.Key } })) {
            $routeItems += ('{{"name":{0},"kind":{1},"count":{2},"basis":"chain-based"}}' -f (JStr $rv.Key), (JStr $rv.Value.kind), (JNum $rv.Value.count))
        }
        $routeJson = '[' + ($routeItems -join ',') + ']'

        $sshPidVal = 0
        if ($sshProc) { $sshPidVal = $sshProc.Id }

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('{"schema_version":1,"producer":"NetDashCollector",')
        [void]$sb.Append('"observed_at":' + (JStr $observedAt) + ',')
        [void]$sb.Append('"updated":' + (JStr $now) + ',')
        [void]$sb.Append('"host":' + (JStr "$env:COMPUTERNAME") + ',')
        [void]$sb.Append('"build_ms":' + (JNum $buildMs) + ',')
        [void]$sb.Append('"error":' + (JStr $errMsg) + ',')
        [void]$sb.Append('"mihomo":{"state":' + (JStr $miState) + ',"version":' + (JStr $miVersion) +
                         ',"uptime":' + (JStr $miUptime) + ',"memory":' + (JStr $miMem) +
                         ',"connections":' + (JNum $miConns) + ',"connections_active":' + (JNum $miConns) +
                         ',"download":' + (JNum $miDown) +
                         ',"upload":' + (JNum $miUp) + ',"native_alive":' + (JBool $miNativeAlive) +
                         ',"routes":' + $routeJson +
                         ',"groups":[' + ($grpItems -join ',') + ']},')
        [void]$sb.Append('"hypomux":{"state":' + (JStr $hState) + ',"service":' + (JStr "$($svcStatus['HypoMuxCore'])") +
                         ',"gui":' + (JBool ([bool]($procCount['hypomux'] -gt 0))) +
                         ',"gui_pid":' + (JNum $procPid['hypomux']) +
                         ',"ports_up":' + (JNum $portsUp) +
                         ',"tun":' + (JBool $hyTunUp) +
                         ',"carrying":' + (JNum $hyCarrying.Carrying) +
                         ',"carried_conns":' + (JNum $hyCarrying.CarriedConnections) +
                         ',"carrying_basis":' + (JStr $hyCarrying.Basis) +
                         ',"chain_expected_conns":' + (JNum $hyCarrying.ExpectedConnections) +
                         ',"chain_expected_basis":' + (JStr $hyCarrying.ExpectedBasis) +
                         ',"dialer_conns":' + (JNum $miDialer) +
                         ',"local_now":' + (JStr $localPick) +
                         ',"memory":' + (JStr "$($procMem['hypomux-engine']) MB") +
                         ',"strategy":' + (JStr $hypoStrategy) +
                         ',"blocked_domain_bypass":' + (JBool $hypoBypass) +
                         ',"adapters":[' + ($adapterItems -join ',') + ']},')
        [void]$sb.Append('"smartdns":{"required":false,"state":' + (JStr $sdState) + ',"service":' + (JStr $sdSvc) +
                         ',"listening":' + (JStr 'retired; DNS owned by mihomo') +
                         ',"memory":' + (JStr 'n/a') +
                         ',"queries":' + (JNum $qTotal) + ',"fail_pct":' + (JNum $qFailPct) +
                         ',"hit_ms":' + (JNum $hitMs) + ',"miss_ms":' + (JNum $missMs) +
                         ',"top":' + $topJson + '},')
        [void]$sb.Append('"tunnel":{"state":' + (JStr $tnState) + ',"task":' + (JStr "$($taskStatus['AliyunTunnel'])") +
                         ',"port":' + (JBool $has1080) +
                         ',"pid":' + (JNum $sshPidVal) +
                         ',"uptime":' + (JStr $sshUp) +
                         ',"host":' + (JStr '192.0.2.10 (Los Angeles)') +
                         ',"probe_ok":' + (JBool $probeOk) + ',"probe_code":' + (JStr $probeCode) +
                         ',"probe_ms":' + (JNum $probeMs) + ',"log":' + $tunLogJson + '},')
        [void]$sb.Append('"hotspot":{"state":' + (JStr $hsState) + ',"on":' + (JBool $hsOn) +
                         ',"ssid":' + (JStr $hsSsid) +
                         ',"band":' + (JStr $hsBand) +
                         ',"auth":' + (JStr $hsAuth) +
                         ',"gateway":' + (JStr $hsIp) +
                         ',"max_clients":' + (JNum $hsMax) +
                         ',"client_count":' + (JNum $hsClientCount) +
                         ',"arp_clients":' + (JNum $hsArp) +
                         ',"snapshot_age":' + (JNum $hsAge) +
                         ',"snapshot_fresh":' + (JBool $hsHealth.SnapshotFresh) +
                         ',"ics_ok":' + (JNum $hsHealth.IcsOk) +
                         ',"observed_at":' + (JStr $hsHealth.ObservedAt) +
                         ',"schema_version":' + (JNum $hsHealth.SchemaVersion) +
                         ',"producer":' + (JStr $hsHealth.Producer) +
                         ',"band_source":' + (JStr $hsHealth.BandSource) +
                         ',"enabled":' + (JNum $hsHealth.Enabled) +
                         ',"restart_pending":' + (JNum $hsHealth.RestartPending) +
                         ',"task":' + (JStr "$($taskStatus['MobileHotspot'])") +
                         ',"refresh_task":' + (JStr "$($taskStatus['MobileHotspotStatus'])") +
                         ',"clients":' + $hsJsonClients + '},')
        [void]$sb.Append('"links":[' + ($linkJson -join ',') + '],')
        [void]$sb.Append('"feed":[' + ($feedItems -join ',') + '],')
        [void]$sb.Append('"pills":[{"name":"mihomo","state":' + (JStr $pM) + '},' +
                         '{"name":"hypomux","state":' + (JStr $hState) + '},' +
                         '{"name":"ss-native","state":' + (JStr $pSS) + '},' +
                         '{"name":"ssh-tunnel","state":' + (JStr $tnState) + '},' +
                         '{"name":"hotspot","state":' + (JStr $hsState) + '}]')
        [void]$sb.Append('}')

        # Parse only our primitive-built JSON into plain data before handing it
        # to the shared same-directory Replace/Move publisher. No decorated
        # Windows/.NET objects reach ConvertTo-Json in Write-AtomicJson.
        $snapshot = $sb.ToString() | ConvertFrom-Json -ErrorAction Stop
        Write-AtomicJson -Path $StatusFile -Value $snapshot -Depth 8
    } catch {
        Write-CLog "COLLECTOR ERROR: $($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)"
    }

    Start-Sleep -Seconds $RefreshSec
}
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
