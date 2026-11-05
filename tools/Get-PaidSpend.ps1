<#
.SYNOPSIS
    Samples mihomo's connections and attributes their bytes to the paid 911 exits or the free
    Aliyun path, so the 4:1 mix has a spend figure instead of only a member count.

.DESCRIPTION
    Why this exists: the mix is four paid 911 exits against one free Aliyun share, and the owner
    asked for it that way ("use our 911 connect first and then use the aliyun server proxy (4:1)").
    mihomo cannot weight group members, so the ratio IS the member count - which CI and the
    reporter both check. But a member count says nothing about SPEND: a metered subscription has
    a quota, and "four members out of five" does not tell you how many gigabytes left today, nor
    whether the paid exits are quietly failing while traffic rides the free path.

    mihomo's API exposes bytes per CONNECTION plus the chain it took, and no per-group counters,
    so this polls /connections, attributes each connection with src\NetStack\Spend.psm1 (pure and
    unit tested), accumulates into state\paid-spend.json, and prints one line.

    Two subtleties the attribution handles, both measured on 2026-10-11:
      * a connection is attributed WHOLE to one bucket - a chain is one path, not a mixture;
      * DIRECT bytes are counted separately and excluded from the share, otherwise a 500 MB
        domestic download would make the paid share look tiny without anything having changed.

.PARAMETER StatePath
    Where the running totals live. Default: state\paid-spend.json (runtime state, gitignored).

.PARAMETER Json
    Emit the report object as JSON instead of text.

.PARAMETER Reset
    Start the day's counters from zero (keeps History).

.EXAMPLE
    pwsh -File tools\Get-PaidSpend.ps1
    # today paid 412.3 MB / free 98.1 MB / direct 1.9 GB - 81% of proxied bytes on the paid exits (design ~80%)

.NOTES
    Exit codes: 0 always unless -Strict is given, in which case a drifted share exits 1. A monitor
    that fails because the proxy is down would be worse than useless, so a missing API is reported
    as "no data", not as an error.
#>
[CmdletBinding()]
param(
    [string] $StatePath = (Join-Path $PSScriptRoot '..\state\paid-spend.json'),
    [string] $Api = 'http://127.0.0.1:9097',
    [switch] $Json,
    [switch] $Reset,
    [switch] $Strict
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '..\src\NetStack\Spend.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "spend module missing: $modulePath" }
Import-Module $modulePath -Force

function Read-SpendState {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return (New-SpendState) }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return (New-SpendState) }
        $s = $raw | ConvertFrom-Json
        # A state file that lost its counters is rebuilt rather than trusted: a monitor that
        # throws on its own damaged bookkeeping is worse than one that starts over.
        if (-not ($s.PSObject.Properties.Name -contains 'PaidBytes')) { return (New-SpendState) }
        return $s
    } catch { return (New-SpendState) }
}

$state = Read-SpendState -Path $StatePath
if ($Reset) {
    $history = @($state.History)
    $state = New-SpendState
    $state.History = $history
}

# One read-only API poll; the shared pure helper handles IDs, cumulative deltas
# and midnight rollover. Do not keep another copy of that accounting here.
$reachable = $true
try {
    $conns = Invoke-RestMethod -Uri "$Api/connections" -TimeoutSec 8
    $state = Update-SpendConnections -State $state -Connections @($conns.connections)
} catch {
    $reachable = $false
    # No snapshot is different from an empty one: preserve open baselines during
    # an outage, including one spanning midnight.
    $state = Add-SpendSample -State $state -Samples @()
}
$report = Format-SpendReport -State $state

# Persist: the directory is runtime state and may not exist on a fresh clone.
$dir = Split-Path -Parent $StatePath
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StatePath -Encoding UTF8

if ($Json) {
    [pscustomobject]@{
        reachable = $reachable
        summary   = $report.Summary
        share     = $report.Share
        drift     = $report.Drift
        state     = $state
    } | ConvertTo-Json -Depth 6
} else {
    if (-not $reachable) { Write-Output "spend: mihomo's API did not answer - no sample taken ($(Get-Date -Format 'HH:mm:ss'))" }
    Write-Output "spend: $($report.Summary)"
    if ($report.Drift) {
        Write-Output 'spend: the 4:1 design is a MEMBER-COUNT ratio; this figure is what it cost in bytes. If the drift is unwanted the levers are the mix membership (config: AUTO) and the routing rules.'
    }
}

if ($Strict -and $report.Drift) { exit 1 }
exit 0
