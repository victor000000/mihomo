<#
.SYNOPSIS
    Unit tests for src\NetStack\Spend.psm1 - paid/free attribution for the 4:1 mix.

.DESCRIPTION
    The mix is 4 paid 911 exits to 1 free Aliyun share, and until now nothing measured what that
    meant in BYTES. mihomo cannot weight group members (the ratio is the member count) and its
    API has no per-group counters - only connections, each carrying the chain it took. So
    attribution is the whole job, and it is pure, which is why these cases need no proxy running.

    The failure mode this guards is quiet and expensive: a mix that drifts means either a metered
    allowance burning faster than intended, or traffic silently riding the free path because the
    paid exits are unhealthy. Both look like "the network works".

    Two lessons from the first live run on 2026-10-11 are encoded here as gates:
      * a connection keeps the member it was assigned at CONNECT time for its whole life, so a few
        large streams dominate a byte share - one window read 23.9 MB free against 0.1 MB paid
        while 30 fresh connections distributed 24 paid : 7 free, exactly the design;
      * DIRECT bytes must be excluded from the share, or a domestic download makes the paid share
        look tiny without anything having changed.
#>

BeforeAll {
    $script:ModulePath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'src\NetStack\Spend.psm1'
    if (-not (Test-Path -LiteralPath $script:ModulePath)) { throw "module not found: $($script:ModulePath)" }
    Import-Module $script:ModulePath -Force

    # A sample big enough to be judged: more than 20 connections and more than 8 MB of proxied
    # bytes, in the requested ratio. Helper so each test states only what it is about.
    function New-MixSamples {
        param([int] $Paid = 20, [int] $Free = 5, [int64] $EachBytes = 512KB, [int64] $DirectBytes = 0)
        $s = @()
        1..$Paid | ForEach-Object { $s += @{ Chain = @('香港|HK2022|AT', 'AUTO'); Download = $EachBytes } }
        1..$Free | ForEach-Object { $s += @{ Chain = @('aliyun-native', 'AUTO'); Download = $EachBytes } }
        if ($DirectBytes -gt 0) { $s += @{ Chain = @('DIRECT'); Download = $DirectBytes } }
        return $s
    }
}

Describe 'Get-ChainBucket' {
    It 'attributes native adapter replicas correctly' {
        Get-ChainBucket -Chain @('HK2022|HK2022|AT [jd_5G]','911-POOL','AUTO') | Should -Be 'paid'
        Get-ChainBucket -Chain @('BALANCED-pisen_2026_10','TOKYO-POOL','AUTO') | Should -Be 'free'
        Get-ChainBucket -Chain @('LA-win_turbo_phone','LA-POOL','AUTO') | Should -Be 'free'
    }
    It 'calls a 911 subscription exit paid' {
        Get-ChainBucket -Chain @('香港|HK2022|AT', 'AUTO', 'DISPATCH') | Should -Be 'paid'
        Get-ChainBucket -Chain @('德国|GE2012|AT', 'DATA') | Should -Be 'paid'
    }

    It 'finds the paid hop wherever it sits in the chain' {
        # mihomo lists the handling outbound first, then its groups; the node can be anywhere.
        Get-ChainBucket -Chain @('AUTO', '香港|HK2022|AT') | Should -Be 'paid'
    }

    It 'calls the Aliyun tunnel free' {
        Get-ChainBucket -Chain @('aliyun-native', 'AUTO', 'DISPATCH') | Should -Be 'free'
    }

    It 'calls every free path free, not only aliyun-native' {
        # Measured 2026-10-18: the live status snapshot carried aliyun-la x31 and omr x4,
        # all filed under `other`, which inflated the paid share the drift gate reads.
        foreach ($hop in @('aliyun-native', 'aliyun-la', 'aliyun-tokyo', 'omr')) {
            Get-ChainBucket -Chain @($hop, 'CHATGPT') | Should -Be 'free' -Because "$hop is a free path, not metered quota"
        }
    }

    It 'calls direct internet local, however it is spelled' {
        # Measured on the first live run: DISPATCH[hypomux] is where most real traffic goes, and
        # filing it under `other` reported 42 MB as unclassified when it was simply direct.
        Get-ChainBucket -Chain @('DIRECT', 'DISPATCH') | Should -Be 'local'
        Get-ChainBucket -Chain @('hypomux', 'DISPATCH') | Should -Be 'local'
        Get-ChainBucket -Chain @('hypomux') | Should -Be 'local'
        Get-ChainBucket -Chain @('LOCAL') | Should -Be 'local'
    }

    It 'prefers paid over free when both appear, because the bytes left through the paid hop' {
        Get-ChainBucket -Chain @('AUTO', 'aliyun-native', 'DISPATCH') | Should -Be 'free'
        Get-ChainBucket -Chain @('香港|HK2022|AT', 'aliyun-native') | Should -Be 'paid'
    }

    It 'does not guess a bucket for an unknown node' {
        # A benchmark target or a provider added later must not be silently filed as paid or free:
        # that would move spend between buckets without anyone deciding to.
        Get-ChainBucket -Chain @('hy2-upstream', 'BENCH') | Should -Be 'other'
        Get-ChainBucket -Chain @('some-new-node') | Should -Be 'other'
    }

    It 'does not treat a name that merely contains a country code as paid' {
        Get-ChainBucket -Chain @('HK2022') | Should -Be 'other'
        Get-ChainBucket -Chain @('aliyun-la|HK2022|ATX') | Should -Be 'other'
    }

    It 'handles an empty or null chain without throwing' {
        Get-ChainBucket -Chain @() | Should -Be 'other'
        Get-ChainBucket -Chain $null | Should -Be 'other'
        Get-ChainBucket -Chain @('', $null) | Should -Be 'other'
    }
}

Describe 'Add-SpendSample' {
    BeforeAll {
        $script:Paid = @{ Chain = @('香港|HK2022|AT', 'AUTO'); Upload = 1000; Download = 5MB }
        $script:Free = @{ Chain = @('aliyun-native', 'AUTO'); Upload = 500; Download = 1MB }
    }

    It 'starts from a null state instead of failing' {
        $s = Add-SpendSample -State $null -Samples @($script:Paid) -Day '2026-10-11'
        $s.Day | Should -Be '2026-10-11'
        $s.PaidBytes | Should -Be (5MB + 1000)
        $s.Connections | Should -Be 1
        $s.PaidConnections | Should -Be 1
    }

    It 'adds up and down into one bucket' {
        $s = New-SpendState -Day '2026-10-11'
        $s = Add-SpendSample -State $s -Samples @($script:Paid, $script:Free)
        $s.PaidBytes | Should -Be (5MB + 1000)
        $s.FreeBytes | Should -Be (1MB + 500)
        $s.Connections | Should -Be 2
        $s.PaidConnections | Should -Be 1
    }

    It 'reads hashtable samples as well as objects, because callers write both' {
        # The first version tested `$s.PSObject.Properties.Name`, which is TRUE for a
        # PSCustomObject but never for a hashtable (its PSObject properties are Count/Keys/Values),
        # so every hashtable sample contributed ZERO bytes - nine tests caught it at once. mihomo's
        # JSON gives PSCustomObjects, PowerShell callers write hashtables.
        $s = New-SpendState -Day '2026-10-11'
        $s = Add-SpendSample -State $s -Samples @([pscustomobject]@{ Chain = @('香港|HK2022|AT'); Upload = 0; Download = 2MB })
        $s.PaidBytes | Should -Be 2MB
    }

    It 'ignores null samples and negative byte counts' {
        $s = New-SpendState -Day '2026-10-11'
        $s = Add-SpendSample -State $s -Samples @($null, @{ Chain = @('DIRECT'); Upload = -5; Download = -5 })
        $s.LocalBytes | Should -Be 0
        $s.Connections | Should -Be 1
    }

    It 'rolls the day over and keeps yesterday in History' {
        $s = New-SpendState -Day '2026-10-11'
        $s = Add-SpendSample -State $s -Samples @($script:Paid) -Day '2026-10-11'
        $s = Add-SpendSample -State $s -Samples @($script:Free) -Day '2026-10-12'
        $s.Day | Should -Be '2026-10-12'
        $s.PaidBytes | Should -Be 0
        $s.FreeBytes | Should -Be (1MB + 500)
        $s.History.Count | Should -Be 1
        $s.History[0].Day | Should -Be '2026-10-11'
        $s.History[0].PaidBytes | Should -Be (5MB + 1000)
    }

    It 'does not record a day that saw no traffic' {
        $s = New-SpendState -Day '2026-10-10'
        $s = Add-SpendSample -State $s -Samples @() -Day '2026-10-11'
        $s.History.Count | Should -Be 0
    }

    It 'survives a round trip through JSON' {
        $s = New-SpendState -Day '2026-10-11'
        $s = Add-SpendSample -State $s -Samples @($script:Paid, $script:Free)
        $back = ($s | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
        $back.PaidBytes | Should -Be $s.PaidBytes
        $s2 = Add-SpendSample -State $back -Samples @($script:Paid)
        $s2.PaidBytes | Should -Be (2 * (5MB + 1000))
    }

    It 'treats a damaged state object as a fresh one rather than throwing' {
        $s = Add-SpendSample -State ([pscustomobject]@{ nonsense = $true }) -Samples @($script:Paid) -Day '2026-10-11'
        $s.PaidBytes | Should -Be (5MB + 1000)
    }
}

Describe 'Spend snapshot reliability regressions' {
    BeforeAll {
        function New-SpendConnection([string] $Id, [int64] $Bytes) {
            @{ id = $Id; chains = @('aliyun-la', 'CHATGPT'); upload = 0; download = $Bytes }
        }
    }

    It 'keeps lifetime baselines across midnight and charges only new bytes on the next poll' {
        $s = Update-SpendConnections -State $null -Connections @((New-SpendConnection 'long' 1000)) -Day '2026-10-11'
        $s = Update-SpendConnections -State $s -Connections @((New-SpendConnection 'long' 1200)) -Day '2026-10-12'
        $s.FreeBytes | Should -Be 200
        $s.OpenConnections['long'] | Should -Be 1200
        $s.History[0].FreeBytes | Should -Be 1000
        $s = $s | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        $s = Update-SpendConnections -State $s -Connections @((New-SpendConnection 'long' 1250)) -Day '2026-10-12'
        $s.FreeBytes | Should -Be 250 -Because 'the midnight state must not lose OpenConnections'
        $s.Connections | Should -Be 1
    }

    It 'preserves baselines during an outage spanning midnight' {
        $s = Update-SpendConnections -State $null -Connections @((New-SpendConnection 'long' 5000)) -Day '2026-10-11'
        $s = Add-SpendSample -State $s -Samples @() -Day '2026-10-12'
        $s.OpenConnections['long'] | Should -Be 5000
        $s = Update-SpendConnections -State $s -Connections @((New-SpendConnection 'long' 5500)) -Day '2026-10-12'
        $s.FreeBytes | Should -Be 500
    }

    It 'does not turn repeated long-lived connections into a statistically meaningful mix' {
        $s = New-SpendState -Day '2026-10-11'
        foreach ($poll in 1..30) {
            $s = Add-SpendSample -State $s -Day '2026-10-11' -Samples @(
                @{ Id = 'paid-stream'; Chain = @('Hong Kong|HK2022|AT'); Download = 1KB },
                @{ Id = 'free-stream'; Chain = @('omr'); Download = 1MB }
            )
        }
        $s.Connections | Should -Be 2 -Because 'drift gate counts distinct IDs, not 60 poll samples'
        $s.PaidConnections | Should -Be 1
        (Format-SpendReport $s).Drift | Should -BeFalse
        $s = $s | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        $s = Add-SpendSample -State $s -Day '2026-10-11' -Samples @(
            @{ Id = 'paid-stream'; Chain = @('Hong Kong|HK2022|AT'); Download = 1KB })
        $s.Connections | Should -Be 2
        $s.PaidConnections | Should -Be 1
    }

    It 'counts a zero-delta connection once and resets daily identity without resetting lifetime bytes' {
        $s = Update-SpendConnections -State $null -Connections @((New-SpendConnection 'idle' 0)) -Day '2026-10-11'
        $s = Update-SpendConnections -State $s -Connections @((New-SpendConnection 'idle' 0)) -Day '2026-10-11'
        $s.Connections | Should -Be 1
        $s = Update-SpendConnections -State $s -Connections @((New-SpendConnection 'idle' 40)) -Day '2026-10-12'
        $s.Connections | Should -Be 1
        $s.FreeBytes | Should -Be 40
    }

    It 'retains legacy no-ID sample semantics and reads old states without identity metadata' {
        $old = [pscustomobject]@{ Day = '2026-10-11'; PaidBytes = 10; FreeBytes = 0; LocalBytes = 0;
            OtherBytes = 0; Connections = 1; PaidConnections = 1; History = @(); Updated = $null }
        $s = Add-SpendSample -State $old -Day '2026-10-11' -Samples @(
            @{ Chain = @('omr'); Download = 5 }, @{ Chain = @('omr'); Download = 5 })
        $s.FreeBytes | Should -Be 10
        $s.Connections | Should -Be 3
        $s = Update-SpendConnections -State $s -Day '2026-10-11' -Connections @((New-SpendConnection 'new' 30))
        $s.FreeBytes | Should -Be 40
        $s.Connections | Should -Be 4
    }

    It 'drops closed baselines, clamps backwards counters, and ignores duplicate snapshot IDs' {
        $s = Update-SpendConnections -State $null -Connections @((New-SpendConnection 'a' 1000)) -Day '2026-10-11'
        $s = Update-SpendConnections -State $s -Connections @((New-SpendConnection 'a' 10), (New-SpendConnection 'a' 10)) -Day '2026-10-11'
        $s.FreeBytes | Should -Be 1000
        $s.Connections | Should -Be 1
        $s = Update-SpendConnections -State $s -Connections @() -Day '2026-10-11'
        $s.OpenConnections.Count | Should -Be 0
        $s.Connections | Should -Be 1
    }
}

Describe 'Format-SpendReport' {
    It 'reports the design share when the mix is 4:1' {
        $s = New-SpendState -Day '2026-10-11'
        $s = Add-SpendSample -State $s -Samples (New-MixSamples -Paid 20 -Free 5)
        $r = Format-SpendReport -State $s
        $r.Share | Should -BeGreaterThan 0.79
        $r.Share | Should -BeLessThan 0.81
        $r.Drift | Should -BeFalse
        $r.Summary | Should -Match '80% of proxied bytes on the paid exits'
    }

    It 'flags MORE paid than designed, because a metered allowance is being spent' {
        $s = New-SpendState -Day '2026-10-11'
        $s = Add-SpendSample -State $s -Samples (New-MixSamples -Paid 190 -Free 5)
        $r = Format-SpendReport -State $s
        $r.Drift | Should -BeTrue
        $r.Summary | Should -Match 'MORE paid than designed'
    }

    It 'flags LESS paid than designed, because the paid exits may be unhealthy' {
        $s = New-SpendState -Day '2026-10-11'
        $s = Add-SpendSample -State $s -Samples (New-MixSamples -Paid 1 -Free 49)
        $r = Format-SpendReport -State $s
        $r.Drift | Should -BeTrue
        $r.Summary | Should -Match 'LESS paid than designed'
    }

    It 'does not judge a share on too little traffic' {
        # Below ~8 MB of proxied bytes one download swings the ratio by tens of percent.
        $s = New-SpendState -Day '2026-10-11'
        $s = Add-SpendSample -State $s -Samples @(@{ Chain = @('香港|HK2022|AT'); Download = 1MB })
        (Format-SpendReport -State $s).Drift | Should -BeFalse
    }

    It 'does not judge a share on too few connections, however many bytes they moved' {
        # A connection keeps the member it was assigned at CONNECT time for its whole life, so two
        # large streams can read as a broken mix: measured live, 23.9 MB "free" against 0.1 MB
        # "paid" in one window while 30 fresh connections distributed 24 paid : 7 free.
        $s = New-SpendState -Day '2026-10-11'
        $s = Add-SpendSample -State $s -Samples @(
            @{ Chain = @('aliyun-native', 'AUTO'); Download = 200MB },
            @{ Chain = @('香港|HK2022|AT', 'AUTO'); Download = 1MB })
        $r = Format-SpendReport -State $s
        $r.Drift | Should -BeFalse -Because '2 connections cannot carry a ratio, whatever their size'
        $r.Share | Should -Not -BeNullOrEmpty   # the figure is still reported, just not judged
    }

    It 'counts DIRECT bytes separately, so domestic browsing cannot move the share' {
        $s = New-SpendState -Day '2026-10-11'
        $s = Add-SpendSample -State $s -Samples (New-MixSamples -Paid 20 -Free 5 -DirectBytes 500MB)
        $r = Format-SpendReport -State $s
        $r.Share | Should -BeGreaterThan 0.79      # 80% of proxied bytes, despite 500 MB direct
        $r.Summary | Should -Match 'direct'
        $r.Drift | Should -BeFalse
    }

    It 'reports an empty state instead of throwing' {
        (Format-SpendReport -State $null).Summary | Should -Match 'no spend data yet'
        (Format-SpendReport -State (New-SpendState)).Summary | Should -Match 'no traffic yet today'
    }
}
