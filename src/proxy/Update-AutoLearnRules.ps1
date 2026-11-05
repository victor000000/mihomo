<#
.SYNOPSIS
    Auto-learner: turn observed connection failures into mihomo routing rules.

.DESCRIPTION
    WHY THIS EXISTS
    ---------------
    mihomo's `fallback` groups pick an outbound from periodic health checks, not
    from per-connection outcomes. So when the free Aliyun proxy passes its health
    check but then times out against one particular site, every request to that
    site keeps failing - mihomo never demotes the proxy for that destination.

    Observed here, 184 repetitions while AUTO stayed pinned to aliyun-native:
        [TCP] dial AUTO (match DomainSuffix/yahoo.com) --> query2.finance.yahoo.com:443
          error: 192.0.2.10:443 connect error: context deadline exceeded

    Likewise a domain with no rule falls through to the catch-all and, if that
    path is blocked, fails forever - that is how hub.docker.com was silently
    broken. Since 2026-10-11 the catch-all is MATCH,DISPATCH - most traffic is not
    MATCH,LOCAL before it), and the learner's job is the same either way: a
    destination the chosen path cannot carry gets a rule of its own.

    WHAT IT DOES
    ------------
    Reads mihomo's log, finds recently-failed destinations, and writes them into
    two mihomo rule-provider payload files, then hot-reloads those providers over
    the API (no config reload, no dropped connections):

        autolearn-direct -> RULE-SET,autolearn-direct,AUTO
                            failed direct => use the configured AUTO proxy pool.

        autolearn-paid   -> RULE-SET,autolearn-paid,AUTO
                            Historical cache name retained for compatibility.
                            This is not a subscription tier or an alternate
                            paid exit. Both cache buckets now target AUTO;
                            failures are not proof that another exit is available.

    SAFETY RULES (each one exists because ignoring it produced a bad proposal)
    -------------------------------------------------------------------------
      1. Only failures from the last -SinceMinutes are considered. Otherwise the
         learner re-proposes problems that were already fixed: it kept suggesting
         docker.com from entries logged before that rule existed.
      2. Domestic domains are never learned. A 30-minute window proposed
         doubao.com x52, zijieapi.com x16, qq.com x13, aliyuncs.com x6 - all
         Chinese telemetry endpoints that time out normally. Proxying them would
         be slower and would spend quota.
      3. Domains that already have an explicit rule are left alone. Those were
         set deliberately (usually after measuring that direct is faster), so the
         learner reports them instead of silently overriding a measured choice.
      4. paid escalation needs a much higher hit count than direct learning.
      5. Failures are collapsed to the registrable domain, so one rule fixes
         every sibling host.

.PARAMETER WhatIf
    Report what would change without writing anything.

.EXAMPLE
    .\Update-AutoLearnRules.ps1
    .\Update-AutoLearnRules.ps1 -WhatIf
    .\Update-AutoLearnRules.ps1 -SinceMinutes 15 -MinHits 10
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $MihomoDir      = 'C:\Users\victo\mihomo\runtime',
    [string] $MihomoApi      = 'http://127.0.0.1:9097',
    [string] $ProjectRoot    = 'C:\Users\victo\mihomo',
    # Overrides for testing: a test can relocate the state, the log and the rule files, and must
    # still load the module and read mihomo's log from their REAL locations. Without these,
    # `-ProjectRoot <tempdir>` alone broke `Import-Module` (measured 2026-10-12 while writing
    # tests\Update-AutoLearnRules.Tests.ps1: "module ... was not found in any module directory"),
    # the script exited 1 before writing anything, and the failure looked like a learner bug.
    [string] $ModulePath,
    [string] $StateFile,
    [string] $LogFile,
    [string] $RulesDir,
    [string] $SummaryFile,
    [int]    $SinceMinutes   = 30,
    [int]    $MinHits        = 5,
    [int]    $MinHitsForPaid = 40,
    [int]    $MaxPerRoute    = 250,
    [int]    $TtlDays        = 30,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'

$modulePath  = if ($ModulePath) { $ModulePath } else { Join-Path $ProjectRoot 'src\NetStack\NetStack.psm1' }
$rulesDir    = if ($RulesDir)   { $RulesDir }   else { Join-Path $MihomoDir 'rules' }
$stateFile   = if ($StateFile)  { $StateFile }  else { Join-Path $ProjectRoot 'state\autolearn.json' }
$logFile     = if ($LogFile)    { $LogFile }    else { Join-Path $ProjectRoot 'state\autolearn.log' }
$domesticFile= Join-Path $ProjectRoot 'config\domestic-suffixes.txt'
$configFile  = Join-Path $MihomoDir 'config.yaml'

Import-Module $modulePath -Force

function Write-ALog([string]$m) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    if (-not $Quiet) { Write-Host $line }
    try {
        $dir = Split-Path $logFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $logFile -Encoding UTF8 -Value $line
    } catch { }
}

function Read-JsonFile([string]$Path, $Default) {
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        return ($raw | ConvertFrom-Json)
    } catch { Write-ALog "could not parse $Path : $($_.Exception.Message)"; return $Default }
}

# ---------------------------------------------------------------------------
# 1. Load inputs
# ---------------------------------------------------------------------------
if (-not (Test-Path $rulesDir)) { New-Item -ItemType Directory -Path $rulesDir -Force | Out-Null }

$mihomoLog = Join-Path $MihomoDir 'mihomo.log'
if (-not (Test-Path -LiteralPath $mihomoLog)) { Write-ALog "no mihomo log at $mihomoLog - nothing to do"; return }

# The log can be large; the tail is all we need.
$logLines = @(Get-Content -LiteralPath $mihomoLog -Tail 8000 -ErrorAction SilentlyContinue)

$domesticSuffixes = @()
if (Test-Path -LiteralPath $domesticFile) {
    $domesticSuffixes = @(
        Get-Content -LiteralPath $domesticFile -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }
    )
}

# Every domain that already carries an explicit rule, either manually written or
# previously learned. The learner must not fight the hand-written ones.
$explicit = @{}
$cfgText = ''
$resolverDomains = @()
if (Test-Path -LiteralPath $configFile) {
    $cfgText = [System.IO.File]::ReadAllText($configFile, [Text.Encoding]::UTF8)
    foreach ($r in (Get-MihomoRules $cfgText)) {
        $parts = $r -split ','
        if ($parts.Count -ge 2 -and $parts[0] -match '^DOMAIN(-SUFFIX|-KEYWORD)?$') {
            $explicit[$parts[1].ToLowerInvariant()] = $true
        }
    }
    # The resolvers are infrastructure, and `respect-rules: true` dials them through
    # these very rules. Learning one makes DNS depend on the path it needs to reach a
    # resolver - and when that path fails, the failure refreshes the rule. They are
    # excluded exactly like a hand-written rule and purged from existing state below.
    $resolverDomains = @(Get-DnsResolverDomains -ConfigText $cfgText)
    foreach ($rd in $resolverDomains) { $explicit[$rd] = $true }
}
# previously learned domains count as deliberate too (that is the whole point)
$state = Read-JsonFile $stateFile $null
if ($null -eq $state) {
    $state = [pscustomobject]@{ direct = [pscustomobject]@{}; paid = [pscustomobject]@{}; updated = '' }
}

# convert the JSON state into hashtables the module can mutate
$stateHash = @{ direct = @{}; paid = @{} }
foreach ($bucket in @('direct', 'paid')) {
    $bp = $state.PSObject.Properties[$bucket]
    if ($bp -and $bp.Value) {
        foreach ($p in $bp.Value.PSObject.Properties) {
            $first = Get-Date; $last = Get-Date; $hits = 0
            try { $first = [datetime]$p.Value.First } catch { }
            try { $last  = [datetime]$p.Value.Last }  catch { }
            try { $hits  = [int]$p.Value.Hits }       catch { }
            $stateHash[$bucket][$p.Name] = @{ First = $first; Last = $last; Hits = $hits }
        }
    }
}

# Existing entries can predate the exclusions above. TTL pruning keeps an entry for
# 30 days after its LAST refresh, and a self-refreshing entry never reaches that age,
# so a resolver learned before the guard existed would otherwise stay escalated.
$resolverRemoved = @(Remove-LearnedResolverDomains -State $stateHash -ResolverDomains $resolverDomains)
if ($resolverRemoved.Count -gt 0) {
    Write-ALog ("removed {0} learned entry(ies) for the stack's own resolvers: {1}" -f $resolverRemoved.Count, ($resolverRemoved -join ', '))
}

# ---------------------------------------------------------------------------
# 2. Learn
# ---------------------------------------------------------------------------
$hostCandidates = @(Get-FailedRouteCandidate -Lines $logLines -MinHits 1 -SinceMinutes $SinceMinutes)

# Thresholds and reports are per DOMAIN; the parser is keyed per HOSTNAME. A site
# split across sibling hosts therefore never reached the bar: measured 2026-10-18,
# two hosts x4 against MinHits 5 were reported as "example.com (x8 < 5)" and
# nothing was learned. Aggregate once, by (route, registrable domain), so the
# threshold, both tallies and Update-AutoLearnState all see the same number.
$agg = @{}
foreach ($c in $hostCandidates) {
    $rd = Get-RegistrableDomain $c.Domain
    if (-not $rd) { continue }
    $key = "$($c.Route)|$rd"
    if ($agg.ContainsKey($key)) {
        $agg[$key].Count += [int]$c.Count
    } else {
        $agg[$key] = @{ Domain = $rd; Route = $c.Route; Count = [int]$c.Count; Error = $c.Error }
    }
}
$candidates = @($agg.Values | Sort-Object -Property { $_.Count } -Descending)
Write-ALog ("scanned {0} log lines; {1} failing domain(s) from {2} hostname(s) in the last {3} min" -f $logLines.Count, $candidates.Count, $hostCandidates.Count, $SinceMinutes)

$accepted = New-Object System.Collections.Generic.List[hashtable]
$skippedDomestic = New-Object System.Collections.Generic.List[string]
$skippedExplicit = New-Object System.Collections.Generic.List[string]
$skippedThreshold = New-Object System.Collections.Generic.List[string]

# Keyed by the REGISTRABLE domain, not by the hostname the log named. Both lists are
# reported per domain and only 8-10 of them are ever printed, so a per-CANDIDATE list
# burned those slots on duplicates: measured 2026-10-12, one REVIEW line carried 10
# entries covering just TWO domains (microsoft.com x9, msftconnecttest.com x1) - eight
# of the ten slots were the same domain over again, and nine real domains could not be
# seen at all. Counting per domain also makes the number meaningful: it is now the
# domain's total failures, not one hostname's.
$explicitTally = @{}
$thresholdTally = @{}
$thresholdReason = @{}
$domesticTally = @{}

foreach ($c in $candidates) {
    $rd = Get-RegistrableDomain $c.Domain
    if (-not $rd) { continue }

    if (Test-DomesticDomain -Domain $rd -DomesticSuffixes $domesticSuffixes) {
        if (-not $domesticTally.ContainsKey($rd)) { $domesticTally[$rd] = 0 }
        $domesticTally[$rd] += [int]$c.Count
        if (-not $skippedDomestic.Contains($rd)) { $skippedDomestic.Add($rd) }
        continue
    }
    # Safety rule 3 applies to BOTH routes. It used to live inside the direct branch,
    # so a domain that already had a hand-written (or resolver-owned) rule could
    # still be learned into the paid bucket from an AUTO failure. That is the path
    # that put dns.alidns.com and doh.pub into PAID.
    $known = $stateHash['direct'].ContainsKey($rd) -or $stateHash['paid'].ContainsKey($rd)
    if ($explicit.ContainsKey($rd) -and -not $known) {
        # Already routed on purpose. Report it, do not silently override a
        # measured decision - see safety rule 3.
        if (-not $explicitTally.ContainsKey($rd)) { $explicitTally[$rd] = 0 }
        $explicitTally[$rd] += [int]$c.Count
        continue
    }
    if ($c.Route -eq 'direct') {
        if ($c.Count -lt $MinHits) {
            if (-not $thresholdTally.ContainsKey($rd)) { $thresholdTally[$rd] = 0; $thresholdReason[$rd] = "x?? < $MinHits" }
            $thresholdTally[$rd] += [int]$c.Count
            $thresholdReason[$rd] = "< $MinHits (direct)"
            continue
        }
    }
    elseif ($c.Route -eq 'proxy') {
        if ($c.Count -lt $MinHitsForPaid) {
            if (-not $thresholdTally.ContainsKey($rd)) { $thresholdTally[$rd] = 0 }
            $thresholdTally[$rd] += [int]$c.Count
            $thresholdReason[$rd] = "< $MinHitsForPaid (paid)"
            continue
        }
    }
    else { continue }

    $accepted.Add($c)
}

# Highest-total first, so the 8-10 reported entries are the ones that matter.
$skippedExplicit = @($explicitTally.GetEnumerator() | Sort-Object { -$_.Value } |
                     ForEach-Object { "$($_.Key) (x$($_.Value), has an explicit rule)" })
$skippedThreshold = @($thresholdTally.GetEnumerator() | Sort-Object { -$_.Value } |
                      ForEach-Object { "$($_.Key) (x$($_.Value) $($thresholdReason[$_.Key]))" })
$skippedDomestic = @($domesticTally.GetEnumerator() | Sort-Object { -$_.Value } |
                     ForEach-Object { "$($_.Key) (x$($_.Value))" })

# The domestic guard is enforced INSIDE Update-AutoLearnState so it cannot be
# bypassed by a caller. This script only reports what was skipped.
$result = Update-AutoLearnState -State $stateHash -Candidates $accepted `
            -DomesticSuffixes $domesticSuffixes `
            -ManualDomains @($explicit.Keys) `
            -MaxPerRoute $MaxPerRoute -TtlDays $TtlDays -MinHits 1

Write-ALog ("learn: +{0} new, {1} refreshed, {2} pruned  => direct={3} paid={4}" -f `
            $result.Added, $result.Refreshed, $result.Pruned, $result.DirectCount, $result.PaidCount)
if ($skippedDomestic.Count -gt 0)  { Write-ALog ("skipped {0} domestic: {1}" -f $skippedDomestic.Count, (($skippedDomestic | Select-Object -Unique | Select-Object -First 15) -join ', ')) }
if ($skippedExplicit.Count -gt 0)  { Write-ALog ("REVIEW - failing but explicitly routed: {0}" -f (($skippedExplicit | Select-Object -First 10) -join '; ')) }
if ($skippedThreshold.Count -gt 0) { Write-ALog ("below threshold: {0}" -f (($skippedThreshold | Select-Object -First 8) -join '; ')) }

# ---------------------------------------------------------------------------
# 3. Render the rule-provider payloads
# ---------------------------------------------------------------------------
$changed = @()
foreach ($bucket in @('direct', 'paid')) {
    $file = Join-Path $rulesDir "autolearn-$bucket.yaml"
    $dirty = ($result.Added -gt 0) -or ($result.Pruned -gt 0) -or
             ($resolverRemoved.Count -gt 0) -or (-not (Test-Path -LiteralPath $file))
    if (-not $dirty) { continue }

    $header = @"
Auto-learned by src/proxy/Update-AutoLearnRules.ps1 - DO NOT EDIT BY HAND.
bucket   : $bucket
meaning  : $(if ($bucket -eq 'direct') { 'direct path failed -> route via configured AUTO pool' } else { 'legacy proxy-classified cache -> AUTO; no subscription tier' })
generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
entries  : $($stateHash[$bucket].Count)
"@
    # classical behavior + an explicit DOMAIN-SUFFIX prefix.
    # `behavior: domain` was tried first and silently failed to match
    # subdomains - see the note in NetStack.psm1 (ConvertTo-RuleProviderPayload).
    $yaml = ConvertTo-RuleProviderPayload -Domains @($stateHash[$bucket].Keys) `
                -Header $header -RulePrefix 'DOMAIN-SUFFIX,'
    if ($PSCmdlet.ShouldProcess($file, 'write auto-learned rules')) {
        $tmp = "$file.tmp"
        [System.IO.File]::WriteAllText($tmp, $yaml, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $file -Force
        $changed += $bucket
        Write-ALog "wrote $file ($($stateHash[$bucket].Count) entries)"
    }
}

# ---------------------------------------------------------------------------
# 4. Persist state
# ---------------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess($stateFile, 'save learner state')) {
    $out = [ordered]@{ updated = (Get-Date).ToString('o'); direct = [ordered]@{}; paid = [ordered]@{} }
    foreach ($bucket in @('direct', 'paid')) {
        foreach ($k in ($stateHash[$bucket].Keys | Sort-Object)) {
            $e = $stateHash[$bucket][$k]
            $out[$bucket][$k] = [ordered]@{
                First = $e.First.ToString('o'); Last = $e.Last.ToString('o'); Hits = $e.Hits
            }
        }
    }
    $dir = Split-Path $stateFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $out | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($stateFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------------
# 5. Hot-reload the providers (only the changed ones)
# ---------------------------------------------------------------------------
$reloadFailed = @()
foreach ($bucket in $changed) {
    $prov = "autolearn-$bucket"
    try {
        Invoke-RestMethod -Uri "$MihomoApi/providers/rules/$prov" -Method Put -TimeoutSec 15 | Out-Null
        Write-ALog "reloaded provider $prov"
    } catch {
        $reloadFailed += $prov
        Write-ALog "reload of $prov failed: $($_.Exception.Message.Split([char]10)[0])"
    }
}
# A failed reload left a rule file on disk that the RUNNING mihomo does not know about, so the
# learner's work is invisible until something reloads it. That must not pass silently: measured
# 2026-10-11 07:55, two loads failed with "无法连接到远程服务器" while the script still exited 0 and
# Task Scheduler recorded a success. It is now a non-zero exit, which is the only channel the task
# has for saying "look at me" - the log line alone is invisible to anyone not reading the log.
if ($reloadFailed.Count -gt 0) {
    Write-ALog ("EXITING NON-ZERO: {0} provider reload(s) failed - the rule files on disk are ahead of the running mihomo" -f $reloadFailed.Count)
}

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------
$summary = [ordered]@{
    timestamp      = (Get-Date).ToString('o')
    scanned        = $logLines.Count
    candidates     = $candidates.Count
    accepted       = $accepted.Count
    added          = $result.Added
    refreshed      = $result.Refreshed
    pruned         = $result.Pruned
    directCount    = $result.DirectCount
    paidCount      = $result.PaidCount
    skippedDomestic= @($skippedDomestic)
    skippedExplicit= @($skippedExplicit)
    # below-threshold entries used to be logged and then DROPPED here, so the one file a
    # dashboard can read never carried them - the reviewer saw them only by reading the log.
    skippedThreshold = @($skippedThreshold)
    resolverDomains  = @($resolverDomains)
    resolverRemoved  = @($resolverRemoved)
    reloadFailed   = @($reloadFailed)
    reloaded       = $changed
}
$summaryPath = if ($SummaryFile) { $SummaryFile } else { Join-Path $ProjectRoot 'state\autolearn-summary.json' }
# -WhatIf must not overwrite the one artefact a dashboard reads as "the last REAL run":
# it carries added/pruned counts for rules that were never written.
if ($PSCmdlet.ShouldProcess($summaryPath, 'write the learner summary')) {
    try {
        [System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

if (-not $Quiet) {
    Write-Host ''
    Write-Host '  === AUTO-LEARN SUMMARY ==='
    Write-Host ("    learned rules      : direct={0}  paid={1}" -f $result.DirectCount, $result.PaidCount)
    Write-Host ("    this run           : +{0} new, {1} refreshed, {2} pruned" -f $result.Added, $result.Refreshed, $result.Pruned)
    Write-Host ("    skipped (domestic) : {0}" -f $skippedDomestic.Count)
    Write-Host ("    skipped (explicit) : {0}  <- review these" -f $skippedExplicit.Count)
    Write-Host ("    below threshold    : {0}" -f $skippedThreshold.Count)
    if ($resolverRemoved.Count) {
        Write-Host ("    resolver exclusion : removed {0} entry(ies): {1}" -f $resolverRemoved.Count, ($resolverRemoved -join ', '))
    }
    Write-Host ("    providers reloaded : {0}" -f $(if ($changed.Count) { $changed -join ', ' } else { 'none (no change)' }))
    if ($reloadFailed.Count) {
        Write-Host ("    RELOAD FAILED      : {0}  <- rule files on disk are ahead of the running mihomo" -f ($reloadFailed -join ', ')) -ForegroundColor Red
    }
    if ($stateHash['direct'].Count -gt 0) {
        Write-Host ("    direct rules       : {0}" -f (($stateHash['direct'].Keys | Sort-Object) -join ', '))
    }
    if ($stateHash['paid'].Count -gt 0) {
        Write-Host ("    paid rules         : {0}" -f (($stateHash['paid'].Keys | Sort-Object) -join ', '))
    }
}

if ($reloadFailed.Count -gt 0) { exit 1 }
return $summary
