<#
.SYNOPSIS
    Fetch Dukascopy historical data (for SQX) from their S3 bucket.

.DESCRIPTION
    Why this exists: the legacy endpoint datafeed.dukascopy.com is rate-limited
    server-side. Measured 2026-10-11, every exit tried got
    `HTTP 429 Too Many Requests` - the free Aliyun SSH tunnel, a paid 911 node,
    and no connection at all from the direct path (blocked). Dukascopy's own
    documentation says the same: the data now lives in an S3 bucket and should be
    pulled with parallel requests, "ensuring optimal download performance and
    system stability":

        s3://cfg-public-proper-wallaby   (eu-west-1, Requester Pays)

    So this wraps the flags their wiki recommends, with two safeguards it does
    not have:

      * Requester Pays means YOUR account pays the egress (roughly $0.09/GB out
        of eu-west-1). A sync therefore refuses to start without -ConfirmCost,
        because the first run on a large instrument can cost real money.
      * It reports what actually moved: files, bytes and achieved MB/s, so a run
        can be compared against the rate-limited HTTP path instead of guessed at.

    Credentials are yours and are never stored here: run `aws configure` (or
    `aws login`) once, and this picks them up from the standard profile. The
    bucket refuses anonymous access outright, by design.

.PARAMETER Pair
    Instrument to fetch, e.g. EURUSD. Repeatable, or comma separated.

.PARAMETER All
    Fetch every instrument (expensive - list first with -List).

.PARAMETER Destination
    Local folder. Defaults to <Documents>\dukascopy-data.

.PARAMETER List
    Only list the instruments in the bucket (a few cheap LIST requests) and
    exit. Costs nothing beyond a rounding error, and is the safe first step.

.PARAMETER ConfirmCost
    Required to actually sync. Acknowledges that egress is billed to your AWS
    account.

.PARAMETER Concurrency
    Parallel requests. Dukascopy recommend 20-30; default 20.

.PARAMETER MaxBandwidth
    Optional per-command bandwidth cap, e.g. '100MB/s'.

.PARAMETER Attempts
    Retries for a failed sync (default 3, 30 s apart), mirroring their script.

.PARAMETER Proxy
    Optional proxy for the AWS CLI, e.g. http://127.0.0.1:7897. Not needed here:
    the S3 endpoints answered directly from this machine (403/307), so the
    default is no proxy.

.EXAMPLE
    .\tools\Fetch-DukascopyS3.ps1 -List
    .\tools\Fetch-DukascopyS3.ps1 -Pair EURUSD -ConfirmCost
    .\tools\Fetch-DukascopyS3.ps1 -Pair EURUSD,GBPUSD -Destination D:\data -ConfirmCost
#>
[CmdletBinding()]
param(
    [string[]] $Pair = @(),
    [switch]   $All,
    [string]   $Destination = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'dukascopy-data'),
    [string]   $Bucket = 'cfg-public-proper-wallaby',
    [string]   $Region = 'eu-west-1',
    [int]      $Concurrency = 20,
    [string]   $MaxBandwidth = '',
    [int]      $Attempts = 3,
    [string]   $Proxy = '',
    [switch]   $List,
    [switch]   $ConfirmCost
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
#  AWS CLI plumbing
# ---------------------------------------------------------------------------
function Get-AwsExe {
    $cmd = Get-Command aws -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @("$env:ProgramFiles\Amazon\AWSCLIV2\aws.exe", "$env:LOCALAPPDATA\Programs\Amazon\AWSCLIV2\aws.exe")) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    throw 'AWS CLI not found. Install it with: winget install Amazon.AWSCLI'
}

# AWS CLI writes progress to stderr and, under $ErrorActionPreference='Stop', a
# single stderr line becomes a terminating NativeCommandError before the exit
# code can be read. Every call goes through here instead.
function Invoke-Aws {
    param([string[]] $AwsArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $script:AwsExe @AwsArgs 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out.Trim() }
    } finally {
        $ErrorActionPreference = $prev
    }
}

$script:AwsExe = Get-AwsExe
Write-Host ''
Write-Host "  aws         : $script:AwsExe"
Write-Host "  bucket      : s3://$Bucket  ($Region, Requester Pays)"

if ($Proxy) {
    $env:HTTPS_PROXY = $Proxy
    $env:HTTP_PROXY = $Proxy
    Write-Host "  proxy       : $Proxy"
}

# --- credentials are mandatory: the bucket refuses anonymous access ---------
$who = Invoke-Aws @('sts', 'get-caller-identity', '--output', 'json')
if ($who.ExitCode -ne 0) {
    Write-Host ''
    Write-Host '  No usable AWS credentials.' -ForegroundColor Yellow
    Write-Host '  The bucket is Requester Pays, so Dukascopy reject anonymous requests:'
    Write-Host '      Anonymous users cannot invoke requests against Requester Pays buckets.'
    Write-Host ''
    Write-Host '  Configure them once, yourself (nothing here stores or asks for keys):'
    Write-Host '      aws configure          # access key, secret, region eu-west-1'
    Write-Host '    or  aws login            # if your account uses IAM Identity Center'
    Write-Host ''
    Write-Host "  aws said: $(@($who.Output -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1))"
    exit 2
}
$ident = $who.Output | ConvertFrom-Json
Write-Host "  identity    : $($ident.Arn)"

# ---------------------------------------------------------------------------
#  -List : the cheap call, and the safe first step
# ---------------------------------------------------------------------------
if ($List) {
    Write-Host ''
    Write-Host '  listing instruments (delimiter=/ keeps it to a few cheap LIST calls)...'
    $r = Invoke-Aws @('s3api', 'list-objects-v2', '--bucket', $Bucket, '--delimiter', '/',
                      '--region', $Region, '--request-payer', 'requester',
                      '--query', 'CommonPrefixes[].Prefix', '--output', 'text')
    if ($r.ExitCode -ne 0) { Write-Host "  list failed: $($r.Output)"; exit 1 }
    $pairs = @($r.Output -split '\s+' | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('/') } | Sort-Object -Unique)
    Write-Host ''
    Write-Host ("  {0} instruments:" -f $pairs.Count)
    $pairs | ForEach-Object { Write-Host "    $_" }
    Write-Host ''
    Write-Host '  Fetch one with:  .\tools\Fetch-DukascopyS3.ps1 -Pair EURUSD -ConfirmCost'
    exit 0
}

# ---------------------------------------------------------------------------
#  what are we syncing?
# ---------------------------------------------------------------------------
if ($All) {
    $r = Invoke-Aws @('s3api', 'list-objects-v2', '--bucket', $Bucket, '--delimiter', '/',
                      '--region', $Region, '--request-payer', 'requester',
                      '--query', 'CommonPrefixes[].Prefix', '--output', 'text')
    if ($r.ExitCode -ne 0) { Write-Host "  list failed: $($r.Output)"; exit 1 }
    $Pair = @($r.Output -split '\s+' | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('/') } | Sort-Object -Unique)
}

$pairs = @($Pair | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })
if ($pairs.Count -eq 0) {
    Write-Host ''
    Write-Host '  Nothing selected. Use -Pair EURUSD (or -List / -All).'
    exit 1
}

Write-Host "  instruments : $($pairs -join ', ')"
Write-Host "  destination : $Destination"

if (-not $ConfirmCost) {
    Write-Host ''
    Write-Host '  Refusing to sync without -ConfirmCost.' -ForegroundColor Yellow
    Write-Host '  This bucket is Requester Pays: the egress is billed to YOUR AWS account'
    Write-Host '  (roughly $0.09/GB out of eu-west-1). Re-run with -ConfirmCost once you'
    Write-Host '  are happy with that, e.g.:'
    Write-Host ''
    Write-Host ("      .\tools\Fetch-DukascopyS3.ps1 -Pair {0} -ConfirmCost" -f $pairs[0])
    Write-Host ''
    exit 3
}

if (-not (Test-Path -LiteralPath $Destination)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}

# ---------------------------------------------------------------------------
#  sync, with retries and a measured result
# ---------------------------------------------------------------------------
$before = @(Get-ChildItem -LiteralPath $Destination -Recurse -File -ErrorAction SilentlyContinue)
$beforeBytes = ($before | Measure-Object -Property Length -Sum).Sum
if (-not $beforeBytes) { $beforeBytes = 0 }
$sw = [Diagnostics.Stopwatch]::StartNew()
$ok = $true
$failedPairs = New-Object System.Collections.Generic.List[string]

foreach ($p in $pairs) {
    $target = Join-Path $Destination $p
    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }

    $pairOk = $false
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        Write-Host ''
        Write-Host ("  syncing {0} (attempt {1}/{2})..." -f $p, $attempt, $Attempts)
        # NOT $args: that is a PowerShell AUTOMATIC variable (the same trap that
        # once produced -File "...Server.ps1"System.Object[] in this repo).
        $awsArgs = @('s3', 'sync', "s3://$Bucket/$p/", $target,
                  '--region', $Region, '--request-payer', 'requester',
                  '--max-concurrent-requests', "$Concurrency", '--only-show-errors')
        if ($MaxBandwidth) { $awsArgs += @('--max-bandwidth', $MaxBandwidth) }

        $r = Invoke-Aws $awsArgs
        if ($r.ExitCode -eq 0) { $pairOk = $true; break }

        Write-Host "  failed: $($r.Output.Split([char]10)[0])" -ForegroundColor Yellow
        if ($attempt -lt $Attempts) { Start-Sleep -Seconds 30 }
    }
    if (-not $pairOk) { $ok = $false; $failedPairs.Add($p) }
}
$sw.Stop()

$after = @(Get-ChildItem -LiteralPath $Destination -Recurse -File -ErrorAction SilentlyContinue)
$afterBytes = ($after | Measure-Object -Property Length -Sum).Sum
if (-not $afterBytes) { $afterBytes = 0 }
$movedBytes = [double]$afterBytes - [double]$beforeBytes
$mbps = 0
if ($sw.Elapsed.TotalSeconds -gt 0) { $mbps = ($movedBytes / 1MB) / $sw.Elapsed.TotalSeconds }

Write-Host ''
Write-Host ("  files     : {0} ({1} new)" -f $after.Count, ($after.Count - $before.Count))
Write-Host ("  moved     : {0:N1} MB in {1:N0}s" -f ($movedBytes / 1MB), $sw.Elapsed.TotalSeconds)
Write-Host ("  throughput: {0:N2} MB/s" -f $mbps)
Write-Host ("  result    : {0}" -f $(if ($ok) { 'OK' } else { "FAILED - incomplete pairs: $($failedPairs -join ', ')" }))
Write-Host ''
if (-not $ok) { exit 1 }
