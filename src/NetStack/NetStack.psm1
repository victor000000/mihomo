<#
.SYNOPSIS
    NetStack - pure, testable helpers for the network stack dashboard.

.DESCRIPTION
    Everything in this module is deliberately PURE: it takes strings/objects in
    and returns plain data out. No WMI, no registry, no network, no file system.
    That is what makes the logic unit-testable, and it is where the bugs were.

    WHY THE JSON HELPERS EXIST
    --------------------------
    PowerShell 5.1's ConvertTo-Json is unusable for this workload:
      * Windows cmdlets return rich .NET objects (ServiceController, PSProvider,
        ErrorRecord). ConvertTo-Json expands them into megabytes of reflection
        metadata - status.json once reached 6.6 MB.
      * On some of that data it does not merely fail, it hangs forever, which
        took down the whole /api/status endpoint.
    So JSON is emitted by hand through these three primitives.

    WHY THE PARSERS EXIST
    ---------------------
    Parsing netstat / SmartDNS CSV / mihomo logs is where the subtle bugs were:
      * `$localEp -match ':(\d+)$'` REPLACES $Matches, destroying the outer
        capture group that was still needed (this silently broke UDP-53
        detection, so SmartDNS always showed as down).
      * The schtasks /fo LIST output is LOCALIZED, so a "Status:" regex never
        matched when running as SYSTEM.
    Isolating them here makes each case explicit and covered by a test.
#>

Set-StrictMode -Version Latest

# ===========================================================================
#  JSON primitives
# ===========================================================================

<#
.SYNOPSIS
    Escape a value as a JSON string literal.
.OUTPUTS
    A double-quoted, escaped JSON string. $null becomes "".
#>
function ConvertTo-NSJsonString {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)] $Value)

    if ($null -eq $Value) { return '""' }
    $s = [string]$Value
    # backslash first, otherwise the escapes added below get double-escaped
    $s = $s -replace '\\', '\\'
    $s = $s -replace '"', '\"'
    $s = $s -replace "`r", ' '
    $s = $s -replace "`n", ' '
    $s = $s -replace "`t", ' '
    return '"' + $s + '"'
}

<#
.SYNOPSIS
    Render a value as a JSON number, or 'null' when it is not numeric.
.DESCRIPTION
    Booleans are handled here as well so callers can pass anything through.
    Non-numeric strings (e.g. 'n/a') become null rather than producing invalid
    JSON, which is important because a malformed status.json breaks the page.
#>
function ConvertTo-NSJsonNumber {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)] $Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    $d = 0.0
    if ([double]::TryParse([string]$Value, [ref]$d)) {
        # invariant culture so a comma-decimal locale cannot emit "1,5"
        return $d.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    return 'null'
}

<#
.SYNOPSIS
    Render a value as a JSON boolean.
#>
function ConvertTo-NSJsonBool {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)] $Value)
    if ($Value) { return 'true' } else { return 'false' }
}

<#
.SYNOPSIS
    Build a JSON object from an ordered dictionary of already-rendered fragments.
.DESCRIPTION
    Values must be pre-rendered JSON (use the ConvertTo-NSJson* helpers). This
    keeps ordering stable, which matters because the web UI shows fields in
    document order.
#>
function ConvertTo-NSJsonObject {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)] [System.Collections.IDictionary] $Members)

    $parts = @()
    foreach ($k in $Members.Keys) {
        $v = $Members[$k]
        if ($null -eq $v) { $v = 'null' }
        $parts += ('"{0}":{1}' -f $k, $v)
    }
    return '{' + ($parts -join ',') + '}'
}

# ===========================================================================
#  netstat parsing
# ===========================================================================

<#
.SYNOPSIS
    Parse `netstat -ano` output into listening ports and per-IP connection counts.
.DESCRIPTION
    Replaces Get-NetTCPConnection, which took ~3.8 s PER CALL on this machine
    (2300+ sockets) and made /api/status time out. netstat -ano takes ~47 ms.

    Returned shape:
        @{
            Listen      = @{ '53' = 'UDP'; '7897' = 'TCP'; ... }   # string keys
            Established = @{ '192.168.1.100' = 38; ... }           # local IP -> count
        }

    Port keys are STRINGS on purpose: ConvertTo-Json in PS 5.1 cannot serialise
    a hashtable with integer keys.

    NOTE: capture groups are copied into locals before any further -match,
    because -match overwrites the automatic $Matches variable. That exact
    mistake previously broke UDP-53 detection.
#>
function ConvertFrom-NetstatOutput {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)] [AllowNull()] [string[]] $Lines)

    $listen = @{}
    $estab = @{}
    if ($null -eq $Lines) { return @{ Listen = $listen; Established = $estab } }

    $re = '^\s*(TCP|UDP)\s+(\S+)\s+(\S+)\s*(LISTENING|ESTABLISHED|TIME_WAIT|CLOSE_WAIT|SYN_SENT|FIN_WAIT_1|FIN_WAIT_2|LAST_ACK|CLOSING|DELETE_TCB|SYN_RECEIVED)?\s*(\d+)?\s*$'

    foreach ($line in $Lines) {
        $m = [regex]::Match($line, $re)
        if (-not $m.Success) { continue }

        $proto   = $m.Groups[1].Value
        $localEp = $m.Groups[2].Value
        $foreign = $m.Groups[3].Value
        $state   = $m.Groups[4].Value

        $portMatch = [regex]::Match($localEp, ':(\d+)$')
        if ($portMatch.Success) {
            $port = $portMatch.Groups[1].Value
            if ($state -eq 'LISTENING') {
                $listen[$port] = $proto
            }
            elseif ($proto -eq 'UDP' -and $foreign -eq '*:*') {
                # a bound UDP socket is reported with no state and foreign *:*
                $listen[$port] = $proto
            }
        }

        if ($state -eq 'ESTABLISHED') {
            $ipMatch = [regex]::Match($localEp, '^(\d+\.\d+\.\d+\.\d+):')
            if ($ipMatch.Success) {
                $ip = $ipMatch.Groups[1].Value
                if ($estab.ContainsKey($ip)) { $estab[$ip] = $estab[$ip] + 1 } else { $estab[$ip] = 1 }
            }
        }
    }

    return @{ Listen = $listen; Established = $estab }
}


<#
.SYNOPSIS
    Split one CSV record, honouring double-quoted fields.
#>
function Split-CsvLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    # NOTE: the parameter is deliberately untyped. With `[string] $Line`, passing
# $null casts it to '' BEFORE the guard below runs, so "no record" and "one
# empty field" became indistinguishable.
    param([Parameter(Position = 0)] [AllowNull()] $Line)

    if ($null -eq $Line) { return ,@() }
    $Line = [string]$Line
    $out = New-Object System.Collections.Generic.List[string]
    $sb = New-Object System.Text.StringBuilder
    $inQuotes = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($c -eq '"') {
            if ($inQuotes -and ($i + 1) -lt $Line.Length -and $Line[$i + 1] -eq '"') {
                [void]$sb.Append('"'); $i++
            } else {
                $inQuotes = -not $inQuotes
            }
        }
        elseif ($c -eq ',' -and -not $inQuotes) {
            $out.Add($sb.ToString()); [void]$sb.Clear()
        }
        else { [void]$sb.Append($c) }
    }
    $out.Add($sb.ToString())
    return ,$out.ToArray()
}

# ===========================================================================
#  mihomo log parsing
# ===========================================================================

<#
.SYNOPSIS
    Extract the routing decision from one mihomo log line.
.DESCRIPTION
    mihomo writes lines such as:
        ... [TCP] 127.0.0.1:59054 --> www.google.com:443 match DomainSuffix(google.com) using AUTO[aliyun-native]
    The outbound field can itself contain a trailing quote, which upstream lines
    carry - trim it so the dashboard does not render `LOCAL[hypomux]"`.
.OUTPUTS
    @{ Domain; Rule; Out } or $null when the line is not a routing decision.
#>
function ConvertFrom-MihomoLogLine {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)] [AllowNull()] [string] $Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }

    $m = [regex]::Match($Line, '-->\s*([^:\s]+):\d+\s+match\s+(\S+)\s+using\s+(\S+)')
    if (-not $m.Success) { return $null }

    $out = $m.Groups[3].Value.Trim().TrimEnd('"').TrimEnd('\')
    return @{
        Domain = $m.Groups[1].Value
        Rule   = $m.Groups[2].Value.TrimEnd('/')
        Out    = $out
    }
}

<#
.SYNOPSIS
    Parse the mihomo health-check history into a simple alive/dead decision.
#>
function Get-MihomoHealth {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)] [AllowNull()] $History,
        [int] $FailThreshold = 0
    )
    $h = @($History)
    if ($h.Count -eq 0) { return @{ Alive = $false; LastDelay = -1; Samples = 0 } }
    $last = $h[-1]
    $delay = -1
    if ($null -ne $last.PSObject.Properties['delay']) { $delay = [int]$last.delay }
    return @{ Alive = ($delay -gt $FailThreshold); LastDelay = $delay; Samples = $h.Count }
}

# ===========================================================================
#  hotspot
# ===========================================================================

<#
.SYNOPSIS
    Decide the hotspot panel state from OS-level facts plus the WinRT snapshot.
.DESCRIPTION
    The collector runs as SYSTEM, where the WinRT tethering API is unavailable,
    so it detects on/off from the Wi-Fi Direct virtual adapter and reads
    SSID/band/client details from a snapshot written in a user session.

    States:
        ok   - hotspot adapter Up plus fresh ICS-positive snapshot
        warn - adapter Up without fresh ICS evidence, or launch task running/ready
        bad  - fresh ICS failure, or no adapter and no task
    A stale snapshot (> MaxSnapshotAgeSec) is reported as stale rather than
    silently presented as current.
#>
function Get-HotspotState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)] [bool]   $AdapterUp,
        [Parameter(Position = 1)] [AllowNull()] $Snapshot,
        [int] $SnapshotAgeSec    = -1,
        [int] $MaxSnapshotAgeSec = 600,
        [AllowNull()] [string] $TaskState,
        [datetimeoffset] $Now = [datetimeoffset]::Now
    )

    $observedAt = [string](Get-SafeProperty $Snapshot 'observed_at' '')
    if ($observedAt) {
        $stamp = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse($observedAt, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref]$stamp)) {
            $SnapshotAgeSec = [int][Math]::Floor(($Now - $stamp).TotalSeconds)
        } else { $SnapshotAgeSec = -1 }
    }
    $fresh = ($null -ne $Snapshot) -and ($SnapshotAgeSec -ge 0) -and ($SnapshotAgeSec -lt $MaxSnapshotAgeSec)
    $ics = Get-SafeProperty $Snapshot 'ics_ok' $null
    if ($ics -isnot [bool]) { $ics = $null }
    $state = 'bad'
    if ($AdapterUp) {
        # An AP adapter alone proves neither internet sharing nor recent user-
        # session telemetry. Never paint broken/stale ICS evidence green.
        $state = 'warn'
        if ($fresh -and $null -ne $ics) {
            $state = if ($ics) { 'ok' } else { 'bad' }
        }
    } elseif ($TaskState -in @('Running', 'Ready')) { $state = 'warn' }

    $ssid = ''; $band = ''; $auth = ''; $maxClients = 0; $clientCount = 0; $clients = @()
    if ($fresh) {
        $ssid = [string](Get-SafeProperty $Snapshot 'ssid' '')
        $band = [string](Get-SafeProperty $Snapshot 'band' '')
        $auth = [string](Get-SafeProperty $Snapshot 'auth' '')
        $maxClients = [int](Get-SafeProperty $Snapshot 'max_clients' 0)
        $clientCount = [int](Get-SafeProperty $Snapshot 'client_count' 0)
        $clients = @(Get-SafeProperty $Snapshot 'clients' @())
    }

    return @{
        State         = $state
        On            = $AdapterUp
        Ssid          = $ssid
        Band          = $band
        Auth          = $auth
        MaxClients    = $maxClients
        ClientCount   = $clientCount
        Clients       = $clients
        SnapshotFresh = $fresh
        SnapshotAge   = $SnapshotAgeSec
        IcsOk         = $ics
        ObservedAt    = $observedAt
        SchemaVersion = Get-SafeProperty $Snapshot 'schema_version' $null
        Producer      = [string](Get-SafeProperty $Snapshot 'producer' '')
        BandSource    = [string](Get-SafeProperty $Snapshot 'band_source' '')
        Enabled       = Get-SafeProperty $Snapshot 'enabled' $null
        RestartPending = Get-SafeProperty $Snapshot 'restart_pending' $null
    }
}

# ===========================================================================
#  mihomo config inspection
# ===========================================================================

<#
.SYNOPSIS
    Extract the `rules:` list from a mihomo/clash YAML config.
.DESCRIPTION
    Hand-rolled rather than using a YAML parser: this project has no external
    dependencies by design, and the rules block is a flat sequence of scalars.
    Quoted and unquoted forms are both accepted, as are trailing comments.
#>
function Get-MihomoRules {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Position = 0)] [AllowNull()] [string] $ConfigText)

    if ([string]::IsNullOrWhiteSpace($ConfigText)) { return @() }
    $rules = New-Object System.Collections.Generic.List[string]
    $inRules = $false
    foreach ($line in ($ConfigText -split "`r?`n")) {
        if ($line -match '^rules:\s*$' -or $line -match '^rules:\s*\[') { $inRules = $true; continue }
        if ($inRules) {
            if ($line -match '^[A-Za-z_]') { break }            # next top-level key
            $t = $line.Trim()
            if (-not $t -or $t.StartsWith('#')) { continue }
            if ($t.StartsWith('-')) {
                $t = $t.Substring(1).Trim()
                $t = $t -replace '\s+#.*$', ''                   # strip trailing comment
                $t = $t.Trim("'").Trim('"').Trim()
                if ($t) { $rules.Add($t) }
            }
        }
    }
    return ,$rules.ToArray()
}

<#
.SYNOPSIS
    Validate a mihomo rule list, returning the problems that would break routing.
.DESCRIPTION
    The loop-protection rules are not optional: mihomo reaches HypoMux at
    127.0.0.1:10800, so if private ranges were routed through LOCAL the outbound
    would re-enter itself. A missing one is a hard error, not a warning.
#>
function Test-MihomoRuleSet {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)] [AllowNull()] [string[]] $Rules)

    $r = @($Rules)
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    if ($r.Count -eq 0) { $errors.Add('no rules found') }

    # 1. must terminate with MATCH
    if ($r.Count -gt 0 -and $r[-1] -notmatch '^MATCH,') {
        $errors.Add("last rule must be MATCH,<group> (found '$($r[-1])')")
    }

    # 2. loop protection
    foreach ($cidr in @('127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')) {
        $hit = @($r | Where-Object { $_ -match ("^IP-CIDR," + [regex]::Escape($cidr) + ",DIRECT") })
        if ($hit.Count -eq 0) { $errors.Add("missing loop-protection rule for $cidr (DIRECT)") }
    }

    # 3. every rule needs at least 2 fields
    $i = 0
    foreach ($rule in $r) {
        $i++
        if ($rule -notmatch ',') { $errors.Add("rule $i has no target: '$rule'"); continue }
        $parts = $rule -split ','
        if ($parts.Count -lt 2) { $errors.Add("rule $i is malformed: '$rule'") }
    }

    # 4. advisories
    $catchAll = @($r | Where-Object { $_ -match '^MATCH,(LOCAL|DIRECT)$' })
    if ($catchAll.Count -gt 0) {
        $warnings.Add('catch-all sends unmatched traffic out direct (NIC-dispatched by HypoMux); domains needing a proxy must be listed explicitly')
    }
    $broad = @($r | Where-Object { $_ -match '^DOMAIN-KEYWORD,' })
    if ($broad.Count -gt 3) {
        $warnings.Add("$($broad.Count) DOMAIN-KEYWORD rules - these are broad and can pull large CDN traffic through the proxy")
    }

    return @{ Ok = ($errors.Count -eq 0); Errors = $errors.ToArray(); Warnings = $warnings.ToArray(); Count = $r.Count }
}

# ===========================================================================
#  Shared connection classification
# ===========================================================================

function Get-ChainRoute {
    <# Leaf-first mihomo chains. Display kind describes the expected dialer;
       TrafficRoute describes internet routing; Bucket describes metered spend.
       These are not proof of TUN traffic. An explicit hypomux <- LOCAL chain
       does observe a legacy SOCKS hop carrying direct internet traffic.
       Exact names avoid AUTO matching MY-AUTO and DIRECT matching DIRECT-LB. #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowNull()][string[]] $Chains)

    $names = @($Chains | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $freeNames = @('aliyun-native', 'aliyun-la', 'aliyun-tokyo', 'omr')
    $proxyGroups = @('HYPOMUX-PATH', 'AUTO', 'MIX', 'HY2LB', 'PAID', 'DATA', 'PROXY',
        'STORE', 'LINGODA-HK', 'LINGODA', 'CHATGPT', 'DEV', 'BENCH')
    $directNames = @('LOCAL', 'DIRECT', 'DISPATCH', 'hypomux')
    $selectors = $proxyGroups + @('DIRECT-LB', 'LOCAL', 'DISPATCH')
    $leaf = if ($names.Count) { $names[0] } else { '' }
    $label = $null
    $paid = $false; $free = $false; $proxy = $false; $direct = $false
    $carried = $false
    foreach ($name in $names) {
        if (-not $label -and $name -in $selectors) { $label = $name }
        if ($name -match '\|[A-Z]{2,5}\d{4}\|AT(?: \[[^\]]+\])?$') { $paid = $true }
        if ($name -in $freeNames -or $name -match '^(BALANCED|LA)-') { $free = $true }
        if ($name -in $proxyGroups -or $name -eq 'hy2-upstream') { $proxy = $true }
        if ($name -in $directNames) { $direct = $true }
        if ($name -in $freeNames -or $name -in @('HYPOMUX-PATH', 'hy2-upstream', 'hypomux')) { $carried = $true }
    }
    $dialer = ($names.Count -eq 1 -and $leaf -eq 'hypomux')
    if ($dialer) { $carried = $false } # own SOCKS session is NOT a carried flow
    if (-not $label) { $label = if ($leaf) { $leaf } else { 'unknown' } }
    $traffic = if ($paid -or $free -or $proxy) { 'proxy' } elseif ($direct) { 'direct' } else { 'other' }
    $bucket = if ($paid) { 'paid' } elseif ($free) { 'free' } elseif ($direct) { 'local' } else { 'other' }
    $kind = 'other'
    if ($carried) { $kind = 'hypomux' }
    elseif ($dialer) { $kind = 'dialer' }
    elseif ($traffic -eq 'proxy' -or $leaf -match '^(aliyun|hy2)-nic\d+$') { $kind = 'proxy' }
    elseif ($traffic -eq 'direct' -or $label -eq 'DIRECT-LB' -or $leaf -match '^direct-nic\d+$') { $kind = 'direct' }
    return @{ label = $label; kind = $kind; carried = $carried; dialer = $dialer;
        LegacyCarried = ($names -contains 'hypomux' -and -not $dialer); TrafficRoute = $traffic; Bucket = $bucket }
}

function Get-HypoMuxCarryingState {
    <# A free-proxy chain names the policy, not the physical egress path. In TUN
       mode only external adapter telemetry could prove actual carrying. An
       explicit legacy SOCKS hop is the sole evidence in /connections itself. #>
    [CmdletBinding()]
    param([bool] $TunUp, [int] $ExpectedConnections = 0, [int] $LegacyConnections = 0)
    $carrying = $false; $count = 0; $basis = 'legacy-socks-hop'
    if ($LegacyConnections -gt 0) { $carrying = $true; $count = $LegacyConnections }
    elseif ($TunUp) { $carrying = $null; $count = $null; $basis = 'unobserved-tun' }
    return @{ Carrying = $carrying; CarriedConnections = $count; Basis = $basis;
        ExpectedConnections = $ExpectedConnections; ExpectedBasis = 'chain-based' }
}

# ===========================================================================
#  misc helpers
# ===========================================================================

<#
.SYNOPSIS
    Accumulate per-route byte counters from mihomo's live connection list.
.DESCRIPTION
    mihomo exposes downloadTotal/uploadTotal for the whole process, and per
    connection byte counts, but NO cumulative per-route figure. That is the one
    number that matters here, because the paid 911 plan has a 50 GB cap - so we
    derive it ourselves.

    Algorithm: keep the last-seen byte count for each connection id. Each poll,
    add the DELTA to the owning route's running total. A connection that
    disappears has already had its final delta counted on the previous poll, so
    nothing is lost. Deltas are clamped at zero because a connection id can be
    reused after a restart.

    $State is mutated in place (hashtables are reference types) and must be
    created once by the caller with New-TrafficState.

    Route classification uses the chain mihomo reports. Under the design of
    record (2026-10-11) proxied traffic rides HYPOMUX-PATH - whose members dial
    through HypoMux - and non-proxied traffic is plain DIRECT:
        HYPOMUX-PATH / aliyun-native / hy2-upstream  -> proxy
        AUTO / MIX / HY2LB / PAID / DATA / PROXY     -> proxy (policy wrappers
                                                        around the same paths)
        LOCAL / DIRECT                               -> direct
        other                                        -> anything else, e.g. a
                                                        manual selector
.OUTPUTS
    A snapshot hashtable: @{ Proxy=@{...}; Direct=@{...}; Other=@{...}; TotalBytes } 
#>
function Update-ConnectionTraffic {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)] [AllowNull()] $Connections,
        [Parameter(Mandatory, Position = 1)] [hashtable] $State
    )

    $live = @{}
    # Live is a snapshot, not a lifetime sample count (review regression).
    $State.Live = @{ proxy = 0; direct = 0; other = 0 }
    foreach ($cn in @($Connections)) {
        if ($null -eq $cn) { continue }
        $id = [string](Get-SafeProperty $cn 'id' '')
        if (-not $id) { continue }

        if ($live.ContainsKey($id)) { continue }
        $route = (Get-ChainRoute -Chains (Get-SafeProperty $cn 'chains' @())).TrafficRoute

        $down = [long](Get-SafeProperty $cn 'download' 0)
        $up   = [long](Get-SafeProperty $cn 'upload'   0)

        $prev = $null
        if ($State.Seen.ContainsKey($id)) { $prev = $State.Seen[$id] }

        if ($null -ne $prev) {
            $dDown = $down - $prev.down
            $dUp   = $up   - $prev.up
            if ($dDown -lt 0) { $dDown = 0 }
            if ($dUp   -lt 0) { $dUp   = 0 }
        } else {
            # first sighting: the connection may already have transferred bytes
            $dDown = $down
            $dUp   = $up
        }

        $State.Totals[$route].down += $dDown
        $State.Totals[$route].up   += $dUp
        $State.Seen[$id] = @{ down = $down; up = $up; route = $route }
        $live[$id] = $true

        # per-route live connection count for this poll
        if (-not $State.Live.ContainsKey($route)) { $State.Live[$route] = 0 }
        $State.Live[$route] = $State.Live[$route] + 1
    }

    # drop connections that are gone so the map cannot grow without bound
    foreach ($k in @($State.Seen.Keys)) {
        if (-not $live.ContainsKey($k)) { $State.Seen.Remove($k) }
    }
    $State.Polls++

    return $State.Totals
}

<#
.SYNOPSIS
    Create the mutable accumulator that Update-ConnectionTraffic expects.
#>
function New-TrafficState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        Seen   = @{}
        Polls  = 0
        Live   = @{}
        Totals = @{
            proxy  = @{ down = [long]0; up = [long]0; label = 'via proxy (AUTO)' }
            direct = @{ down = [long]0; up = [long]0; label = 'direct (LOCAL)' }
            other  = @{ down = [long]0; up = [long]0; label = 'other' }
        }
    }
}

<#
.SYNOPSIS
    Count active connections and top destinations grouped by route.
#>
function Get-ConnectionSummary {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)] [AllowNull()] $Connections,
        [int] $TopCount = 8
    )

    $summary = @{
        Active      = 0
        ProxyActive = 0
        ProxyBytes  = [long]0
        TopProxy    = @()
        TopDirect   = @()
    }

    $proxyHosts = @{}
    $directHosts = @{}
    foreach ($cn in @($Connections)) {
        if ($null -eq $cn) { continue }
        $summary.Active++
        $route = (Get-ChainRoute -Chains (Get-SafeProperty $cn 'chains' @())).TrafficRoute
        $md = Get-SafeProperty $cn 'metadata' $null
        $hostName = [string](Get-SafeProperty $md 'host' '')
        if (-not $hostName) { $hostName = [string](Get-SafeProperty $md 'destinationIP' '') }
        if (-not $hostName) { $hostName = '(unknown)' }

        if ($route -eq 'proxy') {
            $summary.ProxyActive++
            $summary.ProxyBytes += [long](Get-SafeProperty $cn 'download' 0)
            if ($proxyHosts.ContainsKey($hostName)) { $proxyHosts[$hostName]++ } else { $proxyHosts[$hostName] = 1 }
        }
        elseif ($route -eq 'direct') {
            if ($directHosts.ContainsKey($hostName)) { $directHosts[$hostName]++ } else { $directHosts[$hostName] = 1 }
        }
    }

    $top = @()
    foreach ($e in ($proxyHosts.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First $TopCount)) {
        $top += @{ Name = $e.Key; Count = $e.Value }
    }
    $summary.TopProxy = $top

    $topD = @()
    foreach ($e in ($directHosts.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First $TopCount)) {
        $topD += @{ Name = $e.Key; Count = $e.Value }
    }
    $summary.TopDirect = $topD

    return $summary
}

<#
.SYNOPSIS
    Format a byte count as a human-readable string.
#>
function Format-NSBytes {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)] [AllowNull()] $Bytes)
    if ($null -eq $Bytes) { return '0 B' }
    $b = [double]$Bytes
    if ($b -lt 1024) { return ('{0} B' -f [int]$b) }
    if ($b -lt 1048576) { return ('{0:N1} KB' -f ($b / 1024)) }
    if ($b -lt 1073741824) { return ('{0:N1} MB' -f ($b / 1048576)) }
    return ('{0:N2} GB' -f ($b / 1073741824))
}

<#
.SYNOPSIS
    Extract domains whose connections FAILED, grouped by which route failed.
.DESCRIPTION
    mihomo's `fallback` groups choose a proxy from periodic health checks, not
    from per-connection outcomes. So if the free Aliyun proxy passes a health
    check but then times out on one particular site, every request to that site
    keeps failing - mihomo never demotes the proxy for that destination.

    Observed on this machine (mihomo.log), 152 repetitions while AUTO stayed
    pinned to aliyun-native:
        [TCP] dial AUTO (match DomainSuffix/yahoo.com) ... --> query2.finance.yahoo.com:443
          error: 192.0.2.10:443 connect error: context deadline exceeded

    This function turns those lines into the data needed to fix it:
        route 'direct' (LOCAL/DIRECT failed) -> that domain needs a proxy
        route 'proxy'  (AUTO failed)         -> that domain needs the PAID nodes

    IP literals are skipped: rules match names, so an IP entry would be useless.
.OUTPUTS
    Array of @{ Domain; Route; Error; Count }, most frequent first.
#>
function Get-FailedRouteCandidate {
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Position = 0)] [AllowNull()] [string[]] $Lines,
        [int] $MinHits = 1,
        [int] $SinceMinutes = 30,
        [datetimeoffset] $Now = [datetimeoffset]::Now
    )

    $seen = @{}
    if ($null -eq $Lines) { return @() }

    $re = 'dial\s+(\S+)\s+\(match\s+([^)]*)\)\s+\S+\s+-->\s+([^:\s]+):(\d+)\s+error:\s*(.+?)"?\s*$'
    $cutoff = $Now.AddMinutes(-$SinceMinutes)

    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch 'error:') { continue }

        # mihomo prefixes every line with time="2026-10-10T21:27:59.297711+08:00".
        # Without this filter the learner re-learns already-fixed problems: it
        # kept proposing docker.com from entries logged BEFORE that rule was
        # added, which would have been pure churn.
        $tm = [regex]::Match($line, 'time="([^"]+)"')
        if ($tm.Success) {
            # Compare instants, not offset-stripped wall-clock DateTimes. The
            # latter passed on UTC+8 but dropped recent log entries in UTC CI.
            $ts = [datetimeoffset]::MinValue
            if ([datetimeoffset]::TryParse($tm.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::None, [ref]$ts)) {
                if ($ts -lt $cutoff) { continue }
            }
        }
        $m = [regex]::Match($line, $re)
        if (-not $m.Success) { continue }

        $group    = $m.Groups[1].Value
        $hostName = $m.Groups[3].Value
        $errMsg   = $m.Groups[5].Value.Trim()

        if ($hostName -match '^\d+\.\d+\.\d+\.\d+$') { continue }
        if ($hostName -match '^\[?[0-9a-fA-F:]+\]?$') { continue }
        if ([string]::IsNullOrWhiteSpace($hostName)) { continue }

        $route = 'other'
        # DISPATCH belongs in the DIRECT family. It IS this design's direct path
        # (`MATCH,DISPATCH` is the catch-all, and DISPATCH = fallback [hypomux, DIRECT]),
        # so a destination that fails through it has failed the direct route and needs
        # the same treatment as one that failed under LOCAL/DIRECT.
        #
        # It was missing here until 2026-10-12, and the cost was measured: of 269 LOCAL
        # and 182 DISPATCH failed dials in one log tail, only the LOCAL half was ever
        # considered - `api.deepseek.com` x50, `www.msftncsi.com` x7 and
        # `cdn-cookieyes.com` x6 all sat in the DISPATCH bucket, labelled 'other' and
        # dropped. cdn-cookieyes.com is the proof it matters: it was found and fixed by
        # hand on 2026-10-12, and the learner could not have proposed it.
        #
        # PAID and DATA are NOT the "free proxy failed" route. Both dial paid 911
        # exits only (DATA's filter is 香港|新加坡|日本|德国 over the same provider),
        # so a failure there cannot be fixed by learning "use PAID" - it IS the paid
        # path. Counting it as 'proxy' created a self-sustaining loop: once a domain
        # was escalated, every failed PAID retry refreshed the rule that caused the
        # retry, so the entry never aged out. Measured 2026-10-18: the learner's own
        # DNS resolvers, dns.alidns.com and doh.pub, sat in that bucket with 25,203
        # and 24,690 hits while mihomo's DoH was dialled through an Australian 911
        # node and failed. Route 'paid' is deliberately ignored by
        # Update-AutoLearnState: there is no higher tier to escalate to.
        if ($group -match '^(LOCAL|DIRECT|DISPATCH)$') { $route = 'direct' }
        elseif ($group -match '^(AUTO|PROXY)$') { $route = 'proxy' }
        elseif ($group -match '^(PAID|DATA)$') { $route = 'paid' }

        $key = "$route|$hostName"
        if ($seen.ContainsKey($key)) { $seen[$key].Count++ }
        else { $seen[$key] = @{ Domain = $hostName; Route = $route; Error = $errMsg; Count = 1 } }
    }

# Sort-Object -Property Count does NOT read the 'Count' KEY of a hashtable -
    # it reads the intrinsic Count property (the number of keys, 4 here), so
    # every element compared equal and the order was arbitrary. A script block
    # forces real key lookup.
    return @($seen.Values | Where-Object { $_.Count -ge $MinHits } |
             Sort-Object -Property { $_.Count } -Descending)
}

<#
.SYNOPSIS
    Reduce a hostname to the registrable suffix used by a DOMAIN-SUFFIX rule.
.DESCRIPTION
    Rules match on suffix, so learning 'query2.finance.yahoo.com' on its own
    would need one rule per hostname. Collapsing to 'yahoo.com' fixes every
    sibling host at once - which is what "this site is unusable" actually means.

    Deliberately simple (last two labels) with a small table for the two-label
    public suffixes seen in this deployment. It is NOT a full Public Suffix List
    implementation and does not pretend to be one.
#>
function Get-RegistrableDomain {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)] [AllowNull()] [string] $HostName)

    if ([string]::IsNullOrWhiteSpace($HostName)) { return '' }
    $h = $HostName.Trim().TrimEnd('.').ToLowerInvariant()
    if ($h -match '^\d+\.\d+\.\d+\.\d+$') { return '' }
    if ($h -notmatch '\.') { return '' }

    $labels = $h -split '\.'
    if ($labels.Count -le 2) { return $h }

    $twoLevel = @('com.cn', 'net.cn', 'org.cn', 'gov.cn', 'edu.cn', 'co.uk',
                  'org.uk', 'co.jp', 'com.au', 'co.kr', 'com.hk', 'com.tw',
                  'com.sg', 'co.nz', 'com.br')
    $lastTwo = ($labels[-2..-1] -join '.')
    if ($twoLevel -contains $lastTwo) {
        if ($labels.Count -lt 3) { return $h }
        return ($labels[-3..-1] -join '.')
    }
    return $lastTwo
}

<#
.SYNOPSIS
    Extract the registrable domains of the DNS servers a mihomo config uses.
.DESCRIPTION
    The auto-learner must never write a rule for the stack's own resolver
    endpoints. With `respect-rules: true`, mihomo dials its DoH servers through
    the same rules as any other connection; a learned rule that sends
    dns.alidns.com to PAID makes DNS depend on the paid nodes, and a failing
    PAID dial then looks like "the free proxy failed", which is how the rule
    kept refreshing itself. Measured 2026-10-18: alidns.com and doh.pub sat in
    the paid bucket with 25,203 and 24,690 hits while DoH was routed through
    Australia and failed.

    Only list entries inside the `dns:` block are considered, so routing
    destinations that merely look like hostnames (nameserver-policy keys such
    as "domain:dukascopy.com") are not misread as resolvers. IP literals are
    skipped: a rule cannot match them, and they are bootstrap servers.
.OUTPUTS
    Array of registrable domains, e.g. @('alidns.com', 'doh.pub').
#>
function Get-DnsResolverDomains {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Position = 0)] [AllowNull()] [AllowEmptyString()] [string] $ConfigText)

    if ([string]::IsNullOrWhiteSpace($ConfigText)) { return @() }
    $section = [regex]::Match($ConfigText, '(?ms)^dns:[ \t]*\r?\n(.*?)(?=^[A-Za-z][A-Za-z0-9_-]*:|\z)')
    if (-not $section.Success) { return @() }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($section.Groups[1].Value, '(?m)^\s*-\s*(.+?)\s*$')) {
        $value = $m.Groups[1].Value.Trim().Trim("'").Trim('"')
        $hostName = $value
        if ($hostName -match '^[A-Za-z][A-Za-z0-9+.-]*://') {
            try { $hostName = ([Uri]$hostName).Host } catch { continue }
        } else {
            # bare host or host:port; IPv6 literals are bracketed
            $hostName = $hostName -replace '^\[([^\]]+)\].*$', '$1'
            if ($hostName -match '^([^:]+):\d+$') { $hostName = $Matches[1] }
        }
        $hostName = $hostName.Trim().TrimEnd('.')
        if ([string]::IsNullOrWhiteSpace($hostName)) { continue }
        if ($hostName -match '^\d{1,3}(\.\d{1,3}){3}$') { continue }
        if ($hostName.Contains(':')) { continue }            # IPv6 literal
        $rd = Get-RegistrableDomain $hostName
        if ($rd -and -not $out.Contains($rd)) { $out.Add($rd) }
    }
    return $out.ToArray()
}

<#
.SYNOPSIS
    Read a mihomo rule-provider payload file (behaviour: domain).
.OUTPUTS
    Array of domain strings.
#>
function Get-RuleProviderPayload {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Position = 0)] [AllowNull()] [string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $out = New-Object System.Collections.Generic.List[string]
    $inPayload = $false
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^payload:\s*(\[\s*\]\s*)?$') { $inPayload = $true; continue }
        if (-not $inPayload) { continue }
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t -notmatch '^-\s') { continue }
        $v = $t.Substring(1).Trim().Trim("'").Trim('"')
        # classical payloads carry a rule-type prefix; strip it so a
        # read -> write round-trip through this module is lossless
        $v = $v -replace '^DOMAIN-SUFFIX,', ''
        $v = $v -replace '^DOMAIN,', ''
        if ($v) { $out.Add($v) }
    }
    return ,$out.ToArray()
}

<#
.SYNOPSIS
    Render a domain list as a rule-provider payload file.
#>
function ConvertTo-RuleProviderPayload {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)] [AllowNull()] [string[]] $Domains,
        [string] $Header = '',
        [string] $RulePrefix = 'DOMAIN-SUFFIX,'
    )

    $sb = New-Object System.Text.StringBuilder
    if ($Header) {
        foreach ($l in ($Header -split "`r?`n")) { [void]$sb.AppendLine("# $l") }
    }
    $list = @($Domains | Where-Object { $_ } | Sort-Object -Unique)
    [void]$sb.AppendLine('payload:')
    if ($list.Count -eq 0) { [void]$sb.AppendLine('  []') }
    else { foreach ($d in $list) { [void]$sb.AppendLine("  - '$RulePrefix$d'") } }
    return $sb.ToString()
}

<#
.SYNOPSIS
    Merge newly observed failures into the auto-learn state, with pruning.
.DESCRIPTION
    The learned rule set must not grow without bound, and a domain that failed
    once during a momentary blip should not be pinned through the paid proxy
    forever. So each entry carries first/last-seen timestamps and a hit count:

      * re-seeing a domain refreshes LastSeen and increments Hits
      * entries older than TtlDays are dropped
      * if still over MaxPerRoute, the oldest are dropped
      * a domain already handled by an explicit manual rule is never learned,
        so the learner cannot fight the hand-written rules

    $State is mutated in place:
        @{ direct = @{ '<domain>' = @{First;Last;Hits} }; paid = @{ ... } }
.OUTPUTS
    @{ Added; Refreshed; Pruned; DirectCount; PaidCount }
#>
function Update-AutoLearnState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)] [hashtable] $State,
        [Parameter(Position = 1)] [AllowNull()] $Candidates,
        [string[]] $ManualDomains = @(),
        # Domestic filtering lives HERE, not in the calling script, so the
        # safety rule holds wherever this function is used and is covered by a
        # unit test. A CI dry run that called this directly while the filtering
        # sat in the script happily learned qq.com.
        [string[]] $DomesticSuffixes = @(),
        [string[]] $DomesticSet = @(),
        [int] $MaxPerRoute = 250,
        [int] $TtlDays = 30,
        [datetime] $Now = (Get-Date),
        [int] $MinHits = 2
    )

    foreach ($k in @('direct', 'paid')) {
        if (-not $State.ContainsKey($k)) { $State[$k] = @{} }
    }

    $added = 0; $refreshed = 0; $skippedDomestic = 0
    $manual = @{}
    foreach ($d in @($ManualDomains)) {
        if ($d) { $manual[$d.ToLowerInvariant()] = $true }
    }

    foreach ($c in @($Candidates)) {
        if ($null -eq $c) { continue }
        if ($c.Route -notin @('direct', 'proxy')) { continue }
        if ($c.Count -lt $MinHits) { continue }

        $domain = Get-RegistrableDomain $c.Domain
        if (-not $domain) { continue }
        if ($manual.ContainsKey($domain)) { continue }

        # NEVER proxy a domestic endpoint, however often it times out.
        if (Test-DomesticDomain -Domain $domain -DomesticSuffixes $DomesticSuffixes -DomesticSet $DomesticSet) {
            $skippedDomestic++
            continue
        }

        $bucket = 'direct'
        if ($c.Route -eq 'proxy') { $bucket = 'paid' }

        # Escalation is ONE-WAY: PAID is the stricter route, so a proxy-route
        # failure promotes a domain out of the direct bucket. It must never be
        # demoted by a direct-route candidate processed later. Candidates arrive
        # sorted by failure count DESC, so the old unconditional move let the
        # LESS frequent route win the last write: verified 2026-10-18, a domain
        # with a proxy candidate x50 followed by a direct candidate x6 ended up
        # in the direct bucket (AUTO) - the path that had just failed 50 times.
        if ($bucket -eq 'paid') {
            if ($State['direct'].ContainsKey($domain)) { $State['direct'].Remove($domain) }
        } elseif ($State['paid'].ContainsKey($domain)) {
            # Already escalated, and the direct path is still failing - which is
            # why it was escalated. Keep the entry alive; do not move it back.
            $State['paid'][$domain].Last = $Now
            $refreshed++
            continue
        }

        if ($State[$bucket].ContainsKey($domain)) {
            $State[$bucket][$domain].Last = $Now
            $State[$bucket][$domain].Hits = [int]$State[$bucket][$domain].Hits + [int]$c.Count
            $refreshed++
        } else {
            $State[$bucket][$domain] = @{ First = $Now; Last = $Now; Hits = [int]$c.Count }
            $added++
        }
    }

    # prune by age, then by size
    $pruned = 0
    foreach ($bucket in @('direct', 'paid')) {
        $cutoff = $Now.AddDays(-$TtlDays)
        foreach ($d in @($State[$bucket].Keys)) {
            if ($State[$bucket][$d].Last -lt $cutoff) { $State[$bucket].Remove($d); $pruned++ }
        }
        if ($State[$bucket].Count -gt $MaxPerRoute) {
            $ordered = @($State[$bucket].GetEnumerator() | Sort-Object { $_.Value.Last })
            $drop = $State[$bucket].Count - $MaxPerRoute
            for ($i = 0; $i -lt $drop; $i++) {
                $State[$bucket].Remove($ordered[$i].Key); $pruned++
            }
        }
    }

    return @{
        Added           = $added
        Refreshed       = $refreshed
        Pruned          = $pruned
        SkippedDomestic = $skippedDomestic
        DirectCount     = $State['direct'].Count
        PaidCount       = $State['paid'].Count
    }
}

<#
.SYNOPSIS
    Remove learned rules for the stack's own resolver domains.
.DESCRIPTION
    Additive learning alone cannot undo an entry once the guard that should
    have rejected it was missing: TTL pruning keeps it for 30 days after its
    last refresh, and a self-refreshing entry never reaches that age. The
    resolver endpoints are not a routing preference, though - they are
    infrastructure - so any entry naming one is removed outright.
.OUTPUTS
    The domain names that were removed.
#>
function Remove-LearnedResolverDomains {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)] [hashtable] $State,
        [Parameter(Position = 1)] [AllowNull()] [string[]] $ResolverDomains
    )

    $removed = New-Object System.Collections.Generic.List[string]
    $wanted = @{}
    foreach ($d in @($ResolverDomains)) {
        if ($d) { $wanted[$d.ToLowerInvariant()] = $true }
    }
    if ($wanted.Count -eq 0) { return $removed.ToArray() }

    foreach ($bucket in @('direct', 'paid')) {
        if (-not $State.ContainsKey($bucket)) { continue }
        foreach ($d in @($State[$bucket].Keys)) {
            if ($wanted.ContainsKey($d.ToLowerInvariant())) {
                $State[$bucket].Remove($d)
                $removed.Add($d)
            }
        }
    }
    return $removed.ToArray()
}

<#
.SYNOPSIS
    Decide whether a domain is domestic (Chinese) and must never be proxied.
.DESCRIPTION
    Without this guard the learner proposed exactly the wrong thing. A 30-minute
    window produced:

        doubao.com      x52   direct failures   <- ByteDance, domestic
        zijieapi.com    x16   direct failures   <- ByteDance, domestic
        qq.com          x13   direct failures   <- Tencent, domestic
        aliyuncs.com     x6   direct failures   <- Alibaba Cloud, domestic
        aliyun.com       x2   direct failures   <- Alibaba Cloud, domestic

    Those are background/telemetry endpoints that time out routinely. Routing
    them through a proxy would make them slower AND consume the metered plan, so
    they are excluded by rule rather than by hope.

    Two independent signals:
      * the domain is under .cn
      * it appears in $DomesticSet, built from SmartDNS's own audit log, which
        records the answering upstream group ("Server: china" vs
        "Server: default"). That makes the list self-maintaining instead of a
        hand-curated table that rots.
#>
function Test-DomesticDomain {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)] [AllowNull()] [string] $Domain,
        [string[]] $DomesticSuffixes = @(),
        [string[]] $DomesticSet = @()
    )

    if ([string]::IsNullOrWhiteSpace($Domain)) { return $false }
    $d = $Domain.Trim().TrimEnd('.').ToLowerInvariant()

    if ($d -eq 'cn' -or $d.EndsWith('.cn')) { return $true }

    foreach ($s in $DomesticSuffixes) {
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        $s = $s.Trim().TrimEnd('.').ToLowerInvariant()
        if ($d -eq $s -or $d.EndsWith('.' + $s)) { return $true }
    }
    foreach ($s in $DomesticSet) {
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        $s = $s.Trim().TrimEnd('.').ToLowerInvariant()
        if ($d -eq $s -or $d.EndsWith('.' + $s)) { return $true }
    }
    return $false
}


<#
.SYNOPSIS
    Validate a mihomo proxy-group health-check URL.
.DESCRIPTION
    A fallback/url-test group silently disappears if its probe URL is unusable:
    the group is marked dead, and `fallback` quietly moves to the next entry.
    That is exactly what happened here.

    LOCAL had `url: http://223.5.5.5` - the AliDNS resolver IP. It does not
    serve HTTP on port 80 (it answers 404), so every probe failed, hypomux was
    permanently marked dead, and LOCAL fell through to DIRECT. HypoMux therefore
    carried none of the "everything else" traffic while every dashboard surface
    still looked healthy.

    Rules encoded here:
      * the URL must be http/https with a real host
      * a bare IP literal is rejected - an IP that happens to be famous for
        something else (a DNS resolver) is not an HTTP endpoint
      * a group whose members are all direct-path outbounds (DIRECT, a
        NIC-distributing socks5 such as HypoMux) must NOT be probed against a
        blocked domain: probing a direct path with google.com marks it dead
        forever in mainland China
.OUTPUTS
    @{ Ok; Errors; Warnings }
#>
function Test-HealthCheckUrl {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)] [AllowNull()] [string] $Url,
        # true when the group's members reach the internet DIRECTLY (no proxy)
        [switch] $DirectPathGroup
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($Url)) {
        $errors.Add('health-check URL is empty')
        return @{ Ok = $false; Errors = $errors.ToArray(); Warnings = $warnings.ToArray() }
    }

    $u = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u)) {
        $errors.Add("health-check URL is not absolute: '$Url'")
        return @{ Ok = $false; Errors = $errors.ToArray(); Warnings = $warnings.ToArray() }
    }
    if ($u.Scheme -notin @('http', 'https')) {
        $errors.Add("health-check URL must be http or https, got '$($u.Scheme)'")
    }

    $hostPart = $u.Host
    if ($hostPart -match '^\d+\.\d+\.\d+\.\d+$') {
        $errors.Add("health-check URL uses a bare IP ('$hostPart'). An IP that is famous for " +
                    'something else - e.g. 223.5.5.5 is AliDNS - does not necessarily serve HTTP, ' +
                    'so the probe always fails and the group silently falls back.')
    }

    if ($DirectPathGroup) {
        if ($hostPart -match '(google|youtube|facebook|twitter|openai|wikipedia|github)') {
            $errors.Add("a direct-path group is probed against '$hostPart', which is blocked in " +
                        'mainland China. The probe can never succeed, so the group is marked dead ' +
                        'and HypoMux stops carrying traffic.')
        }
    }

    if ($u.Scheme -eq 'http' -and $u.Port -ne 80 -and $u.Port -ne -1) {
        $warnings.Add("non-standard http port $($u.Port)")
    }

    return @{ Ok = ($errors.Count -eq 0); Errors = $errors.ToArray(); Warnings = $warnings.ToArray() }
}

<#
.SYNOPSIS
    Decide what to do when the set of usable network adapters changes.
.DESCRIPTION
    WHY THIS IS PURE
    ---------------
    The decision logic is separated from the probing so it can be tested against
    synthetic adapter states. Every branch below corresponds to an outage that
    actually happened:

      * A dead NIC sat in HypoMux's pool. Because HypoMux spreads connections
        across its channels, roughly half of all requests failed. The symptom is
        intermittent, which makes it look like a flaky uplink rather than a
        config problem. (Measured: hypomux 000 200 000 200 while direct was
        200 200 200 200.)
      * HypoMux resolved DNS through the address of a NIC that had gone down, so
        remote-DNS requests (socks5h - what mihomo sends) failed outright.
      * SmartDNS binds are written as literal IPs. When DHCP moves a NIC, the
        bind no longer matches and HypoMux cannot reach the resolver at all.

    INPUTS
      $Previous  - adapter names that were usable on the last pass
      $Current   - adapter names that are usable now
      $Pool      - the adapter names HypoMux is currently configured to use
      $DnsServer - the address HypoMux is currently configured to resolve with
      $DnsValid  - whether that address is still bound by SmartDNS

    OUTPUTS
      @{ PoolChanged; NewPool; DnsChanged; NewDnsServer; Appeared; Disappeared; Action }
      Action is one of: 'none', 'update', 'restart'
#>
function Compare-AdapterState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)] [AllowNull()] [string[]] $Previous = @(),
        [Parameter(Position = 1)] [AllowNull()] [string[]] $Current  = @(),
        [ string[]] $Pool = @(),
        [AllowNull()] [string] $DnsServer = '',
        [bool] $DnsValid = $true
    )

    $prev = @($Previous | Where-Object { $_ })
    $cur  = @($Current  | Where-Object { $_ })

    $appeared    = @($cur  | Where-Object { $_ -notin $prev })
    $disappeared = @($prev | Where-Object { $_ -notin $cur })

    # HypoMux must be configured with exactly the usable set. Anything else and
    # it will spread connections onto a NIC that cannot carry them.
    $poolChanged = $false
    if (@($Pool | Sort-Object) -join '|' -ne (@($cur | Sort-Object) -join '|')) { $poolChanged = $true }

    $dnsChanged = $false
    $newDns = $DnsServer
    if (-not $DnsValid -or [string]::IsNullOrWhiteSpace($DnsServer)) {
        $dnsChanged = $true
        if ($cur.Count -gt 0) { $newDns = $cur[0] }   # caller maps name -> address
    }

    $action = 'none'
    if ($disappeared.Count -gt 0) { $action = 'restart' }   # a bad NIC is live in the pool
    elseif ($poolChanged -or $dnsChanged) { $action = 'update' }
    elseif ($appeared.Count -gt 0) { $action = 'update' }

    return @{
        Action       = $action
        PoolChanged  = $poolChanged
        NewPool      = $cur
        DnsChanged   = $dnsChanged
        NewDnsServer = $newDns
        Appeared     = $appeared
        Disappeared  = $disappeared
        UsableCount  = $cur.Count
    }
}

<#
.SYNOPSIS
    Pick a HypoMux DNS address that SmartDNS is actually listening on.
.DESCRIPTION
    SmartDNS binds literal addresses (127.0.0.1, the NIC IPs, 0.0.0.0). HypoMux
    source-binds to a NIC, so it cannot use 127.0.0.1, and it must not be given
    the address of a NIC that has gone down. This picks the first address that
    is both bound by SmartDNS and belongs to a usable adapter.
.OUTPUTS
    The chosen address, or '' when none qualifies.
#>
function Select-HypoMuxDnsAddress {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)] [AllowNull()] [string[]] $BoundAddresses = @(),
        [Parameter(Position = 1)] [AllowNull()] [hashtable] $AdapterAddresses = @{}
    )

    $bound = @($BoundAddresses | Where-Object { $_ -and $_ -notin @('0.0.0.0', '::', '127.0.0.1', '::1') })
    if ($bound.Count -eq 0) { return '' }

    # Prefer an address on a NIC we know is usable - over the adapter names SORTED, because a
    # hashtable's key order is not a contract and the two engines do not agree on it. Measured
    # 2026-10-11: the same input (`eth0`=10.0.0.5, `wlan0`=192.168.1.5, both bound) returned
    # 10.0.0.5 under Windows PowerShell 5.1 and 192.168.1.5 under pwsh 7 - the CI matrix caught it,
    # which is exactly what the matrix is for. Sorting makes the choice a property of the data
    # instead of an implementation detail of the runtime.
    foreach ($a in @($AdapterAddresses.Keys | Sort-Object)) {
        if (-not $AdapterAddresses[$a]) { continue }
        if ($bound -contains $AdapterAddresses[$a]) { return $AdapterAddresses[$a] }
    }
    # fall back to any non-loopback bound address
    return $bound[0]
}

<#
.SYNOPSIS
    Read a property from an object without throwing when it is absent.
.DESCRIPTION
    PS 5.1 with Set-StrictMode throws on missing properties; the collector deals
    with loosely-shaped REST payloads from mihomo, so access must be safe.
#>
function Get-SafeProperty {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [AllowNull()] $InputObject,
        [Parameter(Position = 1)] [string] $Name,
        [Parameter(Position = 2)] $Default = $null
    )
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name) -and $null -ne $InputObject[$Name]) { return ,$InputObject[$Name] }
        return $Default
    }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return ,$p.Value
}

<#
.SYNOPSIS
    Format a TimeSpan as "3h 12m", or 'n/a'.
#>
function Format-NSDuration {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)] [AllowNull()] $Span)
    if ($null -eq $Span -or $Span -isnot [TimeSpan]) { return 'n/a' }
    return ('{0}h {1}m' -f [int]$Span.TotalHours, $Span.Minutes)
}

Export-ModuleMember -Function @(
    'ConvertTo-NSJsonString'
    'ConvertTo-NSJsonNumber'
    'ConvertTo-NSJsonBool'
    'ConvertTo-NSJsonObject'
    'ConvertFrom-NetstatOutput'
    'Split-CsvLine'
    'ConvertFrom-MihomoLogLine'
    'Get-MihomoHealth'
    'Get-HotspotState'
    'Get-MihomoRules'
    'Test-MihomoRuleSet'
    'Get-FailedRouteCandidate'
    'Get-RegistrableDomain'
    'Get-DnsResolverDomains'
    'Get-RuleProviderPayload'
    'ConvertTo-RuleProviderPayload'
    'Update-AutoLearnState'
    'Remove-LearnedResolverDomains'
    'Test-DomesticDomain'
    'Test-HealthCheckUrl'
    'Compare-AdapterState'
    'Select-HypoMuxDnsAddress'
    'Get-ChainRoute'
    'Get-HypoMuxCarryingState'
    'Update-ConnectionTraffic'
    'New-TrafficState'
    'Get-ConnectionSummary'
    'Format-NSBytes'
    'Get-SafeProperty'
    'Format-NSDuration'
)
