# =============================================================================
#  fix-codex.ps1 - repair the Codex desktop app's connection, and LOG EVERYTHING.
#
#  Owner, 2026-10-12: "codex desktop still cannot visit deepseekapi" ... "you can
#  write a script especially for codex, as you do for deepseek".
#
#  This is the Codex counterpart of fix-deepseek.ps1, and it exists because the
#  DeepSeek repair could not fix this: api.deepseek.com was answering the whole
#  time (HTTP 200 on /responses with the configured key, both backend IPs, all
#  three uplinks) while every Codex turn died with
#  "Connection failed: error sending request" and the window showed only
#  "Reconnecting... waiting for network".
#
#  THE CAUSE, measured - not theory:
#    The Codex desktop app is an MSIX package, so it reads a PRIVATE, virtualised
#    copy of HKCU\...\Internet Settings out of its own "Helium" registry store:
#
#      %LOCALAPPDATA%\Packages\OpenAI.Codex_*\SystemAppData\Helium\User.dat
#
#    That store held ProxyServer = 127.0.0.1:7897 while the real HKCU was provably
#    clean (ProxyEnable=0, no ProxyServer, no PAC, WinHTTP direct,
#    WinHttpGetIEProxyConfigForCurrentUser -> Proxy=(null), and no proxy in the
#    app-server's own environment). With nothing listening on 7897 the app sat in
#    SynSent to it forever, sent "CONNECT api.deepseek.com:443" into the void, and
#    logged net::ERR_PROXY_CONNECTION_FAILED. A FRESH app-server did the same, which
#    is why restarting the app never helped either - and why turning the system
#    proxy OFF made it worse: with no real proxy to resolve, the app falls back to
#    the cached one.
#    The value is UTF-16LE inside a hive whose value NAMES are ASCII, so grepping
#    the store for 7897 and `reg query` on HKCU both come up empty. That is the
#    trick that kept this invisible.
#
#  WHAT THIS DOES
#    0. captures the state that decides the outcome (proxy keys + PAC, WinHTTP,
#       env vars, the package, the store, the ports, who is dialling what);
#    1. reads the app's OWN evidence - its desktop logs and its live sockets;
#    2. decides: is this the private-store trap, or something else;
#    3. repairs by delegating to tools\CodexProxyCache.ps1 (the tested repair -
#       tier 1 `reg load`, then tier 2 retire the store), restarting Codex so the
#       store unlocks and is recreated;
#    4. verifies: the store no longer records a proxy, the app no longer dials it,
#       and api.deepseek.com answers on the raw OS route.
#
#  Usage (fix-codex.bat wraps this file):
#    fix-codex.bat                 diagnose, repair, verify (closes + reopens Codex)
#    fix-codex.bat --dry           diagnose + report only, change nothing
#    fix-codex.bat --keep-codex    never close Codex (repairs only while it is shut)
#
#  Administrator rights are NOT required: the repair's working tier (retiring the
#  store) lives inside your own profile. If Codex is open it must be closed, since
#  Windows holds the store open exclusively while it runs.
#  Log: state\codex-fix-<stamp>.log, holding every command, its exit code, its raw
#  output and the state of everything that decides the outcome.
# =============================================================================
param(
    [switch] $DryRun,
    [switch] $KeepCodex
)

$ErrorActionPreference = 'Continue'

$repo      = $PSScriptRoot
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$stateDir  = Join-Path $repo 'state'
$logFile   = Join-Path $stateDir "codex-fix-$stamp.log"
# $env:SystemRoot is not guaranteed (a stripped environment leaves it null and
# Join-Path then fails parameter validation, taking the line with it).
$sysRoot   = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
$curl      = "$sysRoot\System32\curl.exe"      # concatenated: Join-Path validates the drive
$api       = 'https://api.deepseek.com/'
$helper    = Join-Path $repo 'tools\CodexProxyCache.ps1'
$packages  = Join-Path $env:LOCALAPPDATA 'Packages'
$appFolder = 'shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App'

$script:fixed  = 0
$script:issues = 0
$script:fails  = New-Object System.Collections.Generic.List[string]

function Log-Raw([string]$Text) {
    try { Add-Content -LiteralPath $logFile -Encoding UTF8 -Value $Text } catch { }
}

function Say([string]$Tag, [string]$Text) {
    $colour = switch ($Tag) {
        'ok'    { 'Gray' }
        'fix'   { 'Green' }
        'warn'  { 'Yellow' }
        'fail'  { 'Red' }
        'skip'  { 'DarkGray' }
        default { 'White' }
    }
    Write-Host ("  [{0,-5}] {1}" -f $Tag, $Text) -ForegroundColor $colour
    Log-Raw ("[{0,-5}] {1}" -f $Tag, $Text)
    if ($Tag -eq 'fail') { $script:fails.Add($Text) }
}

function Step([string]$Text) {
    Write-Host ''
    Write-Host "--- $Text ---" -ForegroundColor Cyan
    Log-Raw ''
    Log-Raw "==================== $Text"
}

# Run a command for the log: the command line, then its output, whatever it is.
function Log-Command([string]$Title, [scriptblock]$Body) {
    Log-Raw ''
    Log-Raw "--- $Title"
    try {
        $out = (& $Body 2>&1 | Out-String).Trim()
        if (-not $out) { $out = '(no output)' }
    } catch { $out = "ERROR: $($_.Exception.Message)" }
    Log-Raw $out
}

# One HTTPS probe. -Proxy '' = the machine's own route (--noproxy=*), anything
# else is handed to curl as -x.
function Invoke-Probe([string]$Url, [string]$Proxy) {
    $r = @{ Ok = $false; Code = ''; Ip = ''; Note = ''; Exit = -1 }
    if (-not (Test-Path -LiteralPath $curl)) { $r.Note = 'curl.exe not found - cannot measure'; return $r }
    $fmt = 'h=%{http_code};i=%{remote_ip}'
    $curlArgs = @('-sS', '-o', 'NUL', '-m', '15', '-w', $fmt)
    # `--noproxy=*` as ONE token on purpose: PowerShell expands a bare `*` into the
    # directory listing, so the "direct" probe would quietly go through whatever
    # proxy the environment still had (the trap fix-deepseek.ps1 documents).
    if ($Proxy) { $curlArgs += @('-x', $Proxy) } else { $curlArgs += '--noproxy=*' }
    Log-Raw ''
    Log-Raw "--- curl $($curlArgs -join ' ') $Url"
    $raw = & $curl @curlArgs $Url 2>&1
    $r.Exit = $LASTEXITCODE
    $all = ($raw | Out-String)
    Log-Raw "exit code: $($r.Exit)"
    Log-Raw "output   : $(if ($all.Trim()) { $all.Trim() } else { '(empty)' })"
    $lines = @($all -split "`r?`n" | Where-Object { $_ -match 'h=\d{3};' })
    if ($lines.Count -and $lines[-1] -match 'h=(\d{3});i=([^\s;]*)') {
        $r.Code = $Matches[1]
        $r.Ip   = $Matches[2]
        $r.Ok   = ($r.Exit -eq 0 -and $r.Code -match '^\d{3}$' -and $r.Code -ne '000')
    }
    return $r
}

# Every live socket the Codex app-server holds. This is the ground truth for
# "is the app still dialling the dead proxy" - the app never says it out loud.
function Get-CodexConnection {
    $out = @()
    $pids = @(Get-CimInstance Win32_Process -Filter "Name='codex.exe'" -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessId })
    foreach ($procId in $pids) {
        foreach ($c in @(Get-NetTCPConnection -OwningProcess $procId -ErrorAction SilentlyContinue)) {
            if ($c.RemotePort -eq 0) { continue }
            $out += [pscustomobject]@{
                Pid    = $procId
                State  = "$($c.State)"
                Remote = "$($c.RemoteAddress):$($c.RemotePort)"
                Port   = $c.RemotePort
                Ip     = "$($c.RemoteAddress)"
            }
        }
    }
    return $out
}

function Get-CodexProcess {
    return @(Get-Process -Name 'ChatGPT', 'codex' -ErrorAction SilentlyContinue)
}

function Test-Port([int]$Port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(800)) { $c.EndConnect($iar); return $true }
        return $false
    } catch { return $false } finally { $c.Close() }
}

# =============================================================================
#  0. the state that decides the outcome
# =============================================================================
Write-Host ''
Write-Host '======================= fix-codex =======================' -ForegroundColor Cyan
Write-Host '  repair the Codex desktop app - MSIX private proxy store' -ForegroundColor Gray
if ($DryRun)    { Write-Host '  DRY RUN - nothing will be changed' -ForegroundColor Yellow }
if ($KeepCodex) { Write-Host '  KEEP-CODEX - the app will not be closed' -ForegroundColor Yellow }
Write-Host ''

try { if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null } } catch { }
Log-Raw "==================== fix-codex $stamp"
Log-Raw "dry run: $DryRun   keep codex: $KeepCodex"

Step '0. environment (the detail is written to the log as it is collected)'

$isAdmin = $false
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }
Log-Command 'who/where' {
    "computer : $env:COMPUTERNAME   user: $env:USERNAME"
    "powershell: $($PSVersionTable.PSVersion)   engine: $($PSVersionTable.PSEdition)   host: $($Host.Name)"
    "script   : $PSCommandPath"
    "elevated : $isAdmin"
}

$inet = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$sysProxy = Get-ItemProperty -Path $inet -ErrorAction SilentlyContinue
Log-Command 'system proxy keys (HKCU, all of them)' {
    "ProxyEnable   = $($sysProxy.ProxyEnable)"
    "ProxyServer   = $($sysProxy.ProxyServer)"
    "ProxyOverride = $($sysProxy.ProxyOverride)"
    "AutoConfigURL = $($sysProxy.AutoConfigURL)"
    "AutoDetect    = $($sysProxy.AutoDetect)"
}

$whDirect = $true
Log-Command 'WinHTTP proxy' {
    $t = ((& netsh winhttp show proxy) 2>&1 | Out-String)
    $script:whDirect = [bool]($t -match 'Direct access|直接访问')
    $t.Trim()
}

Log-Command 'proxy environment variables, User + Machine' {
    foreach ($scope in @('User', 'Machine')) {
        foreach ($n in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) {
            $v = [Environment]::GetEnvironmentVariable($n, $scope)
            if ($v) { "$scope  $n = $v" }
        }
    }
    '(only variables that are set are listed)'
}

Log-Command 'the Codex package' {
    $pkgs = @(Get-ChildItem -LiteralPath $packages -Directory -Filter 'OpenAI.Codex_*' -ErrorAction SilentlyContinue)
    if (-not $pkgs.Count) { 'no OpenAI.Codex_* package found' }
    foreach ($p in $pkgs) { "package : $($p.Name)" }
}

$codexProcs = Get-CodexProcess
$port7897 = Test-Port 7897
Log-Command 'the running app and the port it wants' {
    "Codex processes  : $($codexProcs.Count)"
    "port 7897        : $(if ($port7897) { 'LISTENING' } else { 'closed' })"
    "system proxy     : $(if ($sysProxy.ProxyEnable -eq 1) { "ON -> $($sysProxy.ProxyServer)" } else { 'off' })"
    "WinHTTP          : $(if ($whDirect) { 'direct' } else { 'a proxy is set' })"
}

# =============================================================================
#  1. the app's OWN evidence
# =============================================================================
Step "1. the app's own evidence"

if (-not (Test-Path -LiteralPath $helper)) {
    Say 'fail' "tools\CodexProxyCache.ps1 is missing at $helper - this tool cannot read or repair the store"
    Say 'skip' 'restore that file from the repo; it owns the store repair'
    $storeSummary = @()
} else {
    . $helper
    $storeSummary = @()
    foreach ($store in @(Get-CodexHeliumStore)) {
        foreach ($f in @($store.Files | Where-Object { $_.Name -like '*.dat' })) {
            $v = Get-CodexProxyCacheValue -Path $f.FullName
            $storeSummary += [pscustomobject]@{ File = $f.Name; Readable = $v.Readable; Recorded = $v.HasRecord; Proxies = ($v.Proxies -join ', '); Error = $v.Error }
        }
    }
    Log-Command 'the private MSIX store (the app reads THIS, not HKCU)' {
        if (-not $storeSummary.Count) { 'no Helium store present' }
        foreach ($s in $storeSummary) {
            "$($s.File): readable=$($s.Readable) recorded=$($s.Recorded) proxies=[$($s.Proxies)] $(if ($s.Error) { 'err=' + $s.Error })"
        }
    }
    foreach ($s in $storeSummary) {
        if ($s.Recorded) {
            Say 'fail' "private store records a proxy the app will dial: $($s.Proxies)  ($($s.File))"
            foreach ($p in ($s.Proxies -split ',\s*')) {
                if ($p -match ':(\d+)$' -and -not (Test-Port ([int]$Matches[1]))) {
                    Say 'warn' "  and nothing is listening on $p - every request to it will hang in SynSent"
                }
            }
        } elseif ($s.Readable) {
            Say 'ok' "private store records no proxy ($($s.File))"
        } else {
            Say 'warn' "private store could not be read ($($s.File)) - UNKNOWN, not clean"
        }
    }
}

# The app's desktop logs are plain text and carry the proxy failure verbatim.
$logRoot = Join-Path $packages 'OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs'
Log-Command 'the app log: proxy failures in the newest desktop log' {
    $newest = Get-ChildItem -Recurse -File $logRoot -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { 'no desktop log found'; return }
    "file: $($newest.FullName)"
    $hits = @(Select-String -Path $newest.FullName -Pattern 'ERR_PROXY_CONNECTION_FAILED|proxy' -ErrorAction SilentlyContinue)
    "lines mentioning a proxy: $($hits.Count)"
    foreach ($h in ($hits | Select-Object -Last 5)) { $h.Line.Trim().Substring(0, [Math]::Min(220, $h.Line.Trim().Length)) }
}
$proxyErrLog = $false
try {
    $newest = Get-ChildItem -Recurse -File $logRoot -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest) {
        $proxyErrLog = [bool](Select-String -Path $newest.FullName -Pattern 'ERR_PROXY_CONNECTION_FAILED' -ErrorAction SilentlyContinue)
    }
} catch { }
if ($proxyErrLog) { Say 'fail' 'the app log shows net::ERR_PROXY_CONNECTION_FAILED - the proxy layer is the failing hop' }

# Ground truth: where the app-server is actually dialling.
$conns = Get-CodexConnection
Log-Command 'live app-server sockets' {
    if (-not $conns.Count) { '(none)' }
    foreach ($c in $conns) { "pid $($c.Pid)  $($c.State)  -> $($c.Remote)" }
}
$dialingProxy = @($conns | Where-Object { $_.Port -eq 7897 })
$dialingDirect = @($conns | Where-Object { $_.Ip -in @('111.32.200.78', '39.156.8.67') })
if ($dialingProxy.Count) { Say 'fail' "the app-server is dialling 127.0.0.1:7897 ($($dialingProxy[0].State)) - the cached proxy" }
elseif ($dialingDirect.Count) { Say 'ok' 'the app-server is talking to api.deepseek.com directly' }
else { Say 'skip' 'no app-server connection to judge right now (it is idle until you send a message)' }

# =============================================================================
#  2. the raw route, which must work regardless of any proxy
# =============================================================================
Step '2. can the machine reach api.deepseek.com at all (raw OS route)'
$direct = Invoke-Probe $api ''
if ($direct.Ok) { Say 'ok' "raw OS route : OK  HTTP $($direct.Code)  ip $($direct.Ip)" }
else { Say 'fail' "raw OS route : did NOT answer (exit $($direct.Exit)) - that is upstream of Codex; run fix-deepseek.bat first" }
if ($port7897) {
    $viaProxy = Invoke-Probe $api 'http://127.0.0.1:7897'
    if ($viaProxy.Ok) { Say 'ok' "via 7897      : OK  HTTP $($viaProxy.Code)  (something IS serving that port)" }
    else { Say 'warn' "via 7897      : FAILED (exit $($viaProxy.Exit)) - the port answers but does not carry the API" }
} else {
    Say 'skip' 'via 7897      : nothing listening - correct for a direct setup'
}

# =============================================================================
#  3. what is wrong
# =============================================================================
Step '3. what is wrong'
$storeTrap = @($storeSummary | Where-Object { $_.Recorded }).Count -gt 0
$storeUnknown = @($storeSummary | Where-Object { -not $_.Readable }).Count -gt 0

if ($storeTrap) {
    $script:issues++
    Say 'warn' 'DIAGNOSIS: the Codex MSIX private store holds a proxy. The app reads that store and never HKCU, so no Windows-level repair reaches it.'
} elseif ($storeUnknown) {
    $script:issues++
    Say 'warn' 'DIAGNOSIS: the store could not be read (Codex holds it open). Close the app and re-run to get a verdict.'
} else {
    Say 'ok' 'DIAGNOSIS: the private store is clean - if Codex still fails, the cause is elsewhere (proxy env vars, DNS, or the API itself)'
}

# =============================================================================
#  4. repair
# =============================================================================
Step '4. repair'
$stoppedCodex = $false
$say = { param($Tag, $Text)
    $colour = switch ($Tag) { 'ok' { 'Gray' } 'changed' { 'Green' } 'skip' { 'DarkGray' } 'warn' { 'Yellow' } 'fail' { 'Red' } default { 'White' } }
    Write-Host ("  [{0,-7}] {1}" -f $Tag, $Text) -ForegroundColor $colour
    Log-Raw ("[{0,-7}] {1}" -f $Tag, $Text)
}
if ($DryRun) {
    Say 'skip' 'DRY RUN - no repair attempted'
    if ($storeTrap) { Say 'skip' 'would clear the private store (tier 1 reg load, else tier 2 retire), then reopen Codex' }
} elseif (-not (Test-Path -LiteralPath $helper)) {
    Say 'fail' 'cannot repair: tools\CodexProxyCache.ps1 is missing'
} elseif (-not $storeTrap -and -not $storeUnknown) {
    Say 'skip' 'nothing to repair in the private store'
} else {
    # This tool owns the app's lifecycle, NOT the helper. The store is locked while
    # Codex runs, and it has to stay closed until the store has been READ BACK to
    # prove the repair: letting the helper reopen it first (its -RestartCodex) made
    # the verification read a freshly locked store and report UNKNOWN - measured
    # 2026-10-12, the first run of this script. Stop here, verify below, reopen last.
    if (-not $KeepCodex) {
        $procs = Get-CodexProcess
        if ($procs.Count) {
            Say 'fix' ("closing Codex ({0} process(es)) so its private store unlocks" -f $procs.Count)
            foreach ($p in $procs) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { } }
            for ($i = 0; $i -lt 15; $i++) {
                Start-Sleep -Seconds 1
                if (-not (Get-CodexProcess).Count) { break }
            }
            $stoppedCodex = $true
        }
    }
    $changed = Clear-CodexProxyCache -Say $say
    if ($changed) { $script:fixed++ } else { $script:issues++ }
}

# True when something in this run actually could not be settled.
$blocked = $false

# =============================================================================
#  5. verify
# =============================================================================
Step '5. verify'
$after = @()
$afterUnreadable = 0
if (Test-Path -LiteralPath $helper) {
    foreach ($store in @(Get-CodexHeliumStore)) {
        foreach ($f in @($store.Files | Where-Object { $_.Name -like '*.dat' })) {
            $v = Get-CodexProxyCacheValue -Path $f.FullName
            # Unreadable is UNKNOWN, never clean - reporting it as clean is the
            # false negative that let this trap survive every earlier repair.
            if (-not $v.Readable) { $afterUnreadable++; continue }
            if ($v.HasRecord) { $after += $v.Proxies }
        }
    }
}
Log-Command 'the store after the repair' {
    $files = @(Get-ChildItem -LiteralPath (Join-Path $packages 'OpenAI.Codex_2p2nqsd0c76g0\SystemAppData\Helium') -File -ErrorAction SilentlyContinue)
    if (-not $files.Count) { '(empty - Windows recreates it on the next Codex launch)' }
    foreach ($f in $files) { "$($f.Name)  $($f.Length) bytes" }
    "proxies still recorded: $($after.Count)"
}
if ($DryRun) {
    Say 'skip' 'DRY RUN - nothing to verify'
} elseif ($after.Count) {
    Say 'fail' "the store STILL records a proxy: $($after -join ', ') - close Codex completely and re-run"
} else {
    Say 'ok' 'the private store records no proxy - Codex will resolve the real Windows settings'
}

# The decisive check, and it comes LAST: the store has now been verified, so Codex
# can be reopened and watched. A repair that leaves the app closed (-KeepCodex) has
# nothing to watch - say so rather than implying a pass.
$bad = @()
$good = @()
if ($DryRun) {
    Say 'skip' 'DRY RUN - nothing to watch'
} elseif ($KeepCodex -or -not $stoppedCodex) {
    Say 'skip' 'Codex was not reopened by this run - start it yourself and re-run for the socket check'
} else {
    try {
        Start-Process $appFolder
        Say 'fix' 'reopened Codex against the repaired store'
    } catch {
        Say 'warn' ("could not reopen Codex automatically ({0}) - start it by hand" -f $_.Exception.Message)
    }
    $watch = 75
    Log-Raw "watching app-server sockets for ${watch}s (7897 = still broken, an API ip = repaired)"
    $seen = @{}
    $end = (Get-Date).AddSeconds($watch)
    while ((Get-Date) -lt $end) {
        foreach ($c in (Get-CodexConnection)) {
            $k = "$($c.State) $($c.Remote)"
            if (-not $seen.ContainsKey($k)) { $seen[$k] = (Get-Date).ToString('HH:mm:ss') }
        }
        Start-Sleep -Milliseconds 500
    }
    foreach ($k in $seen.Keys) { Log-Raw "  [$($seen[$k])] $k" }
    $bad  = @($seen.Keys | Where-Object { $_ -match ':7897$' })
    $good = @($seen.Keys | Where-Object { $_ -match ':(443|80)$' -and $_ -notmatch ':7897$' })
    if ($bad.Count) {
        Say 'fail' 'the reopened Codex is STILL dialling 127.0.0.1:7897 - the store was not cleared; send me the log'
        $blocked = $true
    } elseif ($good.Count) {
        Say 'ok' 'the reopened Codex is talking to the network directly (no 7897) - repaired'
    } else {
        Say 'skip' 'no Codex socket yet - send it a message and watch the window; a healthy turn means repaired'
    }
}

# =============================================================================
#  SUMMARY
# =============================================================================
Write-Host ''
Write-Host '======================= SUMMARY =======================' -ForegroundColor Cyan
Write-Host ("  private store    : {0}" -f $(
    if ($after.Count)        { "still records $($after -join ', ')" }
    elseif ($afterUnreadable) { "UNKNOWN - $afterUnreadable file(s) could not be read (Codex holds them open), so this is NOT a clean verdict" }
    else                     { 'no proxy recorded' }))
Write-Host ("  raw OS route     : {0}" -f $(if ($direct.Ok) { "OK  HTTP $($direct.Code)" } else { 'did NOT answer' }))
Write-Host ("  port 7897        : {0}" -f $(if ($port7897) { 'LISTENING' } else { 'closed' }))
Write-Host ("  repairs made     : {0}" -f $script:fixed)
Write-Host ("  open issues      : {0}" -f $script:issues)
Write-Host ''
Log-Raw ''
Log-Raw "SUMMARY store=[$($after -join ', ')] unreadable=$afterUnreadable direct=[$($direct.Code)] port7897=$port7897 fixed=$($script:fixed) issues=$($script:issues) blocked=$blocked"
foreach ($f in $script:fails) { Log-Raw "  FAIL: $f" }
Write-Host "  log: $logFile" -ForegroundColor DarkGray
Write-Host ''
Write-Host '  If Codex still cannot reach the API: QUIT it fully (tray included) and' -ForegroundColor Gray
Write-Host '  reopen it - Windows holds the store open and caches the proxy per process.' -ForegroundColor Gray
Write-Host ''

if ($DryRun) { exit 0 }
# The exit code describes the state at the END, not the problem found at the start:
# repairing something that WAS broken is a success. It is 1 only when something is
# still wrong or could not be settled - a proxy still recorded, a store that could
# not be read (UNKNOWN is not clean), the API unreachable, or the reopened app
# still dialling the dead proxy.
$finalOk = ($after.Count -eq 0) -and ($afterUnreadable -eq 0) -and $direct.Ok -and (-not $blocked)
if ($finalOk) { exit 0 } else { exit 1 }
