<#
.SYNOPSIS
    Unit tests for src\NetStack\HostsPins.psm1 - the hosts-pin parser.

.DESCRIPTION
    The class of bug this file exists to catch: a pin block in the Windows hosts file
    that looks right but is not, so the pinned name keeps resolving to the wrong address
    and the symptom looks like a network fault rather than a stale pin.

    Two real pins are live on this machine and both can rot:
      * www.usvisascheduling.com -> the Cloudflare edge (the resolver answered a
        non-Cloudflare address that did not accept TCP 443 at all);
      * the StrategyQuant CDN fleet -> the HK edge (the EU edges are 380-800 ms away
        against 71-98 ms).

    Every case below is about the parser, which is why the parsing lives in a module
    instead of inside start-network.ps1: no hosts file, no elevation, no network.
#>

BeforeAll {
    $script:ModulePath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'src\NetStack\HostsPins.psm1'
    if (-not (Test-Path -LiteralPath $script:ModulePath)) { throw "module not found: $($script:ModulePath)" }
    Import-Module $script:ModulePath -Force

    $script:Sample = @'
# Copyright (c) 1993-2009 Microsoft Corp.
#
# mihomo: strategyquant cdn - use the HK edge, not the EU ones
# Added 2026-10-11 for SQX's "Fast Data Download".
# Refresh if the edge IP changes.
8.210.228.126  cdn.strategyquantcdn.com
8.210.228.126  cdn001.strategyquantcdn.com
8.210.228.126  cdn002.strategyquantcdn.com

# mihomo: usvisascheduling portal
172.64.146.157  www.usvisascheduling.com
172.64.146.157  usvisascheduling.com

127.0.0.1  localhost
'@
}

Describe 'Get-HostsPinBlock' {
    It 'finds a block by marker and returns its entries' {
        $b = Get-HostsPinBlock -Text $script:Sample -Marker 'strategyquant cdn'
        $b | Should -Not -BeNullOrEmpty
        $b.Entries.Count | Should -Be 3
        $b.Entries[0].IP | Should -Be '8.210.228.126'
        $b.Entries[0].Names | Should -Contain 'cdn.strategyquantcdn.com'
    }

    It 'reports the marker line number so a reader can find it' {
        $b = Get-HostsPinBlock -Text $script:Sample -Marker 'strategyquant cdn'
        $b.Line | Should -Be 3 -Because 'the marker is the third line of the sample'
    }

    It 'stops at the blank line rather than swallowing the rest of the file' {
        $b = Get-HostsPinBlock -Text $script:Sample -Marker 'strategyquant cdn'
        @($b.Entries | Where-Object { $_.Names -contains 'localhost' }).Count | Should -Be 0
    }

    It 'skips the comment prose that documents the pin' {
        $b = Get-HostsPinBlock -Text $script:Sample -Marker 'strategyquant cdn'
        @($b.Entries | Where-Object { $_.IP -notmatch '^\d' }).Count | Should -Be 0
    }

    It 'returns $null for a marker that is not there' {
        Get-HostsPinBlock -Text $script:Sample -Marker 'no such pin' | Should -BeNullOrEmpty
    }

    It 'returns $null for empty text or an empty marker instead of throwing' {
        Get-HostsPinBlock -Text '' -Marker 'x' | Should -BeNullOrEmpty
        Get-HostsPinBlock -Text $script:Sample -Marker '' | Should -BeNullOrEmpty
    }

    It 'handles LF-only line endings as well as CRLF' {
        $lf = $script:Sample -replace "`r`n", "`n"
        $b = Get-HostsPinBlock -Text $lf -Marker 'usvisascheduling portal'
        $b.Entries.Count | Should -Be 2
    }

    It 'accepts more than one name on an entry line' {
        $t = "# mihomo: multi`r`n1.2.3.4  a.example.com b.example.com`r`n"
        $b = Get-HostsPinBlock -Text $t -Marker 'multi'
        $b.Entries[0].Names.Count | Should -Be 2
    }
}

Describe 'Test-HostsPinBlock' {
    It 'accepts a well-formed block' {
        $b = Get-HostsPinBlock -Text $script:Sample -Marker 'strategyquant cdn'
        @(Test-HostsPinBlock -Block $b).Count | Should -Be 0
    }

    It 'rejects an entry whose address is not IPv4' {
        $t = "# mihomo: bad`r`nnot-an-ip  cdn.example.com`r`n"
        $b = Get-HostsPinBlock -Text $t -Marker 'bad'
        $problems = @(Test-HostsPinBlock -Block $b)
        ($problems -join ' ') | Should -Match 'not an IPv4 address'
    }

    It 'rejects an IPv6 address, because these pins are IPv4 pins' {
        $t = "# mihomo: v6`r`n::1  cdn.example.com`r`n"
        $b = Get-HostsPinBlock -Text $t -Marker 'v6'
        ($(Test-HostsPinBlock -Block $b) -join ' ') | Should -Match 'not an IPv4 address'
    }

    It 'rejects a name claimed twice inside the block' {
        $t = "# mihomo: dup`r`n1.1.1.1  a.example.com`r`n2.2.2.2  a.example.com`r`n"
        $b = Get-HostsPinBlock -Text $t -Marker 'dup'
        ($(Test-HostsPinBlock -Block $b) -join ' ') | Should -Match 'claimed twice'
    }

    It 'reports a name that is also mapped OUTSIDE the block, because hosts keeps the first' {
        $t = "# mihomo: pin`r`n1.1.1.1  cdn.example.com`r`n`r`n9.9.9.9  cdn.example.com`r`n"
        $b = Get-HostsPinBlock -Text $t -Marker 'pin'
        ($(Test-HostsPinBlock -Block $b -AllText $t) -join ' ') | Should -Match 'mapped outside this block'
    }

    It 'does not flag the block''s own entries as foreign when the whole file is supplied' {
        $b = Get-HostsPinBlock -Text $script:Sample -Marker 'strategyquant cdn'
        @(Test-HostsPinBlock -Block $b -AllText $script:Sample).Count | Should -Be 0
    }

    It 'reports an empty block rather than passing it' {
        $t = "# mihomo: empty`r`n`r`n127.0.0.1 localhost`r`n"
        $b = Get-HostsPinBlock -Text $t -Marker 'empty'
        ($(Test-HostsPinBlock -Block $b) -join ' ') | Should -Match 'no entries'
    }

    It 'handles a null block without throwing' {
        ($(Test-HostsPinBlock -Block $null) -join ' ') | Should -Match 'no block parsed'
    }
}

Describe 'the live pins on this machine are well formed' -Tag 'Machine' {
    # Opt-in only (Run-Tests.ps1 -IncludeMachine). Default discovery must not even
    # read the real hosts file. Pure parser coverage above always runs.
    BeforeAll {
        $script:HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        $script:HostsText = if (Test-Path -LiteralPath $script:HostsPath) { [IO.File]::ReadAllText($script:HostsPath) } else { '' }
    }

    It 'parses every pin block the docs promise, when the file exists' {
        if (-not $script:HostsText) { Set-ItResult -Skipped -Because 'no hosts file on this machine'; return }
        foreach ($marker in 'strategyquant cdn', 'usvisascheduling portal') {
            $b = Get-HostsPinBlock -Text $script:HostsText -Marker $marker
            if ($null -ne $b) {
                @(Test-HostsPinBlock -Block $b -AllText $script:HostsText).Count |
                    Should -Be 0 -Because "the '$marker' pin block is malformed"
            }
        }
    }
}
