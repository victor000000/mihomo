Set-StrictMode -Version 2.0

function New-HotspotState {
    @{
        enabled = $true
        ap_started = ''; ap_stopped = ''; pass_fp = ''; idle_fix_at = ''
        last_client_at = ''; clients = @{}
        band_restart_pending = $false; restart_pending = $false; band_retry_after = ''; fallback_band = ''
        # Uplink and traffic evidence. `uplink` is the adapter this project last
        # tethered ('' = the Windows default link); the rest are sampling
        # baselines, never policy.
        uplink = ''; traffic_at = ''; traffic_rx = [long]0; traffic_tx = [long]0
        ap_link = ''; wlan_seen = ''; uplink_policy = $false
    }
}

function Set-HotspotIntent {
    [CmdletBinding()]
    param([hashtable] $State, [string] $Action)
    if ($Action -notin @('start', 'restart', 'stop')) { return $false }
    $enabled = $Action -ne 'stop'
    $changed = -not $State.ContainsKey('enabled') -or [bool]$State.enabled -ne $enabled
    $State.enabled = $enabled
    return $changed
}

function Update-HotspotSession {
    [CmdletBinding()]
    param([hashtable] $State, [string] $ObservedState, [datetime] $Now = (Get-Date))

    if ($ObservedState -eq 'Off' -and $State.ap_started) {
        $State.ap_stopped = $Now.ToString('o')
        $State.ap_started = ''
        $State.last_client_at = ''
        $State.clients = @{}
    } elseif ($ObservedState -eq 'On' -and -not $State.ap_started) {
        $State.ap_started = $Now.ToString('o')
        $State.last_client_at = ''
        $State.clients = @{}
    }
}

function Invoke-HotspotCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('start', 'stop', 'restart', 'ensure')] [string] $Action,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Adapter,
        [Parameter(Mandatory)] [hashtable] $State,
        [string] $PreferredBand = 'FiveGigahertz',
        [bool] $RestartRequired = $false,
        [ValidateRange(1, 60)] [int] $PollAttempts = 15,
        [ValidateRange(1, 60)] [int] $FallbackMinutes = 30,
        [datetime] $Now = (Get-Date)
    )

    foreach ($name in 'GetState', 'GetBand', 'SupportsBand', 'SetBand', 'Start', 'Stop', 'SharingHealthy', 'Delay', 'Persist', 'Log') {
        if (-not $Adapter.Contains($name) -or $Adapter[$name] -isnot [scriptblock]) {
            throw "Missing hotspot adapter operation: $name"
        }
    }
    $defaults = New-HotspotState
    foreach ($key in $defaults.Keys) {
        if (-not $State.ContainsKey($key)) { $State[$key] = $defaults[$key] }
    }

    function Save-State { $null = & $Adapter.Persist $State }
    function Observe-State {
        $observed = [string](& $Adapter.GetState)
        Update-HotspotSession -State $State -ObservedState $observed -Now $Now
        return $observed
    }
    function Wait-State([string] $Expected, [bool] $Sharing = $false) {
        for ($i = 0; $i -lt $PollAttempts; $i++) {
            $observed = Observe-State
            if ($observed -eq $Expected -and (-not $Sharing -or [bool](& $Adapter.SharingHealthy))) { return $true }
            if ($i -lt ($PollAttempts - 1)) { $null = & $Adapter.Delay 1 }
        }
        return $false
    }
    function Wait-StableState {
        for ($i = 0; $i -lt $PollAttempts; $i++) {
            $observed = Observe-State
            if ($observed -in @('On', 'Off')) { return $observed }
            if ($i -lt ($PollAttempts - 1)) { $null = & $Adapter.Delay 1 }
        }
        throw [TimeoutException]::new('Hotspot is still transitioning; no competing operation was issued')
    }
    function Stop-Ap {
        if ((Wait-StableState) -eq 'Off') { return $true }
        $status = [string](& $Adapter.Stop)
        $null = & $Adapter.Log "stop: status=$status"
        if ($status -notin @('Success', 'AlreadyOff')) { return $false }
        return (Wait-State 'Off')
    }
    function Write-Diagnostics([string] $Tag) {
        if ($Adapter.Contains('Diagnose')) {
            try { $null = & $Adapter.Diagnose $Tag }
            catch { $null = & $Adapter.Log 'diagnostic collection failed' }
        }
    }
    function Complete([bool] $Success, [string] $Reason, [bool] $Fallback = $false) {
        $observed = Observe-State
        Save-State
        [pscustomobject]@{
            Success = $Success; Reason = $Reason; State = $observed
            SavedBand = [string](& $Adapter.GetBand)
            Fallback = $Fallback; RestartPending = [bool]($State.band_restart_pending -or $State.restart_pending)
        }
    }

    try {
        if ($Action -in @('start', 'restart', 'stop')) {
            $null = Set-HotspotIntent -State $State -Action $Action
            Save-State
        }
        if (($RestartRequired -or $Action -eq 'restart') -and $State.enabled) {
            $State.restart_pending = $true
            Save-State
        }
        $observed = Wait-StableState
        if ($Action -eq 'stop') {
            if (Stop-Ap) { return (Complete $true 'Stopped') }
            return (Complete $false 'StopFailed')
        }
        if ($Action -eq 'ensure' -and -not [bool]$State.enabled) {
            if (Stop-Ap) { return (Complete $true 'IntentionallyStopped') }
            return (Complete $false 'StopFailed')
        }
        $currentBand = [string](& $Adapter.GetBand)
        $target = $PreferredBand
        $fallback = $false
        $retryAfter = [datetime]::MinValue
        $cooldown = $State.band_retry_after -and [datetime]::TryParse([string]$State.band_retry_after, [ref]$retryAfter) -and $retryAfter -gt $Now
        if ($cooldown -and $State.fallback_band) {
            $target = [string]$State.fallback_band
            $fallback = $true
        } elseif (-not [bool](& $Adapter.SupportsBand $PreferredBand)) {
            $target = 'Auto'
            $fallback = $true
            $State.fallback_band = $target
            $State.band_retry_after = $Now.AddMinutes($FallbackMinutes).ToString('o')
            $null = & $Adapter.Log "band: $PreferredBand unsupported; using Auto"
        }

        if ($currentBand -ne $target) {
            # Persist intent before an operation that can outlive this process.
            $wasPending = [bool]$State.band_restart_pending
            $State.band_restart_pending = $true
            Save-State
            try {
                $null = & $Adapter.SetBand $target
                if ([string](& $Adapter.GetBand) -ne $target) { throw 'Windows did not save the requested band' }
            } catch {
                if ($_.Exception -is [TimeoutException]) { throw }
                $target = [string](& $Adapter.GetBand)
                $fallback = $true
                $State.fallback_band = $target
                $State.band_retry_after = $Now.AddMinutes($FallbackMinutes).ToString('o')
                $State.band_restart_pending = $wasPending -or $target -ne $currentBand
                $null = & $Adapter.Log 'band: configuration failed; retaining the saved band for availability'
                Save-State
            }
        }
        $observed = Wait-StableState
        $mustRestart = $Action -eq 'restart' -or $RestartRequired -or [bool]$State.restart_pending -or [bool]$State.band_restart_pending
        if ($observed -eq 'On' -and -not $mustRestart -and [bool](& $Adapter.SharingHealthy)) {
            return (Complete $true 'Healthy' $fallback)
        }
        Write-Diagnostics 'repair'
        if (-not (Stop-Ap)) { return (Complete $false 'StopFailed' $fallback) }
        Save-State
        $null = & $Adapter.Delay 2

        for ($attempt = 0; $attempt -lt 2; $attempt++) {
            try { $status = [string](& $Adapter.Start) }
            catch {
                if ($_.Exception -is [TimeoutException]) { throw }
                $status = 'OperationFailed'
            }
            $null = & $Adapter.Log "start: attempt=$($attempt + 1) status=$status band=$target"
            if ($status -in @('Success', 'AlreadyOn') -and (Wait-State 'On' $true)) {
                $State.band_restart_pending = $false
                $State.restart_pending = $false
                if (-not $fallback) { $State.fallback_band = ''; $State.band_retry_after = '' }
                return (Complete $true 'Healthy' $fallback)
            }
            if ($attempt -eq 0) {
                if (-not (Stop-Ap)) { return (Complete $false 'StopFailed' $fallback) }
                Save-State
                $null = & $Adapter.Delay 2
                if ($status -in @('RadioRestriction', 'BandInterference') -and $target -eq $PreferredBand) {
                    $target = 'Auto'
                    $fallback = $true
                    $State.fallback_band = $target
                    $State.band_retry_after = $Now.AddMinutes($FallbackMinutes).ToString('o')
                    $State.band_restart_pending = $true
                    Save-State
                    $null = & $Adapter.SetBand $target
                    if ([string](& $Adapter.GetBand) -ne $target) { return (Complete $false 'ConfigurationNotApplied' $true) }
                    $null = & $Adapter.Log "band: 5 GHz start rejected ($status); Auto fallback for $FallbackMinutes minutes"
                }
            }
        }
        Write-Diagnostics 'still-broken'
        return (Complete $false 'SharingUnavailable' $fallback)
    } catch {
        $reason = if ($_.Exception -is [TimeoutException]) { 'TimedOut' } else { 'OperationFailed' }
        $null = & $Adapter.Log "$reason`: $($_.Exception.Message)"
        # A timed-out async operation may still be running in Windows. Do not
        # issue a compensating start/stop until a later invocation observes it.
        Save-State
        return [pscustomobject]@{
            Success = $false; Reason = $reason; State = 'Unknown'; SavedBand = ''
            Fallback = $false; RestartPending = [bool]($State.band_restart_pending -or $State.restart_pending)
        }
    }
}

function Wait-HotspotTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Threading.Tasks.Task] $Task,
        [ValidateRange(1, 120000)] [int] $TimeoutMilliseconds = 15000,
        [scriptblock] $Cancel = {}
    )
    if (-not $Task.Wait($TimeoutMilliseconds)) {
        try { $null = & $Cancel } catch { }
        throw [TimeoutException]::new("Hotspot operation exceeded $TimeoutMilliseconds ms")
    }
    if ($Task.GetType().GetProperty('Result')) { return $Task.Result }
}

function New-HotspotSnapshot {
    [CmdletBinding()]
    param(
        [string] $State, [string] $Ssid, [string] $Band, [string] $Authentication,
        [int] $MaxClients, [object[]] $Clients = @(), [bool] $SharingHealthy,
        [int] $UptimeSeconds, [string] $LastStop, [string] $IdleOff,
        [string] $Fingerprint, [bool] $Enabled = $true, [bool] $RestartPending = $false,
        [string] $Uplink = '', [datetime] $Now = (Get-Date)
    )
    $safeClients = @(
        foreach ($client in @($Clients)) {
            if ($null -eq $client) { continue }
            $fields = @{}
            foreach ($key in 'name', 'mac', 'ip') {
                $fields[$key] = if ($client -is [Collections.IDictionary]) { [string]$client[$key] }
                    elseif ($client.PSObject.Properties[$key]) { [string]$client.$key } else { '' }
            }
            [pscustomobject]$fields
        }
    )
    [pscustomobject]@{
        schema_version = 1; producer = 'HotspotController'
        state = $State; ssid = $Ssid; band = $Band; band_source = 'saved-configuration'
        auth = $Authentication; max_clients = $MaxClients; client_count = $safeClients.Count
        clients = $safeClients; ics_ok = $SharingHealthy; ap_uptime_s = $UptimeSeconds
        last_stop = $LastStop; idle_off = $IdleOff; pass_fp = $Fingerprint
        uplink = $Uplink
        enabled = $Enabled; restart_pending = $RestartPending
        updated = $Now.ToString('HH:mm:ss'); observed_at = $Now.ToString('o')
    }
}

function Select-HotspotUplink {
    [CmdletBinding()]
    param(
        [object[]] $Candidates = @(),
        [string[]] $Preference = @(),
        [string] $Current = '',
        [bool] $Enabled = $true
    )
    $available = @{}
    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) { continue }
        $name = ''
        $usable = $true
        if ($candidate -is [Collections.IDictionary]) {
            if ($candidate.Contains('name')) { $name = [string]$candidate['name'] }
            if ($candidate.Contains('available')) { $usable = [bool]$candidate['available'] }
        } else {
            if ($candidate.PSObject.Properties['name']) { $name = [string]$candidate.name }
            if ($candidate.PSObject.Properties['available']) { $usable = [bool]$candidate.available }
        }
        if ($name -and $usable) { $available[$name] = $true }
    }
    if (-not $Enabled) {
        # Policy off: leave the Windows default link alone, but drop a stale choice.
        return [pscustomobject]@{ Name = ''; Source = 'disabled' }
    }
    foreach ($name in @($Preference)) {
        if ($name -and $available.ContainsKey([string]$name)) {
            return [pscustomobject]@{ Name = [string]$name; Source = 'preference' }
        }
    }
    if ($Current -and $available.ContainsKey($Current)) {
        return [pscustomobject]@{ Name = $Current; Source = 'current' }
    }
    return [pscustomobject]@{ Name = ''; Source = 'system' }
}

Export-ModuleMember -Function New-HotspotState, Set-HotspotIntent, Update-HotspotSession, Invoke-HotspotCommand, Wait-HotspotTask, New-HotspotSnapshot, Select-HotspotUplink
