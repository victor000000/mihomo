# =============================================================================
#  tools\CodexProxyCache.ps1 - repair the Codex desktop app's PRIVATE proxy copy.
#
#  Owner, 2026-10-12: "revise the start, stop and fixall bat script to deal with
#  this situation, Codex has a system-proxy-cache-v1, clear the cache", then
#  "fix all of your scripts to do the thorough cleanup and repair all including
#  codex".
#
#  ---------------------------------------------------------------------------
#  THE FAILURE THIS REPAIRS (measured on this machine, not theory)
#  ---------------------------------------------------------------------------
#  The Codex desktop app is an MSIX package, so packaging gives it a PRIVATE,
#  virtualised copy of HKCU\...\Internet Settings, kept as a registry hive in the
#  package's "Helium" store:
#
#    %LOCALAPPDATA%\Packages\OpenAI.Codex_*\SystemAppData\Helium\User.dat
#
#  Once that key is virtualised the app never reads the real HKCU again, so every
#  script in this repo that "turns the system proxy off" edits a key the app has
#  stopped looking at. The app keeps the last proxy it ever saw and keeps dialling
#  it. Measured:
#    * the store held ProxyServer = 127.0.0.1:7897 while the real key was provably
#      clean (ProxyEnable=0, no ProxyServer, no PAC, WinHTTP direct,
#      WinHttpGetIEProxyConfigForCurrentUser -> Proxy=(null), and no proxy in the
#      app-server's own environment);
#    * the app opened SynSent -> 127.0.0.1:7897 with nothing listening and sent
#      "CONNECT api.deepseek.com:443" into it; its own log said
#      net::ERR_PROXY_CONNECTION_FAILED and the turn retried forever as
#      "Reconnecting... waiting for network";
#    * api.deepseek.com itself was healthy throughout (HTTP 200 on /responses with
#      the configured key, both backend IPs, all three uplinks);
#    * a FRESH app-server did the same with the machine's proxy provably clean,
#      which is why restarting the app never helped either.
#
#  THE TELL: the hive stores value NAMES as ASCII but REG_SZ DATA as UTF-16LE -
#  the bytes for "7897" are 37 00 38 00 39 00 37 00. That is why grepping the
#  store for 7897 and `reg query` on HKCU both come up empty.
#
#  ---------------------------------------------------------------------------
#  WHY THE REPAIR HAS TWO TIERS - AND WHY TIER 1 ALONE IS NOT ENOUGH
#  ---------------------------------------------------------------------------
#  TIER 1 - surgical, through `reg load` (preserves the app's packaged settings):
#      reg load HKU\<tmp> <hive> -> ProxyEnable=0, drop ProxyServer /
#      ProxyOverride / AutoConfigURL -> reg unload
#  This is the tidy repair and it is tried first. It needs administrator rights,
#  and on this machine it PROVED INSUFFICIENT: `reg load` succeeds, but every key
#  inside the mounted hive answers "Access is denied", because the root's security
#  comes from the hive's OWN embedded security records (sk cells), not from the
#  file ACL. Taking ownership of the file and granting full control does NOT
#  change that (measured). Tier 1 needs SYSTEM, not merely Administrator.
#
#  An earlier version of this script reported that failure as "ProxyServer was
#  recorded but no key carried it - nothing changed", which reads like "nothing to
#  do". It was not: the walk had been denied every key and the error was swallowed
#  by -ErrorAction SilentlyContinue. That misleading outcome is pinned by a test.
#
#  TIER 2 - thorough, and the one that actually worked here: retire the store.
#      The whole Helium folder is copied to state\, then its files are MOVED out,
#      so the app comes up with an empty virtual store and falls through to the
#      REAL, clean HKCU -> no proxy -> direct. Windows recreates the hive on the
#      next launch. The app's own settings are unaffected: they live in
#      %USERPROFILE%\.codex (config.toml, state_5.sqlite, the global-state JSON),
#      not in this store - the store holds the virtualised HKCU (shell/WebView2
#      MRU state), which is why a backup is taken either way.
#      Verified end to end: after retiring, with mihomo stopped and 7897 closed,
#      the app-server went straight to 39.156.8.67 (api.deepseek.com) and DeepSeek
#      turns completed.
#      Tier 2 needs NO administrator rights - the store lives in the user's own
#      profile - but it DOES need Codex closed: Windows holds the hive open
#      exclusively while the app runs (verified: even FileShare.ReadWrite fails on
#      User.dat, .LOG1 and .LOG2).
#
#  ---------------------------------------------------------------------------
#  WHAT THE DETECTION CAN AND CANNOT SAY
#  ---------------------------------------------------------------------------
#  Get-CodexProxyCacheValue scans hive bytes, so it sees proxy strings in LIVE
#  cells and in FREED ones alike (a hive keeps deleted data as free space until it
#  is reused). It is a reliable "a proxy is recorded here" signal and NOT proof
#  that a live key still uses it. The repair does not depend on that distinction:
#  tier 1 decides on the live key tree, tier 2 removes the whole store. Reporting
#  keeps them apart - Readable=$false means UNKNOWN and is never reported as
#  clean, because that false negative is what let this trap survive every earlier
#  repair run.
# =============================================================================

Set-StrictMode -Off

$script:CodexProxyCachePackageFilter = 'OpenAI.Codex_*'

function Get-CodexHeliumStore {
    <#
      Every packaged app that keeps a Helium store on this machine, as
      (Package, Folder, Files). The filter is Codex today; the pattern is not
      hard-coded to it, so a second packaged app cannot silently reintroduce this.
    #>
    [CmdletBinding()]
    param([string] $PackageFilter = $script:CodexProxyCachePackageFilter)

    $result = @()
    $packagesRoot = Join-Path $env:LOCALAPPDATA 'Packages'
    if (-not (Test-Path -LiteralPath $packagesRoot)) { return $result }

    foreach ($pkg in @(Get-ChildItem -LiteralPath $packagesRoot -Directory -Filter $PackageFilter -ErrorAction SilentlyContinue)) {
        $folder = Join-Path $pkg.FullName 'SystemAppData\Helium'
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        $files = @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)
        $result += [pscustomobject]@{ Package = $pkg.Name; Folder = $folder; Files = $files }
    }
    return $result
}

function Get-CodexProxyCacheValue {
    <#
      Read the recorded proxy WITHOUT loading the hive, so this works unelevated
      and even while Codex runs.

      Both encodings must be read: inside a registry hive the VALUE NAMES are
      ASCII ("ProxyServer") while REG_SZ DATA is UTF-16LE ("127.0.0.1:7897").
      An ASCII grep misses the data; a UTF-16 read misses the name.

      THREE OUTCOMES, not two - collapsing the first into the second is the false
      negative that makes this repair silently do nothing:
        Readable=$false                   the file could not be read at all
        Readable=$true  HasRecord=$false   read fine, no proxy recorded: clean
        Readable=$true  HasRecord=$true    a proxy is recorded (may be a freed cell)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $bytes = $null
    try {
        # FileShare.ReadWrite: the app keeps its hive open while it runs, and
        # without sharing the read fails with "being used by another process" -
        # which an earlier version turned into "no cached proxy", i.e. a locked
        # hive reported as a clean one.
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $ms = New-Object IO.MemoryStream
            $fs.CopyTo($ms)
            $bytes = $ms.ToArray()
            $ms.Dispose()
        } finally { $fs.Dispose() }
    } catch {
        return [pscustomobject]@{ Readable = $false; HasRecord = $false; Proxies = @(); Error = $_.Exception.Message }
    }
    if (-not $bytes -or $bytes.Length -eq 0) {
        return [pscustomobject]@{ Readable = $false; HasRecord = $false; Proxies = @(); Error = 'empty hive' }
    }

    $names = [Text.Encoding]::UTF8.GetString($bytes)      # ASCII-named records
    $data  = [Text.Encoding]::Unicode.GetString($bytes)   # REG_SZ payloads
    $hasRecord = (($names -match 'ProxyServer') -or ($data -match 'ProxyServer'))
    $proxies = @()
    foreach ($view in @($data, $names)) {
        foreach ($m in [regex]::Matches($view, '(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}:\d{2,5}(?![\d])')) {
            if ($proxies -notcontains $m.Value) { $proxies += $m.Value }
        }
    }
    return [pscustomobject]@{ Readable = $true; HasRecord = $hasRecord; Proxies = $proxies; Error = $null }
}

function Clear-CodexProxyCache {
    <#
      .SYNOPSIS
        Remove the stale Windows-proxy copy the Codex MSIX package keeps for itself.
      .DESCRIPTION
        Tier 1 clears it surgically through `reg load`. When that is not possible -
        no administrator rights, or the mounted hive denies access as it does on
        this machine - tier 2 retires the store so the app falls back to the real
        HKCU. Everything is backed up before either tier touches it.
      .PARAMETER DryRun
        Report only; change nothing.
      .PARAMETER RestartCodex
        Allow stopping the Codex app (it holds the store open while it runs) and
        relaunching it afterwards. Without this switch a running Codex is only
        reported, never killed.
      .PARAMETER Say
        Optional logger: a scriptblock taking (Tag, Text), so fixall.ps1 can route
        these lines into its own state\fixall-<stamp>.log.
    #>
    [CmdletBinding()]
    param(
        [switch] $DryRun,
        [switch] $RestartCodex,
        [scriptblock] $Say
    )

    if (-not $Say) { $Say = { param($Tag, $Text) Write-Host "  [$Tag] $Text" } }
    $changed    = 0
    $found      = $false
    $locked     = $false
    $unreadable = $false
    $retired    = $false
    $restart    = $false

    $isAdmin = $false
    try {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }

    $stores = @(Get-CodexHeliumStore)
    if (-not $stores.Count) {
        & $Say 'ok' 'Codex private proxy store: not present (no packaged Codex on this machine)'
        return $false
    }

    foreach ($store in $stores) {
        $leaf = Split-Path -Leaf $store.Folder
        $recorded = $null
        $unreadableHere = $false
        foreach ($f in $store.Files) {
            if ($f.Name -notlike '*.dat') { continue }
            $v = Get-CodexProxyCacheValue -Path $f.FullName
            if (-not $v.Readable) {
                $unreadable = $true
                $unreadableHere = $true
                & $Say 'warn' ("Codex private proxy store could not be read ({0}) - cannot tell whether a proxy is recorded" -f $f.Name)
                & $Say 'skip' ("reason: {0}" -f $v.Error)
                continue
            }
            if ($v.HasRecord) {
                $recorded = $v
                $shown = if ($v.Proxies.Count) { $v.Proxies -join ', ' } else { 'set' }
                & $Say 'warn' ("Codex private proxy store has a proxy recorded ({0}): {1}" -f $f.Name, $shown)
            }
        }
        # A running Codex holds the store open, so the read above comes back
        # UNKNOWN. Unknown is not clean, and a locked store is exactly the case
        # -RestartCodex exists for: close the app and read again rather than
        # reporting "nothing to do". Measured 2026-10-12 - the first version of
        # this two-tier code did the latter and silently repaired nothing.
        if (-not $recorded -and $unreadableHere -and $RestartCodex -and -not $DryRun) {
            $running = @(Get-Process -Name 'ChatGPT', 'codex' -ErrorAction SilentlyContinue)
            if ($running.Count) {
                & $Say 'changed' ("Codex holds its store open ({0} process(es)) - stopping it so the store can be read and repaired" -f $running.Count)
                foreach ($p in $running) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { } }
                for ($i = 0; $i -lt 15; $i++) {
                    Start-Sleep -Seconds 1
                    if (-not @(Get-Process -Name 'ChatGPT', 'codex' -ErrorAction SilentlyContinue).Count) { break }
                }
                $restart = $true
                $unreadableHere = $false
                foreach ($f in @($store.Files | Where-Object { $_.Name -like '*.dat' })) {
                    $v = Get-CodexProxyCacheValue -Path $f.FullName
                    if (-not $v.Readable) { $unreadableHere = $true; continue }
                    if ($v.HasRecord) { $recorded = $v }
                }
            }
        }

        if (-not $recorded) {
            if ($unreadableHere) {
                & $Say 'warn' ("Codex private proxy store could not be read ({0}) - UNKNOWN, not clean; nothing was repaired" -f $leaf)
                & $Say 'skip' 'close Codex and re-run, or pass -RestartCodex'
            } else {
                & $Say 'ok' ("Codex private proxy store: no proxy recorded ({0})" -f $leaf)
            }
            continue
        }
        $found = $true

        if ($DryRun) {
            & $Say 'skip' ("would repair: tier 1 reg load (admin), then tier 2 retire the store if that is denied - {0}" -f $leaf)
            continue
        }

        # ---------------------------------------------------------------- backup
        $backupDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'state'
        $backup = Join-Path $backupDir ("codex-helium-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        try {
            if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
            New-Item -ItemType Directory -Path $backup -Force | Out-Null
            foreach ($f in $store.Files) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $backup $f.Name) -Force -ErrorAction Stop }
            & $Say 'ok' ("backed up the store first: {0}" -f $backup)
        } catch {
            & $Say 'fail' ("could not back up the store ({0}) - refusing to modify it" -f $_.Exception.Message)
            continue
        }

        # A running Codex memory-maps its store: reg load fails and the files are
        # locked. Report, or stop it - only when the caller allowed that.
        $codex = @(Get-Process -Name 'ChatGPT', 'codex' -ErrorAction SilentlyContinue)
        if ($codex.Count) {
            if (-not $RestartCodex) {
                $locked = $true
                & $Say 'warn' ("Codex is RUNNING ({0} process(es)) - it holds this store open, so it cannot be repaired now" -f $codex.Count)
                & $Say 'skip' 'close Codex and re-run (or pass -RestartCodex, which closes and relaunches it for you)'
                continue
            }
            & $Say 'changed' ("stopping Codex so its store unlocks and can be recreated ({0} process(es))" -f $codex.Count)
            foreach ($p in $codex) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { } }
            for ($i = 0; $i -lt 15; $i++) {
                Start-Sleep -Seconds 1
                if (-not @(Get-Process -Name 'ChatGPT', 'codex' -ErrorAction SilentlyContinue).Count) { break }
            }
            $restart = $true
        }

        $needsRetire = $false

        # ---------------------------------------------------------------- tier 1
        $datFile = ($store.Files | Where-Object { $_.Name -like '*.dat' } | Select-Object -First 1)
        if (-not $isAdmin) {
            & $Say 'skip' 'tier 1 (reg load) needs administrator rights - going straight to the thorough repair'
            $needsRetire = $true
        } elseif ($datFile) {
            $mount = 'DshCodexProxyCacheFix'
            & reg unload "HKU\$mount" 2>&1 | Out-Null
            $loadOut = (& reg load "HKU\$mount" $datFile.FullName 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) {
                & $Say 'warn' ("tier 1: reg load failed ({0}) - using the thorough repair" -f $loadOut)
                $needsRetire = $true
            } else {
                try {
                    $root = "Registry::HKEY_USERS\$mount"
                    $denied = $false
                    $keys = @($root)
                    try {
                        $keys += @(Get-ChildItem -LiteralPath $root -Recurse -ErrorAction Stop | ForEach-Object { $_.PSPath })
                    } catch {
                        # Measured here: the mounted root's security comes from the
                        # hive's own sk records, so even an Administrator is denied.
                        # Surface it - never let it read as "nothing to do".
                        $denied = $true
                        & $Say 'warn' ("tier 1: the mounted hive denies access to its keys ({0})" -f $_.Exception.Message)
                        & $Say 'skip' 'that needs SYSTEM, not merely Administrator - using the thorough repair'
                    }
                    if ($denied) {
                        $needsRetire = $true
                    } else {
                        $hit = 0
                        foreach ($k in $keys) {
                            $old = $null
                            try { $old = (Get-ItemProperty -LiteralPath $k -Name 'ProxyServer' -ErrorAction Stop).ProxyServer } catch { continue }
                            if (-not $old) { continue }
                            New-ItemProperty -LiteralPath $k -Name 'ProxyEnable' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
                            foreach ($v in 'ProxyServer', 'ProxyOverride', 'AutoConfigURL') {
                                Remove-ItemProperty -LiteralPath $k -Name $v -ErrorAction SilentlyContinue
                            }
                            $hit++
                            & $Say 'changed' ("cleared cached proxy '{0}' in {1}" -f $old, ($k -replace '^.*HKEY_USERS\\', 'HKEY_USERS\'))
                        }
                        if ($hit) {
                            $changed += $hit
                            & $Say 'ok' 'tier 1 cleared the live value - the app will resolve the real Windows proxy'
                        } else {
                            & $Say 'ok' 'tier 1: the live key tree carries no proxy (the strings on disk are freed cells) - nothing to clear'
                        }
                    }
                } finally {
                    [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                    $unload = (& reg unload "HKU\$mount" 2>&1 | Out-String).Trim()
                    if ($LASTEXITCODE -ne 0) { & $Say 'warn' ("reg unload reported: {0}" -f $unload) }
                }
            }
        }

        # ---------------------------------------------------------------- tier 2
        if ($needsRetire) {
            $retiredDir = Join-Path $backup 'retired'
            try {
                New-Item -ItemType Directory -Path $retiredDir -Force | Out-Null
                $moved = 0
                foreach ($f in @(Get-ChildItem -LiteralPath $store.Folder -File -ErrorAction Stop)) {
                    Move-Item -LiteralPath $f.FullName -Destination (Join-Path $retiredDir $f.Name) -Force -ErrorAction Stop
                    $moved++
                }
                if ($moved) {
                    $retired = $true
                    $changed++
                    & $Say 'changed' ("tier 2: retired {0} store file(s) - Windows recreates an empty store on the next launch, so the app falls through to the real (clean) HKCU" -f $moved)
                } else {
                    & $Say 'ok' 'tier 2: the store folder was already empty - nothing to retire'
                }
            } catch {
                & $Say 'fail' ("tier 2 could not retire the store ({0})" -f $_.Exception.Message)
            }
        }

        # ---------------------------------------------------------------- verify
        $after = @()
        foreach ($f in @(Get-ChildItem -LiteralPath $store.Folder -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -notlike '*.dat') { continue }
            $v = Get-CodexProxyCacheValue -Path $f.FullName
            if ($v.HasRecord) { $after += $v.Proxies }
        }
        if ($retired) {
            & $Say 'ok' 'verified: the recorded store is gone; the next Codex launch starts from an empty, clean store'
        } elseif ($after.Count) {
            & $Say 'fail' ("still recorded after the repair: {0}" -f ($after -join ', '))
        } else {
            & $Say 'ok' 'verified: no proxy is recorded in the store'
        }

        if ($restart) {
            try {
                Start-Process 'shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App'
                & $Say 'changed' 'relaunched Codex so it comes up against the repaired store'
            } catch {
                & $Say 'warn' ("could not relaunch Codex automatically ({0}) - start it by hand" -f $_.Exception.Message)
            }
        }
    }

    if ($found -and $changed -eq 0 -and -not $DryRun) {
        if ($locked)          { & $Say 'skip' 'nothing was repaired: Codex is running and holds its store open - close it and re-run, or pass -RestartCodex' }
        elseif ($unreadable)  { & $Say 'skip' 'nothing was repaired: the store could not be read - see the reason above' }
        else                  { & $Say 'skip' 'nothing was repaired - see the lines above for the reason' }
    }
    return ($changed -gt 0)
}

# ---------------------------------------------------------------------------
#  Self-test. Run DIRECTLY (not dot-sourced) for a report that changes nothing:
#
#      pwsh -NoProfile -ExecutionPolicy Bypass -File tools\CodexProxyCache.ps1
#
#  Run it when Codex "cannot visit DeepSeek" while the Windows proxy looks clean:
#  that combination is this store and nothing else. Callers dot-source this file,
#  and a dot-sourced file reports '.' as its InvocationName, so this stays out of
#  their way.
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    Write-Host ''
    Write-Host 'Codex private proxy store - report only (nothing is changed)' -ForegroundColor Cyan
    Write-Host '  the app''s own copy of the Windows proxy, in the MSIX Helium hive' -ForegroundColor Gray
    Write-Host ''
    Clear-CodexProxyCache -DryRun | Out-Null
    Write-Host ''
    Write-Host '  repair it:  stop-all.bat / start-all.bat / fixall.bat [--restart-codex]' -ForegroundColor Gray
    Write-Host '  from here:  . tools\CodexProxyCache.ps1 ; Clear-CodexProxyCache [-RestartCodex]' -ForegroundColor Gray
    Write-Host ''
}
