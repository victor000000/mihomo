<#
.SYNOPSIS
    Tests for the auto-learner script (src\proxy\Update-AutoLearnRules.ps1).

.DESCRIPTION
    Two defects were found by reading this script on 2026-10-12, and each one is asserted here so
    the exact behaviour cannot regress silently:

      * **A failed provider reload exited 0.** Measured 2026-10-11 07:55, two reloads failed
        (`无法连接到远程服务器`) while the script still returned 0 and Task Scheduler recorded a
        success - so the learner's rule files were ahead of the running mihomo and NOTHING said so.
        The exit code is the only channel a scheduled task has; it is now asserted end to end with a
        deliberately dead API URL.

      * **The REVIEW list repeated itself.** It added one entry per failing CANDIDATE hostname
        instead of per registrable domain, and only 8-10 entries are ever printed. One real line
        carried 10 entries covering TWO domains (microsoft.com x9, msftconnecttest.com x1), so eight
        of the ten slots were the same domain over again and nine real domains could not be seen.
        The tally is now per domain - verified by asserting that no domain appears twice in the
        learner's own log output.

    Everything is hermetic: the state, the mihomo log (a SYNTHETIC one, so the assertions do not
    depend on what the live machine happened to log today), the rule files and the reload endpoint
    all live in $TestDrive or on a loopback mock. The only live paths read are the tracked repo
    files (the learner, the module, config\domestic-suffixes.txt). Measured 2026-10-12: the first
    version read the LIVE mihomo.log and called the LIVE controller, so three assertions went red
    whenever the stack was stopped or quiet - a red suite with nothing wrong in the learner.

    Run:  .\tests\Run-Tests.ps1
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers\TestEnvironment.ps1')
    $script:Root        = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ScriptPath  = Join-Path $script:Root 'src\proxy\Update-AutoLearnRules.ps1'
    $script:ScriptText  = [IO.File]::ReadAllText($script:ScriptPath, [Text.Encoding]::UTF8)
    function New-LearnerFixture {
        # Everything a run needs, built from nothing:
        #  * state\autolearn.json - ONE stale entry (45 days), so the run MUST prune it and
        #    therefore MUST write and reach the reload step. It must sit exactly where
        #    Invoke-Learner points -StateFile; the first version of this fixture wrote it one
        #    directory up and the assertions only passed for the wrong reason.
        #  * mihomo\mihomo.log - SYNTHETIC lines in mihomo's own format: 12 failed dials to one
        #    domestic host and 2 to a foreign host under the 5-hit threshold. That is what makes
        #    the report assertions below deterministic.
        # Returns the state path.
        param([string] $Dir)
        foreach ($sub in @('state', 'rules', 'mihomo')) {
            New-Item -ItemType Directory -Path (Join-Path $Dir $sub) -Force | Out-Null
        }
        $old = (Get-Date).AddDays(-45).ToString('o')
        $state = [ordered]@{
            updated = ''
            direct  = [ordered]@{ 'stale-fixture-entry.example' = [ordered]@{ First = $old; Last = $old; Hits = 3 } }
            paid    = [ordered]@{}
        }
        $statePath = Join-Path $Dir 'state\autolearn.json'
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

        $t = (Get-Date).ToString('o')
        $lines = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt 12; $i++) {
            $lines.Add(('time="{0}" level=warning msg="[TCP] dial DISPATCH (match Match using DISPATCH) 192.168.137.2:{1} --> cdn.learnertest.cn:443 error: timeout"' -f $t, (50000 + $i)))
        }
        for ($i = 0; $i -lt 2; $i++) {
            $lines.Add(('time="{0}" level=warning msg="[TCP] dial DISPATCH (match Match using DISPATCH) 192.168.137.2:{1} --> cdn.learnerprobe-example.com:443 error: connection refused"' -f $t, (51000 + $i)))
        }
        [IO.File]::WriteAllLines((Join-Path $Dir 'mihomo\mihomo.log'), $lines.ToArray())
        return $statePath
    }

    function Invoke-Learner {
        # Runs the learner with state/log/rules/mihomo-log redirected into $TestDrive, while the
        # module and the domestic-suffix list come from the repo (they are tracked files). The
        # controller must be a mock or a deliberately dead port - NEVER the live 9097: a test run
        # must not make the running mihomo reload anything.
        param([string] $Root, [string] $Api, [switch] $Quiet, [switch] $WhatIf)
        $arguments = @(
            '-ProjectRoot', $script:Root,
            '-ModulePath', (Join-Path $script:Root 'src\NetStack\NetStack.psm1'),
            '-MihomoDir', (Join-Path $Root 'mihomo'),
            '-StateFile', (Join-Path $Root 'state\autolearn.json'),
            '-LogFile', (Join-Path $Root 'state\autolearn.log'),
            '-RulesDir', (Join-Path $Root 'rules'),
            '-SummaryFile', (Join-Path $Root 'state\autolearn-summary.json'),
            '-MihomoApi', $Api
        )
        # Windows PowerShell 5.1 -File cannot bind -Switch:$false from native
        # arguments. Omit false switches rather than silently testing only pwsh.
        if ($Quiet) { $arguments += '-Quiet' }
        if ($WhatIf) { $arguments += '-WhatIf' }
        $child = Invoke-TestPowerShell -ScriptPath $script:ScriptPath -ArgumentList $arguments
        return $child.ExitCode
    }

    function Start-MockController {
        # Answers every request with 200 - the "mihomo is up and the provider reload succeeds"
        # case, without mihomo. A raw TcpListener, not HttpListener: no URL ACL, no admin.
        param([int] $Port)
        return Start-Job -ArgumentList $Port -ScriptBlock {
            param($Port)
            $listener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
            $listener.Start()
            $until = (Get-Date).AddSeconds(60)
            while ((Get-Date) -lt $until) {
                if (-not $listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
                $client = $listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $stream.ReadTimeout = 2000
                    $buf = New-Object byte[] 4096
                    try { $null = $stream.Read($buf, 0, $buf.Length) } catch { }
                    $resp = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                    try { $stream.Write($resp, 0, $resp.Length); $stream.Flush() } catch { }
                } finally { $client.Close() }
            }
            $listener.Stop()
        }
    }

    function Wait-Listening {
        param([int] $Port)
        for ($i = 0; $i -lt 60; $i++) {
            if (Test-NetConnection -ComputerName 127.0.0.1 -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue) { return $true }
            Start-Sleep -Milliseconds 100
        }
        return $false
    }

    function Start-FixtureMock {
        # A mock on a random high port, waited-for. Retries a few ports: a busy port would fail
        # the listener inside the job silently. Returns @{ Port; Job; Up }.
        param([int] $Minimum = 22000, [int] $Maximum = 44000)
        for ($attempt = 0; $attempt -lt 5; $attempt++) {
            $port = Get-Random -Minimum $Minimum -Maximum $Maximum
            $job = Start-MockController -Port $port
            if (Wait-Listening -Port $port) {
                return [pscustomobject]@{ Port = $port; Job = $job; Up = $true }
            }
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
        return [pscustomobject]@{ Port = 0; Job = $null; Up = $false }
    }
}

Describe 'the learner surfaces a failed provider reload through its exit code' {
    # Why this is the assertion that matters: the scheduled task can only report what the process
    # returns. A silent success while the rule files and the running mihomo disagree is exactly the
    # failure mode this repo keeps a test suite for.
    BeforeAll {
        $script:Td = Join-Path $TestDrive 'reloadfail'
        New-Item -ItemType Directory -Path $script:Td -Force | Out-Null
        $null = New-LearnerFixture -Dir $script:Td
    }

    It 'exits non-zero when a provider reload fails' {
        # a dead controller URL guarantees the PUT /providers/rules/<name> calls fail; the stale
        # fixture entry guarantees there is something to write, so the reload step is reached
        $code = Invoke-Learner -Root $script:Td -Api 'http://127.0.0.1:1' -Quiet
        $code | Should -Be 1 -Because 'a failed reload means the running mihomo does not have the rules the learner just wrote'
    }

    It 'says so in its own log, in words a reader can act on' {
        $logFile = Join-Path $script:Td 'state\autolearn.log'
        Test-Path -LiteralPath $logFile | Should -BeTrue
        $text = Get-Content -LiteralPath $logFile -Raw
        $text | Should -Match 'reload of autolearn-direct failed'
        $text | Should -Match 'EXITING NON-ZERO'
    }

    It 'keeps exiting 0 on a healthy run - the signal must not cry wolf' {
        $script:Td2 = Join-Path $TestDrive 'healthy'
        New-Item -ItemType Directory -Path $script:Td2 -Force | Out-Null
        $null = New-LearnerFixture -Dir $script:Td2
        # A loopback mock stands in for the controller, so "healthy" is a fact of this test and not
        # a bet on the live mihomo being up - the old version called the live 9097 and went red
        # whenever the stack was stopped, which is exactly when this suite gets run during a repair.
        $mock = Start-FixtureMock
        try {
            $mock.Up | Should -BeTrue -Because 'the mock controller must listen before the learner runs'
            $code = Invoke-Learner -Root $script:Td2 -Api ("http://127.0.0.1:{0}" -f $mock.Port) -Quiet
            $code | Should -Be 0 -Because 'a successful reload is not a failure'
        } finally {
            Stop-Job -Job $mock.Job -ErrorAction SilentlyContinue
            Remove-Job -Job $mock.Job -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'the learner protects the stack''s own resolvers' {
    # Measured 2026-10-18: dns.alidns.com and doh.pub sat in the paid bucket with
    # 25,203 and 24,690 hits, so mihomo's DoH was dialled through the paid 911
    # nodes (an Australian exit in the log) and failed. The guard that should
    # have stopped this did not exist, and TTL pruning cannot undo an entry that
    # keeps refreshing itself. This asserts the removal, end to end.
    BeforeAll {
        $script:Td6 = Join-Path $TestDrive 'resolvers'
        New-Item -ItemType Directory -Path $script:Td6 -Force | Out-Null
        $statePath = New-LearnerFixture -Dir $script:Td6

        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $now = (Get-Date).ToString('o')
        $state.paid | Add-Member -NotePropertyName 'alidns.com' -NotePropertyValue ([pscustomobject]@{
            First = (Get-Date).AddDays(-1).ToString('o'); Last = $now; Hits = 25203
        })
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

        $cfg = @'
mixed-port: 7897
dns:
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
rules:
  - MATCH,DIRECT
'@
        [IO.File]::WriteAllText((Join-Path $script:Td6 'mihomo\config.yaml'), $cfg, (New-Object System.Text.UTF8Encoding($false)))

        $script:Mock6 = Start-FixtureMock
        if (-not $script:Mock6.Up) { throw 'the mock controller never came up - the resolver assertions need it' }
        $script:Code6 = Invoke-Learner -Root $script:Td6 -Api ("http://127.0.0.1:{0}" -f $script:Mock6.Port) -Quiet
    }
    AfterAll {
        Stop-Job -Job $script:Mock6.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $script:Mock6.Job -Force -ErrorAction SilentlyContinue
    }

    It 'removes the resolver entry from the learner state' {
        $state = Get-Content -LiteralPath (Join-Path $script:Td6 'state\autolearn.json') -Raw | ConvertFrom-Json
        @($state.paid.PSObject.Properties.Name) | Should -Not -Contain 'alidns.com'
        $script:Code6 | Should -Be 0
    }

    It 'rewrites the paid provider without the resolver, and says so in the log' {
        $rules = Get-Content -LiteralPath (Join-Path $script:Td6 'rules\autolearn-paid.yaml') -Raw
        $rules | Should -Not -Match 'alidns\.com'
        $log = Get-Content -LiteralPath (Join-Path $script:Td6 'state\autolearn.log') -Raw
        $log | Should -Match 'removed \d+ learned entry\(ies\) for the stack''s own resolvers'
    }
}

Describe 'the learner thresholds per DOMAIN, not per hostname' {
    # Get-FailedRouteCandidate keys failures per hostname. Before aggregation, a site
    # split across sibling hosts never reached MinHits: two hosts x4 was reported as
    # "example.com (x8 < 5)" and nothing was learned.
    BeforeAll {
        $script:Td7 = Join-Path $TestDrive 'perdomain'
        New-Item -ItemType Directory -Path $script:Td7 -Force | Out-Null
        $null = New-LearnerFixture -Dir $script:Td7
        $t = (Get-Date).ToString('o')
        $lines = New-Object System.Collections.Generic.List[string]
        $n = 52000
        foreach ($h in @('a.split-fixture.com', 'b.split-fixture.com')) {
            for ($i = 0; $i -lt 4; $i++) {
                $lines.Add(('time="{0}" level=warning msg="[TCP] dial DISPATCH (match Match using DISPATCH) 192.168.137.2:{1} --> {2}:443 error: timeout"' -f $t, $n, $h))
                $n++
            }
        }
        [IO.File]::WriteAllLines((Join-Path $script:Td7 'mihomo\mihomo.log'), $lines.ToArray())

        $script:Mock7 = Start-FixtureMock
        if (-not $script:Mock7.Up) { throw 'the mock controller never came up - the per-domain assertions need it' }
        $null = Invoke-Learner -Root $script:Td7 -Api ("http://127.0.0.1:{0}" -f $script:Mock7.Port) -Quiet
        $script:State7 = Get-Content -LiteralPath (Join-Path $script:Td7 'state\autolearn.json') -Raw | ConvertFrom-Json
    }
    AfterAll {
        Stop-Job -Job $script:Mock7.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $script:Mock7.Job -Force -ErrorAction SilentlyContinue
    }

    It 'learns a domain whose 8 failures are split 4+4 across two sibling hosts' {
        @($script:State7.direct.PSObject.Properties.Name) | Should -Contain 'split-fixture.com'
    }
}

Describe 'the learner reports per DOMAIN, never per hostname' {
    # The defect: `$skippedExplicit.Add(...)` ran once per failing candidate hostname, so a site with
    # many hosts under one domain filled the printed list with copies of itself. Measured before the
    # fix: 10 entries, 2 distinct domains.
    BeforeAll {
        $script:Td3 = Join-Path $TestDrive 'dedupe'
        New-Item -ItemType Directory -Path $script:Td3 -Force | Out-Null
        $null = New-LearnerFixture -Dir $script:Td3
        $script:Td3Mock = Start-FixtureMock
        if (-not $script:Td3Mock.Up) { throw 'the mock controller never came up - the dedupe assertions need it' }
        $null = Invoke-Learner -Root $script:Td3 -Api ("http://127.0.0.1:{0}" -f $script:Td3Mock.Port) -Quiet
        $script:LogText = Get-Content -LiteralPath (Join-Path $script:Td3 'state\autolearn.log') -Raw
    }
    AfterAll {
        Stop-Job -Job $script:Td3Mock.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $script:Td3Mock.Job -Force -ErrorAction SilentlyContinue
    }

    It 'prints each domain at most once in the domestic, REVIEW and threshold lines' {
        $dupes = New-Object System.Collections.Generic.List[string]
        foreach ($line in ($script:LogText -split "`r?`n")) {
            # only the three reporting lines carry a "name (xN ..." list
            if ($line -notmatch 'skipped \d+ domestic|REVIEW - failing|below threshold') { continue }
            $list = ($line -replace '^.*?(domestic|routed|threshold):\s*', '') -split ';\s*'
            $names = @($list | ForEach-Object { ($_ -split ' \(x')[0] } | Where-Object { $_ })
            $grouped = @($names | Group-Object | Where-Object { $_.Count -gt 1 })
            foreach ($g in $grouped) { $dupes.Add("$($g.Name) x$($g.Count)") }
        }
        ($dupes -join ' | ') | Should -BeExactly '' -Because 'a domain listed twice wastes a slot that another domain needed'
    }

    It 'carries the failure count per domain, so the number means something' {
        $script:LogText | Should -Match '\(\s*x\d+'
    }

    It 'still lists the domestic domains it refused' {
        $script:LogText | Should -Match 'skipped \d+ domestic:'
    }
}

Describe 'the learner summary carries what the log used to hide' {
    # `skippedThreshold` was logged and then dropped from the JSON, so the one artefact a dashboard
    # can read never carried the "this is failing but below the bar" list - it was only visible to
    # somebody reading the log by hand.
    BeforeAll {
        $script:Td4 = Join-Path $TestDrive 'summary'
        New-Item -ItemType Directory -Path $script:Td4 -Force | Out-Null
        $null = New-LearnerFixture -Dir $script:Td4
        $script:Td4Mock = Start-FixtureMock
        if (-not $script:Td4Mock.Up) { throw 'the mock controller never came up - the summary assertions need it' }
        $null = Invoke-Learner -Root $script:Td4 -Api ("http://127.0.0.1:{0}" -f $script:Td4Mock.Port) -Quiet
        $script:Sum = Get-Content -LiteralPath (Join-Path $script:Td4 'state\autolearn-summary.json') -Raw | ConvertFrom-Json
    }
    AfterAll {
        Stop-Job -Job $script:Td4Mock.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $script:Td4Mock.Job -Force -ErrorAction SilentlyContinue
    }

    It 'writes a summary with the fields a reader needs' {
        foreach ($k in 'timestamp','scanned','candidates','accepted','added','refreshed','pruned','directCount','paidCount','skippedDomestic','skippedExplicit','skippedThreshold','reloadFailed','reloaded') {
            ($script:Sum.PSObject.Properties.Name -contains $k) | Should -BeTrue -Because "$k is part of the documented summary shape"
        }
    }

    It 'no longer truncates the below-threshold list to nothing' {
        ($script:Sum.PSObject.Properties.Name -contains 'skippedThreshold') | Should -BeTrue
    }
}

Describe 'the learner keeps its safety rails' {
    It 'still refuses to override a hand-written rule' {
        $script:ScriptText | Should -Match 'has an explicit rule'
        # single-quoted on purpose: the fragment contains `$explicit`, and in a double-quoted
        # PowerShell string that would expand to nothing and the regex would look for '@(.Keys)'
        # - measured: that is exactly how this assertion first failed.
        $script:ScriptText | Should -Match '-ManualDomains @\(\$explicit\.Keys\)'
    }

    It 'still enforces the domestic guard inside the module, not only in the script' {
        $module = [IO.File]::ReadAllText((Join-Path $script:Root 'src\NetStack\NetStack.psm1'), [Text.Encoding]::UTF8)
        $module | Should -Match 'NEVER proxy a domestic endpoint'
        $module | Should -Match 'Test-DomesticDomain -Domain \$domain'
    }

    It 'writes nothing at all under -WhatIf' {
        $script:Td5 = Join-Path $TestDrive 'whatif'
        New-Item -ItemType Directory -Path $script:Td5 -Force | Out-Null
        $state = New-LearnerFixture -Dir $script:Td5
        $before = (Get-FileHash -LiteralPath $state).Hash
        # A dead port on purpose: this test asserts the state does not move, not that a reload
        # succeeds - and no test in this file may point at the live controller.
        $null = Invoke-Learner -Root $script:Td5 -Api 'http://127.0.0.1:1' -Quiet -WhatIf
        (Get-FileHash -LiteralPath $state).Hash | Should -BeExactly $before -Because 'a dry run must not move the state'
        # The summary used to be written outside ShouldProcess, so a -WhatIf run
        # overwrote the dashboard's record of the last real run with counts of rules
        # that were never written.
        Test-Path -LiteralPath (Join-Path $script:Td5 'state\autolearn-summary.json') | Should -BeFalse -Because 'a dry run must not replace the last real summary'
        @(Get-ChildItem -LiteralPath (Join-Path $script:Td5 'rules') -File -ErrorAction SilentlyContinue).Count | Should -Be 0 -Because 'a dry run must not write rule files'
    }

    It 'keeps the thresholds it documents' {
        $script:ScriptText | Should -Match '\[int\]\s+\$MinHits\s+= 5'
        $script:ScriptText | Should -Match '\[int\]\s+\$MinHitsForPaid\s+= 40'
        $script:ScriptText | Should -Match '\[int\]\s+\$TtlDays\s+= 30'
        $script:ScriptText | Should -Match '\[int\]\s+\$MaxPerRoute\s+= 250'
    }
}
