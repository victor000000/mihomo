BeforeAll {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $repo 'src\NetStack\NetStack.psm1') -Force
}

Describe 'Shared dashboard and traffic classification regressions' {
    It 'recognises every current free outbound under every current policy group' {
        foreach ($node in @('aliyun-native', 'aliyun-la', 'aliyun-tokyo', 'omr')) {
            foreach ($group in @('HYPOMUX-PATH', 'AUTO', 'STORE', 'LINGODA-HK', 'LINGODA',
                    'CHATGPT', 'DEV', 'DATA', 'PROXY', 'PAID', 'BENCH')) {
                $route = Get-ChainRoute @($node, $group)
                $route.label | Should -Be $group
                $route.kind | Should -Be 'hypomux'
                $route.carried | Should -BeTrue
                $route.dialer | Should -BeFalse
                $route.TrafficRoute | Should -Be 'proxy'
                $route.Bucket | Should -Be 'free'
            }
        }
    }

    It 'labels paid nodes by the innermost selector and keeps the spend tier' {
        $route = Get-ChainRoute @('Hong Kong|HK2022|AT', 'LINGODA-HK', 'LINGODA', 'AUTO')
        $route.label | Should -Be 'LINGODA-HK'
        $route.kind | Should -Be 'proxy'
        $route.Bucket | Should -Be 'paid'
        $route.TrafficRoute | Should -Be 'proxy'
        (Get-ChainRoute @('Hong Kong|HK2022|AT', 'aliyun-la')).Bucket | Should -Be 'paid'
    }

    It 'separates the raw dialer socket from carried direct internet traffic' {
        $own = Get-ChainRoute @('hypomux')
        $own.kind | Should -Be 'dialer'
        $own.dialer | Should -BeTrue
        $own.carried | Should -BeFalse
        $carried = Get-ChainRoute @('hypomux', 'DISPATCH')
        $carried.kind | Should -Be 'hypomux'
        $carried.carried | Should -BeTrue
        $carried.TrafficRoute | Should -Be 'direct'
        $carried.Bucket | Should -Be 'local'
    }

    It 'retains legacy display classification without substring-based accounting' {
        $legacy = Get-ChainRoute @('direct-nic50', 'DIRECT-LB')
        $legacy.kind | Should -Be 'direct'
        $legacy.TrafficRoute | Should -Be 'other'
        foreach ($name in @('MY-AUTO', 'not-aliyun-native', 'not-hypomux', 'DIRECT-LB-extra')) {
            $route = Get-ChainRoute @($name)
            $route.kind | Should -Be 'other'
            $route.TrafficRoute | Should -Be 'other'
        }
        (Get-ChainRoute $null).label | Should -Be 'unknown'
    }

    It 'reads real dictionary keys (including false, zero and property-name collisions)' {
        foreach ($object in @(@{ id = 'a'; Count = 0; enabled = $false; missing = $null },
                [ordered]@{ id = 'a'; Count = 0; enabled = $false; missing = $null },
                [pscustomobject]@{ id = 'a'; Count = 0; enabled = $false; missing = $null })) {
            Get-SafeProperty $object 'id' 'fallback' | Should -Be 'a'
            Get-SafeProperty $object 'Count' 9 | Should -Be 0
            Get-SafeProperty $object 'enabled' $true | Should -BeFalse
            Get-SafeProperty $object 'missing' 'fallback' | Should -Be 'fallback'
            Get-SafeProperty $object 'absent' 'fallback' | Should -Be 'fallback'
        }
    }

    It 'resets Live per poll while keeping byte totals and forgetting closed IDs' {
        $state = New-TrafficState
        $connection = @{ id = 'same'; chains = @('omr', 'CHATGPT'); download = 100; upload = 5 }
        $null = Update-ConnectionTraffic @($connection) $state
        $null = Update-ConnectionTraffic @($connection) $state
        $state.Live.proxy | Should -Be 1 -Because 'a live connection is not two poll samples'
        $state.Totals.proxy.down | Should -Be 100
        $connection.download = 140
        $null = Update-ConnectionTraffic @($connection) $state
        $state.Totals.proxy.down | Should -Be 140
        $null = Update-ConnectionTraffic @() $state
        $state.Live.proxy | Should -Be 0
        $state.Live.direct | Should -Be 0
        $state.Live.other | Should -Be 0
        $state.Seen.Count | Should -Be 0
        $state.Totals.proxy.down | Should -Be 140
    }

    It 'uses the same classifier for summary, cumulative traffic and dashboard routes' {
        $connections = @(
            @{ id = 'free'; chains = @('aliyun-tokyo', 'DEV'); download = 200; upload = 2; metadata = @{ host = 'free.example' } },
            @{ id = 'paid'; chains = @('Japan|JP2022|AT', 'LINGODA'); download = 300; upload = 3; metadata = @{ host = 'paid.example' } },
            @{ id = 'direct'; chains = @('hypomux', 'DISPATCH'); download = 400; upload = 4; metadata = @{ host = 'direct.example' } },
            @{ id = 'other'; chains = @('NOT-AUTO'); download = 500; upload = 5; metadata = @{ host = 'unknown.example' } }
        )
        $summary = Get-ConnectionSummary $connections
        $summary.Active | Should -Be 4
        $summary.ProxyActive | Should -Be 2
        $summary.ProxyBytes | Should -Be 500
        @($summary.TopProxy).Count | Should -Be 2
        $summary.TopDirect[0].Name | Should -Be 'direct.example'
        $state = New-TrafficState
        $null = Update-ConnectionTraffic $connections $state
        $state.Totals.proxy.down | Should -Be 500
        $state.Totals.direct.down | Should -Be 400
        $state.Totals.other.down | Should -Be 500
    }

    It 'does not present expected TUN policy chains as observed HypoMux carrying' {
        $route = Get-ChainRoute @('omr', 'CHATGPT')
        $route.carried | Should -BeTrue -Because 'the retained classifier field is a chain-based expectation'
        $route.LegacyCarried | Should -BeFalse
        $tun = Get-HypoMuxCarryingState -TunUp $true -ExpectedConnections 42 -LegacyConnections 0
        $tun.Carrying | Should -BeNullOrEmpty
        $tun.CarriedConnections | Should -BeNullOrEmpty
        $tun.Basis | Should -Be 'unobserved-tun'
        $tun.ExpectedConnections | Should -Be 42
        $tun.ExpectedBasis | Should -Be 'chain-based'
        (Get-ChainRoute @('hypomux')).LegacyCarried | Should -BeFalse
        (Get-ChainRoute @('hypomux', 'DISPATCH')).LegacyCarried | Should -BeTrue
        $legacy = Get-HypoMuxCarryingState -TunUp $false -ExpectedConnections 45 -LegacyConnections 3
        $legacy.Carrying | Should -BeTrue
        $legacy.CarriedConnections | Should -Be 3
        $legacy.Basis | Should -Be 'legacy-socks-hop'
    }

    It 'requires fresh ICS-positive evidence before showing hotspot health as ok' {
        $now = [datetimeoffset]'2026-10-20T14:00:00Z'
        $snapshot = @{ ics_ok = $false; observed_at = '2026-10-20T21:59:40+08:00';
            schema_version = 1; producer = 'Hotspot'; ssid = 'fixture'; band_source = 'saved-configuration';
            enabled = $true; restart_pending = $false }
        $health = Get-HotspotState -AdapterUp $true -Snapshot $snapshot -SnapshotAgeSec 0 -Now $now
        $health.State | Should -Be 'bad'
        $health.IcsOk | Should -BeFalse
        $health.SnapshotFresh | Should -BeTrue
        $health.SnapshotAge | Should -Be 20
        $health.ObservedAt | Should -Be '2026-10-20T21:59:40+08:00'
        $health.SchemaVersion | Should -Be 1
        $health.Producer | Should -Be 'Hotspot'
        $health.BandSource | Should -Be 'saved-configuration'
        $health.Enabled | Should -BeTrue
        $health.RestartPending | Should -BeFalse
        $snapshot.ics_ok = $true
        (Get-HotspotState -AdapterUp $true -Snapshot $snapshot -Now $now).State | Should -Be 'ok'
    }

    It 'never hides stale or missing hotspot evidence behind an up adapter' {
        $now = [datetimeoffset]'2026-10-20T14:00:00Z'
        $snapshot = [pscustomobject]@{ ics_ok = $true; observed_at = '2026-10-20T13:00:00Z';
            schema_version = 1; producer = 'Hotspot'; ssid = 'stale fixture' }
        $health = Get-HotspotState -AdapterUp $true -Snapshot $snapshot -SnapshotAgeSec 0 -Now $now
        $health.State | Should -Be 'warn'
        $health.SnapshotFresh | Should -BeFalse
        $health.SnapshotAge | Should -Be 3600 -Because 'a recent file copy cannot freshen an old observation'
        $health.Ssid | Should -Be ''
        $health.ObservedAt | Should -Be '2026-10-20T13:00:00Z'
        $health.Producer | Should -Be 'Hotspot'
        $health.IcsOk | Should -BeTrue -Because 'the old ICS observation remains explicitly marked stale'
        (Get-HotspotState -AdapterUp $true -Snapshot $null -Now $now).State | Should -Be 'warn'
        $snapshot.observed_at = 'invalid timestamp'
        (Get-HotspotState -AdapterUp $true -Snapshot $snapshot -SnapshotAgeSec 0 -Now $now).SnapshotFresh | Should -BeFalse
        $snapshot.observed_at = '2026-10-20T15:00:00Z'
        (Get-HotspotState -AdapterUp $true -Snapshot $snapshot -SnapshotAgeSec 0 -Now $now).State | Should -Be 'warn'
    }

    It 'compares log timestamps as instants regardless of caller offset' {
        $lines = @(
            'time="2026-10-10T21:55:00+08:00" level=warning msg="[TCP] dial LOCAL (match Match/) a --> recent.example:443 error: timeout"',
            'time="2026-10-10T13:20:00Z" level=warning msg="[TCP] dial LOCAL (match Match/) a --> old.example:443 error: timeout"'
        )
        foreach ($now in @([datetimeoffset]'2026-10-10T22:00:00+08:00',
                [datetimeoffset]'2026-10-10T14:00:00Z', [datetime]'2026-10-10T14:00:00Z')) {
            $candidates = @(Get-FailedRouteCandidate -Lines $lines -Now $now -SinceMinutes 30)
            $candidates.Count | Should -Be 1
            $candidates[0].Domain | Should -Be 'recent.example'
        }
    }
}
