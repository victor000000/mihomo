<#
.SYNOPSIS
    Spend attribution for the 4:1 proxy mix: which bytes went over a PAID 911 exit, and which
    went over the free Aliyun path.

.DESCRIPTION
    The owner asked for the 911 exits first with the Aliyun server as a 4:1 minority
    ("for proxy, we can use our 911 connect first and then use the aliyun server proxy (4:1),
    all through hypomux dispatch"), and mihomo cannot weight group members - the ratio IS the
    member count. That makes the RATIO checkable (four filter alternatives + one explicit member,
    asserted in CI and at runtime) but it says nothing about SPEND: a subscription has a quota,
    and "four members out of five" does not tell you how many gigabytes of a metered allowance
    have gone out today.

    mihomo's API gives bytes per CONNECTION and the chain each connection took, but no per-group
    accounting - there is no counter to read, only connections to attribute. So attribution is
    the whole job, and it is pure: chains in, a bucket out. This module does that half, which
    means the interesting cases (a chain that names a paid exit, the free path, a DIRECT hop, an
    unknown node, an empty chain, a chain list with repeats) are unit tested with no live proxy.

    Buckets:
      paid  - the chain contains a 911 subscription exit. Those node names all end in the
              `|<CODE><NNNN>|AT` shape (`香港|HK2022|AT`, `新加坡|SG2034|AT`, `德国|GE2012|AT`).
      free  - the chain contains a free Aliyun/Tokyo/OMR path (`aliyun-native`,
              `aliyun-la`, `aliyun-tokyo`, `omr`): not metered.
      local - the chain ends at `DIRECT` (no proxy at all).
      other - a named node that is neither (a benchmark target, a provider added later): counted
              separately on purpose, because guessing a bucket for it would silently move spend.

.NOTES
    State is a plain PSCustomObject so it round-trips through ConvertTo-Json/ConvertFrom-Json
    without a schema, and every function tolerates a missing or damaged state file: a monitor
    that throws because its own counter is corrupt is worse than no monitor.
#>

Import-Module (Join-Path $PSScriptRoot 'NetStack.psm1')

function Get-FieldValue {
    <#
    .SYNOPSIS
        Reads a field from a sample that may be a hashtable, a dictionary or an object.
    .DESCRIPTION
        The first version read `$s.PSObject.Properties.Name` to test for Upload/Download, which is
        true for a PSCustomObject but NOT for a hashtable: a hashtable's PSObject properties are
        Count/Keys/Values, so every hashtable sample silently contributed ZERO bytes. Nine tests
        caught it at once, which is exactly what they are for - mihomo's JSON gives PSCustomObjects
        while PowerShell callers naturally write hashtables, so both must work.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Object, [Parameter(Mandatory)][string] $Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}
function Get-ChainBucket {
    <#
    .SYNOPSIS
        Classifies one mihomo connection chain as paid, free, local or other.
    .PARAMETER Chain
        The `chains` array of one connection, innermost first (mihomo: the outbound that
        handled it, then the group, then the parent group).
    #>
    [CmdletBinding()]
    param([AllowNull()][string[]] $Chain)

    return (Get-ChainRoute -Chains $Chain).Bucket
}

function New-SpendState {
    <#
    .SYNOPSIS
        A fresh, empty spend state.
    #>
    [CmdletBinding()]
    param([string] $Day = (Get-Date -Format 'yyyy-MM-dd'))

    return [pscustomobject]@{
        Day       = $Day
        PaidBytes = 0
        FreeBytes = 0
        LocalBytes = 0
        OtherBytes = 0
        Connections = 0
        PaidConnections = 0
        ConnectionIds = @{} # distinct IDs seen today, survives JSON round trips
        OpenConnections = @{} # last cumulative counters; NOT reset at midnight
        Updated   = $null
        History   = @()   # one entry per finished day, so a quota question can be answered later
    }
}

function Add-SpendSample {
    <#
    .SYNOPSIS
        Adds one poll's worth of connection bytes to the state, rolling the day over at midnight.
    .DESCRIPTION
        $Samples is a list of objects with Chain (string[]), Upload and Download (byte deltas).
        Optional Id identifies the connection for distinct daily connection counts. Legacy
        samples without Id count once per sample. Each connection is attributed whole to
        one bucket: a chain is one path, not a mixture.
    .PARAMETER State
        The state object (New-SpendState output, or one read back from JSON).
    .PARAMETER Samples
        The connections to add.
    .PARAMETER Day
        The day the samples belong to; when it differs from State.Day the current totals are
        pushed into History and the counters restart.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] $State,
        [AllowNull()][object[]] $Samples,
        [string] $Day = (Get-Date -Format 'yyyy-MM-dd')
    )

    if ($null -eq $State -or -not ($State.PSObject.Properties.Name -contains 'PaidBytes')) {
        $State = New-SpendState -Day $Day
    }
    if ($State.Day -ne $Day) {
        # Day rolled over: keep the finished day, start clean. Only push a day that saw traffic,
        # so a machine left off for a month does not accumulate 30 empty entries.
        if ($State.PaidBytes + $State.FreeBytes + $State.LocalBytes + $State.OtherBytes -gt 0) {
            $State.History = @($State.History) + [pscustomobject]@{
                Day = $State.Day; PaidBytes = $State.PaidBytes; FreeBytes = $State.FreeBytes
                LocalBytes = $State.LocalBytes; OtherBytes = $State.OtherBytes
                Connections = $State.Connections; PaidConnections = $State.PaidConnections
            }
        }
        $fresh = New-SpendState -Day $Day
        $fresh.History = @($State.History)
        # Review regression: losing this baseline at midnight made the NEXT
        # poll re-add the entire lifetime of every connection still open.
        $open = Get-FieldValue $State 'OpenConnections'
        if ($null -ne $open) { $fresh.OpenConnections = $open }
        $State = $fresh
    }
    $ids = @{}
    $savedIds = Get-FieldValue $State 'ConnectionIds'
    if ($savedIds -is [System.Collections.IDictionary]) {
        foreach ($key in $savedIds.Keys) { $ids[$key] = $savedIds[$key] }
    } elseif ($null -ne $savedIds) {
        foreach ($property in $savedIds.PSObject.Properties) { $ids[$property.Name] = $property.Value }
    }
    $State | Add-Member -NotePropertyName ConnectionIds -NotePropertyValue $ids -Force

    foreach ($s in @($Samples)) {
        if ($null -eq $s) { continue }
        $bucket = Get-ChainBucket -Chain (Get-FieldValue -Object $s -Name 'Chain')
        $bytes = 0
        foreach ($p in 'Upload', 'Download') {
            $v = Get-FieldValue -Object $s -Name $p
            if ($v) { $bytes += [int64]$v }
        }
        if ($bytes -lt 0) { $bytes = 0 }
        switch ($bucket) {
            'paid'  { $State.PaidBytes += $bytes }
            'free'  { $State.FreeBytes += $bytes }
            'local' { $State.LocalBytes += $bytes }
            default { $State.OtherBytes += $bytes }
        }
        # Samples are deltas, but the drift gate needs CONNECTIONS, not polls.
        # Legacy callers without Id retain one connection per sample semantics.
        $id = [string](Get-FieldValue $s 'Id')
        if (-not $id -or -not $ids.ContainsKey($id)) {
            $State.Connections++
            if ($bucket -eq 'paid') { $State.PaidConnections++ }
        } elseif ($bucket -eq 'paid' -and $ids[$id] -ne 'paid') {
            $State.PaidConnections++
        }
        if ($id -and (-not $ids.ContainsKey($id) -or $ids[$id] -ne 'paid')) { $ids[$id] = $bucket }
    }
    $State.Updated = (Get-Date).ToString('s')
    return $State
}

function Update-SpendConnections {
    <# Pure cumulative-snapshot adapter used by Get-PaidSpend.ps1. Keeping it here
       makes the actual midnight/delta/JSON behaviour testable without the API.
       The first post-midnight delta belongs to the new day (poll resolution). #>
    [CmdletBinding()]
    param(
        [AllowNull()] $State,
        [AllowNull()][object[]] $Connections,
        [string] $Day = (Get-Date -Format 'yyyy-MM-dd')
    )
    if ($null -eq $State -or $null -eq (Get-FieldValue $State 'PaidBytes')) { $State = New-SpendState -Day $Day }
    $previous = Get-FieldValue $State 'OpenConnections'
    $open = @{}; $samples = @()
    foreach ($connection in @($Connections)) {
        if ($null -eq $connection) { continue }
        $id = [string](Get-FieldValue $connection 'id')
        if (-not $id -or $open.ContainsKey($id)) { continue }
        $total = [int64](Get-FieldValue $connection 'upload') + [int64](Get-FieldValue $connection 'download')
        $last = [int64](Get-FieldValue $previous $id)
        $delta = [Math]::Max([int64]0, ($total - $last))
        $open[$id] = $total
        $samples += [pscustomobject]@{ Id = $id; Chain = @(Get-FieldValue $connection 'chains'); Upload = $delta; Download = 0 }
    }
    $State = Add-SpendSample -State $State -Samples $samples -Day $Day
    $State | Add-Member -NotePropertyName OpenConnections -NotePropertyValue $open -Force
    return $State
}

function Format-SpendReport {
    <#
    .SYNOPSIS
        One line for the reporter: today's split, and whether it matches the 4:1 design.
    .DESCRIPTION
        The design sends the PROXY path 4:1 paid:free, so a mix that has drifted far from ~80%
        paid is worth naming - in either direction. Too much paid can burn a metered allowance;
        too little means the paid exits are failing and traffic is quietly on the free path.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] $State,
        [double] $ExpectedPaidShare = 0.8,
        [double] $Tolerance = 0.15
    )

    if ($null -eq $State) { return [pscustomobject]@{ Summary = 'no spend data yet'; Share = $null; Drift = $false } }
    $paid = [double]$State.PaidBytes; $free = [double]$State.FreeBytes
    $total = $paid + $free + [double]$State.LocalBytes + [double]$State.OtherBytes
    if ($total -le 0) { return [pscustomobject]@{ Summary = 'no traffic yet today'; Share = $null; Drift = $false } }

    # Share is of the PROXIED bytes only: the mix is a statement about proxied traffic, and
    # counting local (DIRECT) bytes in it would make the number fall whenever the machine browsed
    # a domestic site - a measurement artefact, not a routing change.
    $proxied = $paid + $free
    $share = if ($proxied -gt 0) { $paid / $proxied } else { $null }
    $fmt = { param($b) "{0:N1} MB" -f ($b / 1MB) }
    $summary = "today paid $(& $fmt $paid) / free $(& $fmt $free) / direct $(& $fmt ([double]$State.LocalBytes))"
    if ($null -ne $share) {
        $summary += " - {0:N0}% of proxied bytes on the paid exits (design ~{1:N0}%)" -f ($share * 100), ($ExpectedPaidShare * 100)
    }
    $drift = $false
    # Judge only a sample that can carry a ratio. Two gates, both learned the hard way on
    # 2026-10-11: bytes alone are not enough, because a connection keeps the member it was
    # assigned at CONNECT time for its whole life - a handful of large streams (a CDN download)
    # then dominates the byte share and reads as a broken mix. The live proof: 23.9 MB "free"
    # against 0.1 MB "paid" in one window, while 30 fresh connections distributed 24 paid : 7 free
    # - exactly the 4:1 design. So a share needs BOTH enough bytes and enough connections.
    if ($null -ne $share -and $proxied -gt 8MB -and $State.Connections -gt 20) {
        # Only judge a share once there is enough traffic for a ratio to mean anything: 8 MB of
        # proxied bytes. Below that a single large download swings the number by tens of percent.
        if ([Math]::Abs($share - $ExpectedPaidShare) -gt $Tolerance) {
            $drift = $true
            $summary += if ($share -gt $ExpectedPaidShare) { ' - MORE paid than designed: a metered allowance is being spent faster than the mix implies' } else { ' - LESS paid than designed: check that the 911 exits are healthy, traffic may be on the free path' }
        }
    }
    return [pscustomobject]@{ Summary = $summary; Share = $share; Drift = $drift }
}

Export-ModuleMember -Function Get-ChainBucket, New-SpendState, Add-SpendSample, Update-SpendConnections, Format-SpendReport
