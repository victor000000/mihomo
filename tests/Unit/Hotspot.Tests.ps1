BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'src\hotspot\Hotspot.Core.psm1') -Force
    $script:Now = [datetime]'2026-10-20T10:00:00'

    function New-FakeHotspot {
        param([string] $State = 'On', [string] $Band = 'FiveGigahertz')
        $device = @{
            State = $State; Band = $Band; Sharing = $true; Supported = $true
            Events = New-Object System.Collections.ArrayList
            Starts = New-Object System.Collections.Queue
            Stops = New-Object System.Collections.Queue
            ThrowOnSet = $false; ConfigurationError = $false; TimeoutOnStart = $false; StopStuck = $false
            StartStuck = $false; SetIgnored = $false; TransitionReads = 0; Persisted = @()
        }
        $adapter = @{
            GetState = {
                if ($device.TransitionReads -gt 0) { $device.TransitionReads--; return 'InTransition' }
                $device.State
            }.GetNewClosure()
            GetBand = { $device.Band }.GetNewClosure()
            SupportsBand = { param($Name) $device.Supported }.GetNewClosure()
            SetBand = {
                param($Name)
                [void]$device.Events.Add("set:$Name")
                if ($device.ThrowOnSet) { throw [TimeoutException]::new('fixture timeout') }
                if ($device.ConfigurationError) { throw [InvalidOperationException]::new('fixture configuration error') }
                if (-not $device.SetIgnored) { $device.Band = $Name }
            }.GetNewClosure()
            Start = {
                [void]$device.Events.Add('start')
                if ($device.TimeoutOnStart) { throw [TimeoutException]::new('fixture timeout') }
                $result = if ($device.Starts.Count) { $device.Starts.Dequeue() } else { 'Success' }
                if ($result -eq 'Exception') { throw [InvalidOperationException]::new('fixture transient start') }
                if ($result -eq 'Success') { $device.State = if ($device.StartStuck) { 'InTransition' } else { 'On' } }
                return $result
            }.GetNewClosure()
            Stop = {
                [void]$device.Events.Add('stop')
                $result = if ($device.Stops.Count) { $device.Stops.Dequeue() } else { 'Success' }
                if ($result -eq 'Success' -and -not $device.StopStuck) { $device.State = 'Off' }
                return $result
            }.GetNewClosure()
            SharingHealthy = { $device.Sharing }.GetNewClosure()
            Delay = { param($Seconds) [void]$device.Events.Add('wait') }.GetNewClosure()
            Persist = {
                param($Value)
                $device.Persisted += ($Value | ConvertTo-Json -Depth 6 -Compress)
            }.GetNewClosure()
            Log = { param($Message) [void]$device.Events.Add("log:$Message") }.GetNewClosure()
        }
        [pscustomobject]@{ Device = $device; Adapter = $adapter; State = (New-HotspotState) }
    }

    function Invoke-Fixture {
        param($Fixture, [string] $Action = 'ensure', [bool] $Restart = $false, [datetime] $At = $script:Now)
        Invoke-HotspotCommand -Action $Action -Adapter $Fixture.Adapter -State $Fixture.State -Now $At -PollAttempts 2 -RestartRequired $Restart
    }
}

Describe 'hotspot lifecycle with an isolated Windows adapter' {
    It 'leaves a healthy 5 GHz access point alone' {
        $f = New-FakeHotspot
        $r = Invoke-Fixture $f
        $r.Success | Should -BeTrue
        $r.Reason | Should -Be 'Healthy'
        @($f.Device.Events | Where-Object { $_ -in 'stop', 'start' -or $_ -like 'set:*' }).Count | Should -Be 0
    }

    It 'starts an Off access point and records its observed session' {
        $f = New-FakeHotspot -State Off
        $r = Invoke-Fixture $f start
        $r.Success | Should -BeTrue
        $r.State | Should -Be 'On'
        $f.State.ap_started | Should -Be $script:Now.ToString('o')
    }

    It 'repairs On without ICS rather than reporting start success' {
        $f = New-FakeHotspot
        $f.Device.Sharing = $false
        $r = Invoke-Fixture $f start
        $r.Success | Should -BeFalse
        $r.Reason | Should -Be 'SharingUnavailable'
        @($f.Device.Events | Where-Object { $_ -eq 'start' }).Count | Should -Be 2
    }

    It 'stops before starting when a live band changes' {
        $f = New-FakeHotspot -Band TwoPointFourGigahertz
        $r = Invoke-Fixture $f
        $r.Success | Should -BeTrue
        $events = @($f.Device.Events)
        [array]::IndexOf($events, 'stop') | Should -BeLessThan ([array]::IndexOf($events, 'start'))
        $f.Device.Band | Should -Be 'FiveGigahertz'
        $f.State.band_restart_pending | Should -BeFalse
    }

    It 'persists restart intent before changing the saved band' {
        $f = New-FakeHotspot -Band TwoPointFourGigahertz
        $null = Invoke-Fixture $f
        ($f.Device.Persisted[0] | ConvertFrom-Json).band_restart_pending | Should -BeTrue
    }

    It 'does not start after an unsuccessful stop' {
        $f = New-FakeHotspot -Band TwoPointFourGigahertz
        $f.Device.Stops.Enqueue('OperationInProgress')
        $r = Invoke-Fixture $f
        $r.Success | Should -BeFalse
        $r.Reason | Should -Be 'StopFailed'
        $f.Device.Events | Should -Not -Contain 'start'
        $f.State.band_restart_pending | Should -BeTrue
    }

    It 'keeps the original uptime when stopping fails' {
        $f = New-FakeHotspot -Band TwoPointFourGigahertz
        $original = $script:Now.AddHours(-1).ToString('o')
        $f.State.ap_started = $original
        $f.Device.Stops.Enqueue('OperationInProgress')
        $null = Invoke-Fixture $f
        $f.State.ap_started | Should -Be $original
        $f.State.ap_stopped | Should -Be ''
    }

    It 'does not equate a successful stop result with an observed Off state' {
        $f = New-FakeHotspot
        $f.Device.StopStuck = $true
        $r = Invoke-Fixture $f restart
        $r.Success | Should -BeFalse
        $r.Reason | Should -Be 'StopFailed'
        $f.Device.Events | Should -Not -Contain 'start'
    }

    It 'retries a pending band change on the next invocation' {
        $f = New-FakeHotspot -Band TwoPointFourGigahertz
        $f.Device.Stops.Enqueue('OperationInProgress')
        $null = Invoke-Fixture $f
        $f.Device.Band | Should -Be 'FiveGigahertz'
        $r = Invoke-Fixture $f
        $r.Success | Should -BeTrue
        $f.Device.Events | Should -Contain 'start'
        $f.State.band_restart_pending | Should -BeFalse
    }

    It 'preserves idle-fix restart intent after a failed stop' {
        $f = New-FakeHotspot
        $original = $script:Now.AddHours(-1).ToString('o')
        $f.State.ap_started = $original
        $f.State.idle_fix_at = $script:Now.ToString('o')
        $f.Device.Stops.Enqueue('OperationInProgress')
        $r = Invoke-Fixture $f ensure $true
        $r.Success | Should -BeFalse
        $f.State.ap_started | Should -Be $original
    }

    It 'plain stop clears session and disables watchdog resurrection' {
        $f = New-FakeHotspot
        $f.State.ap_started = $script:Now.AddHours(-1).ToString('o')
        $f.State.last_client_at = $f.State.ap_started
        $f.State.clients = @{ 'fixture-mac' = @{} }
        $r = Invoke-Fixture $f stop
        $r.Success | Should -BeTrue
        $f.State.enabled | Should -BeFalse
        $f.State.ap_started | Should -Be ''
        $f.State.ap_stopped | Should -Be $script:Now.ToString('o')
        $f.State.last_client_at | Should -Be ''
        $f.State.clients.Count | Should -Be 0
        $r2 = Invoke-Fixture $f
        $r2.Reason | Should -Be 'IntentionallyStopped'
        $f.Device.Events | Should -Not -Contain 'start'
    }

    It 'an explicit start overrides manual-stop intent' {
        $f = New-FakeHotspot -State Off
        $f.State.enabled = $false
        $r = Invoke-Fixture $f start
        $r.Success | Should -BeTrue
        $f.State.enabled | Should -BeTrue
    }

    It 'starts a fresh uptime after ordinary stop then start' {
        $f = New-FakeHotspot
        $f.State.ap_started = $script:Now.AddHours(-1).ToString('o')
        $null = Invoke-Fixture $f stop
        $later = $script:Now.AddMinutes(5)
        $null = Invoke-Fixture $f start $false $later
        $f.State.ap_started | Should -Be $later.ToString('o')
    }

    It 'uses Auto when the adapter cannot support 5 GHz' {
        $f = New-FakeHotspot -State Off -Band TwoPointFourGigahertz
        $f.Device.Supported = $false
        $r = Invoke-Fixture $f start
        $r.Success | Should -BeTrue
        $r.Fallback | Should -BeTrue
        $f.Device.Band | Should -Be 'Auto'
        $f.State.band_retry_after | Should -Not -BeNullOrEmpty
    }

    It 'recovers availability after a band-specific start rejection' {
        $f = New-FakeHotspot -State Off
        $f.Device.Starts.Enqueue('BandInterference')
        $f.Device.Starts.Enqueue('Success')
        $r = Invoke-Fixture $f start
        $r.Success | Should -BeTrue
        $r.Fallback | Should -BeTrue
        $f.Device.Band | Should -Be 'Auto'
    }

    It 'does not flap a working fallback every watchdog tick' {
        $f = New-FakeHotspot -State Off
        $f.Device.Starts.Enqueue('RadioRestriction')
        $null = Invoke-Fixture $f start
        $f.Device.Events.Clear()
        $r = Invoke-Fixture $f ensure $false ($script:Now.AddMinutes(2))
        $r.Success | Should -BeTrue
        $f.Device.Events | Should -Not -Contain 'stop'
        $f.Device.Events | Should -Not -Contain 'set:FiveGigahertz'
    }

    It 'retries the preferred band after the fallback cooldown' {
        $f = New-FakeHotspot -State Off
        $f.Device.Starts.Enqueue('RadioRestriction')
        $null = Invoke-Fixture $f start
        $f.Device.Events.Clear()
        $r = Invoke-Fixture $f ensure $false ($script:Now.AddMinutes(31))
        $r.Success | Should -BeTrue
        $f.Device.Events | Should -Contain 'set:FiveGigahertz'
        $f.State.fallback_band | Should -Be ''
    }

    It 'does not retry or start after a configuration timeout' {
        $f = New-FakeHotspot -Band TwoPointFourGigahertz
        $f.Device.ThrowOnSet = $true
        $r = Invoke-Fixture $f
        $r.Success | Should -BeFalse
        $r.Reason | Should -Be 'TimedOut'
        $f.Device.Events | Should -Not -Contain 'stop'
        $f.Device.Events | Should -Not -Contain 'start'
        $f.State.band_restart_pending | Should -BeTrue
    }

    It 'does not send compensating operations after a start timeout' {
        $f = New-FakeHotspot -State Off
        $f.Device.TimeoutOnStart = $true
        $r = Invoke-Fixture $f start
        $r.Reason | Should -Be 'TimedOut'
        @($f.Device.Events | Where-Object { $_ -eq 'start' }).Count | Should -Be 1
        $f.Device.Events | Should -Not -Contain 'stop'
    }

    It 'reports retained-band fallback when Windows ignores a preference' {
        $f = New-FakeHotspot -Band TwoPointFourGigahertz
        $f.Device.SetIgnored = $true
        $r = Invoke-Fixture $f
        $r.Success | Should -BeTrue
        $r.Fallback | Should -BeTrue
        $r.SavedBand | Should -Be 'TwoPointFourGigahertz'
        $f.Device.Events | Should -Not -Contain 'stop'
    }

    It 'fails when a start remains InTransition' {
        $f = New-FakeHotspot -State Off
        $f.Device.StartStuck = $true
        $r = Invoke-Fixture $f start
        $r.Success | Should -BeFalse
    }

    It 'recovers on the saved band after a non-timeout configuration fault' {
        $f = New-FakeHotspot -State Off -Band TwoPointFourGigahertz
        $f.Device.ConfigurationError = $true
        $r = Invoke-Fixture $f start
        $r.Success | Should -BeTrue
        $r.Fallback | Should -BeTrue
        $f.Device.Events | Should -Contain 'start'
    }

    It 'retries a transient start exception with settling time' {
        $f = New-FakeHotspot -State Off
        $f.Device.Starts.Enqueue('Exception')
        $r = Invoke-Fixture $f start
        $r.Success | Should -BeTrue
        @($f.Device.Events | Where-Object { $_ -eq 'start' }).Count | Should -Be 2
        $f.Device.Events | Should -Contain 'wait'
    }

    It 'backs off between busy status retries' {
        $f = New-FakeHotspot -State Off
        $f.Device.Starts.Enqueue('OperationInProgress')
        $f.Device.Starts.Enqueue('OperationInProgress')
        $r = Invoke-Fixture $f start
        $r.Success | Should -BeFalse
        @($f.Device.Events | Where-Object { $_ -eq 'wait' }).Count | Should -BeGreaterThan 0
    }

    It 'converges a failed manual stop on the next watchdog tick' {
        $f = New-FakeHotspot
        $f.Device.Stops.Enqueue('OperationInProgress')
        (Invoke-Fixture $f stop).Success | Should -BeFalse
        $r = Invoke-Fixture $f
        $r.Success | Should -BeTrue
        $r.State | Should -Be 'Off'
        $f.Device.Events | Should -Not -Contain 'start'
        @($f.Device.Events | Where-Object { $_ -eq 'stop' }).Count | Should -Be 2
    }

    It 'preserves idle restart intent when the original start time is unknown' {
        $f = New-FakeHotspot
        $f.State.ap_started = ''
        $f.Device.Stops.Enqueue('OperationInProgress')
        (Invoke-Fixture $f ensure $true).Success | Should -BeFalse
        $f.State.restart_pending | Should -BeTrue
        (Invoke-Fixture $f).Success | Should -BeTrue
        $f.Device.Events | Should -Contain 'start'
        $f.State.restart_pending | Should -BeFalse
    }

    It 'does not mutate an access point while a previous operation is transitioning' {
        $f = New-FakeHotspot -Band TwoPointFourGigahertz
        $f.Device.TransitionReads = 3
        $r = Invoke-Fixture $f
        $r.Reason | Should -Be 'TimedOut'
        @($f.Device.Events | Where-Object { $_ -eq 'start' -or $_ -eq 'stop' -or $_ -like 'set:*' }).Count | Should -Be 0
    }

    It 'does not confuse a powered-off radio with band incompatibility' {
        $f = New-FakeHotspot -State Off
        $f.Device.Starts.Enqueue('WiFiDeviceOff')
        $f.Device.Starts.Enqueue('WiFiDeviceOff')
        $r = Invoke-Fixture $f start
        $r.Success | Should -BeFalse
        $f.Device.Band | Should -Be 'FiveGigahertz'
        $f.State.band_retry_after | Should -Be ''
    }

    It 'records start intent before an unavailable adapter can reject the command' {
        $f = New-FakeHotspot -State Off
        $f.State.enabled = $false
        $f.Adapter.GetState = { throw 'fixture profile unavailable' }
        (Invoke-Fixture $f start).Success | Should -BeFalse
        $f.State.enabled | Should -BeTrue
    }

    It 'explicit intent does not need an available device or connection profile' {
        $state = New-HotspotState
        (Set-HotspotIntent -State $state -Action stop) | Should -BeTrue
        $state.enabled | Should -BeFalse
        (Set-HotspotIntent -State $state -Action ensure) | Should -BeFalse
        $state.enabled | Should -BeFalse
        (Set-HotspotIntent -State $state -Action start) | Should -BeTrue
        $state.enabled | Should -BeTrue
    }

    It 'migrates old persisted state by adding new fields' {
        $f = New-FakeHotspot
        $f.State = @{ ap_started = ''; ap_stopped = ''; clients = @{} }
        $r = Invoke-Fixture $f
        $r.Success | Should -BeTrue
        $f.State.ContainsKey('enabled') | Should -BeTrue
        $f.State.ContainsKey('band_restart_pending') | Should -BeTrue
    }

    It 'rejects an incomplete adapter before touching the device' {
        { Invoke-HotspotCommand start @{} (New-HotspotState) } | Should -Throw '*Missing hotspot adapter*'
    }
}

Describe 'bounded asynchronous waits' {
    It 'returns a completed task result' {
        $task = [Threading.Tasks.Task]::FromResult([string]'Success')
        Wait-HotspotTask -Task $task | Should -Be 'Success'
    }

    It 'cancels an incomplete task and raises a timeout' {
        $source = New-Object 'System.Threading.Tasks.TaskCompletionSource[string]'
        $flag = @{ Cancelled = $false }
        { Wait-HotspotTask -Task $source.Task -TimeoutMilliseconds 1 -Cancel { $flag.Cancelled = $true } } | Should -Throw '*exceeded*'
        $flag.Cancelled | Should -BeTrue
    }
}

Describe 'hotspot snapshot serialization' {
    It 'round trips quotes, newlines, backslashes and Unicode without exposing a passphrase' {
        $ssid = "fixture`"`n\\ssid"
        $clients = @([pscustomobject]@{ name = "client`"`tname"; mac = 'fixture'; ip = '192.168.137.2'; passphrase = 'REPLACE-FIXTURE' })
        $snapshot = New-HotspotSnapshot -State On -Ssid $ssid -Band FiveGigahertz -Clients $clients -SharingHealthy $true -Now $script:Now
        $back = $snapshot | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        $back.ssid | Should -BeExactly $ssid
        $back.clients[0].name | Should -BeExactly $clients[0].name
        $back.band_source | Should -Be 'saved-configuration'
        $back.schema_version | Should -Be 1
        @($back.clients[0].PSObject.Properties.Name) | Should -Not -Contain 'passphrase'
        @($back.PSObject.Properties.Name) | Should -Not -Contain 'passphrase'
    }

    It 'keeps an empty clients collection as an array' {
        $snapshot = New-HotspotSnapshot -State Off -Clients @() -Now $script:Now
        $back = $snapshot | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        @($back.clients).Count | Should -Be 0
        $back.client_count | Should -Be 0
    }

    It 'publishes the shared uplink and keeps the traffic baselines in state' {
        $state = New-HotspotState
        $state.uplink | Should -Be ''
        $state.ContainsKey('traffic_at') | Should -BeTrue
        $state.ContainsKey('traffic_rx') | Should -BeTrue
        $state.ContainsKey('wlan_seen') | Should -BeTrue
        $snapshot = New-HotspotSnapshot -State On -Uplink 'jd_5G' -Now $script:Now
        ($snapshot | ConvertTo-Json -Depth 4 | ConvertFrom-Json).uplink | Should -Be 'jd_5G'
    }
}

Describe 'hotspot uplink selection' {
    BeforeAll {
        function New-Uplink([string] $Name, [bool] $Available = $true) {
            [pscustomobject]@{ name = $Name; available = $Available }
        }
    }

    It 'takes the first usable link from the ordered policy' {
        $c = @((New-Uplink 'win_turbo_phone'), (New-Uplink 'jd_5G'), (New-Uplink 'pisen_2026_03'))
        $r = Select-HotspotUplink -Candidates $c -Preference @('jd_5G', 'pisen_2026_03') -Current 'win_turbo_phone'
        $r.Name | Should -Be 'jd_5G'
        $r.Source | Should -Be 'preference'
    }

    It 'skips a preferred link that is not usable' {
        $c = @((New-Uplink 'jd_5G' $false), (New-Uplink 'pisen_2026_03'), (New-Uplink 'win_turbo_phone'))
        $r = Select-HotspotUplink -Candidates $c -Preference @('jd_5G', 'pisen_2026_03') -Current ''
        $r.Name | Should -Be 'pisen_2026_03'
    }

    It 'keeps the applied link when no preference is usable' {
        $c = @((New-Uplink 'pisen_2026_10'), (New-Uplink 'win_turbo_phone'))
        $r = Select-HotspotUplink -Candidates $c -Preference @('jd_5G') -Current 'pisen_2026_10'
        $r.Name | Should -Be 'pisen_2026_10'
        $r.Source | Should -Be 'current'
    }

    It 'falls back to the Windows default when nothing is known' {
        $r = Select-HotspotUplink -Candidates @() -Preference @('jd_5G') -Current ''
        $r.Name | Should -Be ''
        $r.Source | Should -Be 'system'
    }

    It 'leaves the default link alone when the policy is disabled' {
        $c = @((New-Uplink 'jd_5G'))
        $r = Select-HotspotUplink -Candidates $c -Preference @('jd_5G') -Current 'jd_5G' -Enabled $false
        $r.Name | Should -Be ''
        $r.Source | Should -Be 'disabled'
    }

    It 'accepts hashtable candidates as well as objects' {
        $c = @(@{ name = 'jd_5G'; available = $true })
        (Select-HotspotUplink -Candidates $c -Preference @('jd_5G')).Name | Should -Be 'jd_5G'
    }
}
