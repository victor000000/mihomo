<#
.SYNOPSIS
    Tests for tools\Update-Clashmi911Rules.ps1 - the extractor that lifts the 911
    subscription's own must-proxy rules into the clashmi-911 rule-provider payload.

.DESCRIPTION
    The class of bug this file exists to catch: the extractor silently producing a
    payload that is wrong in a way nothing else notices. The payload is runtime
    state (runtime\rules\, gitignored) that the live config references with
    `RULE-SET,clashmi-911,AUTO`, so a regression here does not fail a build - it
    just routes traffic differently:

      * a policy left on a payload line, which makes the rule match nothing at all
        (a classical provider entry is a rule WITHOUT a policy - measured on mihomo
        v1.19.32, README "behavior: classical matters");
      * the provider's `MATCH,OpenConnectUs911` tail copied into the payload, which
        would proxy everything and spend the metered 50 GB plan - the exact thing
        this tool exists to strip;
      * the provider's own DIRECT / REJECT / CN entries lifted as if they were
        proxy rules;
      * a rule counted twice or dropped, so the header and the payload disagree;
      * a provider that changed shape (multi-line rules, a rewritten rules: block)
        yielding an almost-empty payload, which is worse than failing loudly.

    The fixture is synthetic and lives in $TestDrive. This suite never reads or
    writes runtime\providers\clashmi.yaml, never runs the live switch and never
    touches the network or the controller.

    Run:  .\tests\Run-Tests.ps1
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers\TestEnvironment.ps1')
    $script:ToolPath   = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\Update-Clashmi911Rules.ps1')).Path
    $script:ProxyGroup = 'OpenConnectUs911'

    <#
        A synthetic provider with the same shape as the real one: `rules:` is the
        last top-level key and every rule is a single quoted scalar under it.

        Deliberate contents, one per behaviour under test:
          * five rules whose policy is the provider's own group   -> lifted
          * one rule for a DIFFERENT group                        -> dropped
          * one rule that already carries no policy               -> dropped
          * DIRECT / REJECT / IP-CIDR / GEOSITE entries           -> dropped
          * the provider's own catch-all tail                     -> dropped
    #>
    $script:ProviderFixture = Join-Path $TestDrive 'clashmi-provider-fixture.yaml'
    $fixtureYaml = @'
# synthetic 911 provider fixture - same shape as runtime\providers\clashmi.yaml
proxies:
  - name: OpenConnectUs911
    type: anytls
    server: 192.0.2.10
proxy-groups:
  - name: OpenConnectUs911
    type: select
  - name: OtherGroup
    type: select
rules:
  - 'DOMAIN-SUFFIX,alpha.example,OpenConnectUs911'
  - 'DOMAIN-SUFFIX,beta.example,OpenConnectUs911'
  - DOMAIN,gamma.example,OpenConnectUs911
  - 'DOMAIN-KEYWORD,delta,OpenConnectUs911'
  - 'AND,((DOMAIN-SUFFIX,and1.example),(DOMAIN-SUFFIX,and2.example)),OpenConnectUs911'
  - 'DOMAIN-SUFFIX,other-group.example,OtherGroup'
  - 'DOMAIN-SUFFIX,no-policy.example'
  - 'DOMAIN-SUFFIX,cn-direct.example,DIRECT'
  - 'DOMAIN-SUFFIX,reject.example,REJECT'
  - 'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve'
  - 'GEOSITE,cn,DIRECT'
  - 'MATCH,OpenConnectUs911'
'@
    [IO.File]::WriteAllText($script:ProviderFixture, $fixtureYaml, (New-Object Text.UTF8Encoding($false)))

    # The five entries the fixture's proxy-group rules must produce, in file order.
    $script:ExpectedPayload = @(
        'DOMAIN-SUFFIX,alpha.example'
        'DOMAIN-SUFFIX,beta.example'
        'DOMAIN,gamma.example'
        'DOMAIN-KEYWORD,delta'
        'AND,((DOMAIN-SUFFIX,and1.example),(DOMAIN-SUFFIX,and2.example))'
    )

    # Run the real extractor in the selected matrix engine, capturing its report
    # and surfacing failures as throws so the failure-mode assertions stay intact.
    function Invoke-Extractor {
        param(
            [string] $OutPath,
            [string] $ProviderPath = $script:ProviderFixture,
            [string] $Group = $script:ProxyGroup,
            [switch] $WhatIf
        )
        $arguments = @('-ProviderPath', $ProviderPath, '-OutPath', $OutPath, '-ProxyGroup', $Group)
        if ($WhatIf) { $arguments += '-WhatIf' }
        $child = Invoke-TestPowerShell -ScriptPath $script:ToolPath -ArgumentList $arguments
        if ($child.ExitCode -ne 0) { throw ($child.Output -join "`n") }
        return $child.Output
    }

    function Get-PayloadEntries {
        param([string] $Path)
        $entries = New-Object System.Collections.Generic.List[string]
        foreach ($line in @([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) -split "\r?\n")) {
            if ($line -match "^  - '(.*)'$") { $entries.Add($Matches[1]) }
        }
        return $entries.ToArray()
    }

    function Get-HeaderLine {
        param([string] $Path, [string] $Prefix)
        foreach ($line in @([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) -split "\r?\n")) {
            if ($line.StartsWith($Prefix)) { return $line }
        }
        return ''
    }

    $script:OutPath = Join-Path $TestDrive 'out\clashmi-911.yaml'
    $script:Report  = @(Invoke-Extractor -OutPath $script:OutPath)
}

Describe 'Update-Clashmi911Rules - payload' {
    It 'writes the payload to the path it was given' {
        Test-Path -LiteralPath $script:OutPath | Should -BeTrue
    }

    It 'lifts exactly the rules that target the provider proxy group, in file order' {
        $actual = @(Get-PayloadEntries -Path $script:OutPath)
        ($actual -join '|') | Should -BeExactly ($script:ExpectedPayload -join '|')
    }

    It 'strips the policy from every lifted line (a classical payload entry has none)' {
        foreach ($line in @([IO.File]::ReadAllText($script:OutPath, [Text.Encoding]::UTF8) -split "\r?\n")) {
            if ($line -notmatch "^  - '") { continue }
            $line | Should -Not -Match (',' + [regex]::Escape($script:ProxyGroup))
            $line | Should -Not -Match ',DIRECT|,REJECT|,OtherGroup'
        }
    }

    It 'keeps the rule type on every entry, so behavior: classical can still match it' {
        foreach ($e in @(Get-PayloadEntries -Path $script:OutPath)) {
            $e | Should -Match '^(DOMAIN-SUFFIX|DOMAIN|DOMAIN-KEYWORD|IP-CIDR|GEOSITE|AND|PROCESS-NAME|RULE-SET),'
        }
    }

    It 'drops the provider MATCH tail' {
        @(Get-PayloadEntries -Path $script:OutPath | Where-Object { $_ -match '^MATCH' }).Count | Should -Be 0 -Because 'the tail is what proxied every destination and emptied the metered plan'
        [IO.File]::ReadAllText($script:OutPath, [Text.Encoding]::UTF8) | Should -Not -Match '(?m)^\s*-\s*.?MATCH'
    }

    It 'drops the DIRECT, REJECT, GEOSITE and IP-CIDR entries' {
        $entries = @(Get-PayloadEntries -Path $script:OutPath)
        foreach ($gone in @('cn-direct.example', 'reject.example', '10.0.0.0/8')) {
            @($entries | Where-Object { $_ -match [regex]::Escape($gone) }).Count | Should -Be 0
        }
    }

    It 'drops rules aimed at a different group and rules that carry no policy at all' {
        $entries = @(Get-PayloadEntries -Path $script:OutPath)
        @($entries | Where-Object { $_ -match 'other-group\.example' }).Count | Should -Be 0
        @($entries | Where-Object { $_ -match 'no-policy\.example' }).Count    | Should -Be 0
    }

    It 'honours -ProxyGroup instead of a hard-coded name' {
        $out = Join-Path $TestDrive 'other-group.yaml'
        $null = @(Invoke-Extractor -OutPath $out -Group 'OtherGroup')
        (@(Get-PayloadEntries -Path $out) -join '|') | Should -BeExactly 'DOMAIN-SUFFIX,other-group.example'
    }

    It 'declares a payload: key with one quoted entry per lifted rule' {
        $text = [IO.File]::ReadAllText($script:OutPath, [Text.Encoding]::UTF8)
        $text | Should -Match '(?m)^payload:\s*$'
        $entries = @(Get-PayloadEntries -Path $script:OutPath)
        $entries.Count | Should -Be $script:ExpectedPayload.Count
        # Every rule line in the file must be one of the payload entries - a stray
        # unquoted entry would be read as a nested mapping by the YAML parser.
        $ruleLines = @($text -split "\r?\n" | Where-Object { $_ -match '^  - ' })
        $ruleLines.Count | Should -Be $entries.Count
    }
}

Describe 'Update-Clashmi911Rules - header' {
    It 'records the source file it read' {
        Get-HeaderLine -Path $script:OutPath -Prefix '# source' | Should -Match 'clashmi-provider-fixture\.yaml'
    }

    It 'records what the payload means and why the dropped parts were dropped' {
        $text = [IO.File]::ReadAllText($script:OutPath, [Text.Encoding]::UTF8)
        $text | Should -Match '(?m)^# meaning\s*:'
        $text | Should -Match 'MATCH,DISPATCH'
        $text | Should -Match "RULE-SET,clashmi-911"
    }

    It 'records the entry count, and it agrees with the payload it emitted' {
        $header = Get-HeaderLine -Path $script:OutPath -Prefix '# entries'
        $header | Should -Match ':\s*5\s*$'
        @(Get-PayloadEntries -Path $script:OutPath).Count | Should -Be 5
    }

    It 'stamps the generation time' {
        $stamp = Get-HeaderLine -Path $script:OutPath -Prefix '# generated:'
        $stamp | Should -Match '^# generated: \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
    }

    It 'says it is machine-generated so nobody hand-edits runtime state' {
        ([IO.File]::ReadAllText($script:OutPath, [Text.Encoding]::UTF8) -split "\r?\n")[0] |
            Should -Match 'DO NOT EDIT BY HAND'
    }
}

Describe 'Update-Clashmi911Rules - reporting' {
    It 'reports how many rules the provider held and how many were lifted' {
        $report = $script:Report -join "`n"
        $report | Should -Match 'rules in file\s*:\s*12'
        $report | Should -Match 'proxy group: OpenConnectUs911\s+\(5 lifted\)'
    }

    It 'warns when very few rules were lifted, because that means the provider changed shape' {
        # The real provider carried 610 rules / 354 lifted; a handful is the signal
        # that the rules: block moved, changed shape, or was truncated.
        ($script:Report -join "`n") | Should -Match 'WARNING: only 5 rules lifted'
    }

    It 'names the rule types it lifted, so a shape change is visible at a glance' {
        # Order-independent: the report sorts by count and PowerShell 5.1's
        # Sort-Object is not a stable sort, so the ties come out in an order that is
        # an implementation detail, not an invariant.
        $report = $script:Report -join "`n"
        $report | Should -Match 'rule types\s*:\s*\S'
        foreach ($token in @('DOMAIN-SUFFIX=2', 'DOMAIN=1', 'DOMAIN-KEYWORD=1', 'AND=1')) {
            $report | Should -Match ([regex]::Escape($token) + '(?:\s|$)')
        }
    }
}

Describe 'Update-Clashmi911Rules - idempotency' {
    It 'is byte-identical across runs apart from the generation stamp' {
        $second = Join-Path $TestDrive 'second.yaml'
        $null = @(Invoke-Extractor -OutPath $second)

        $strip = { param($p) (@([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) -split "\r?\n") |
                              Where-Object { $_ -notmatch '^# generated:' }) -join "`r`n" }
        # Only the timestamp may differ: the switch and the daily refresh re-run this
        # tool, and a payload that drifted run to run would reload mihomo's provider
        # with different rules for no reason.
        (& $strip $script:OutPath) | Should -BeExactly (& $strip $second)
    }

    It 'replaces the file atomically and leaves no .tmp behind' {
        Test-Path -LiteralPath "$($script:OutPath).tmp" | Should -BeFalse
    }
}

Describe 'Update-Clashmi911Rules - WhatIf' {
    It 'writes nothing at all' {
        $out = Join-Path $TestDrive 'whatif\clashmi-911.yaml'
        $null = @(Invoke-Extractor -OutPath $out -WhatIf)
        Test-Path -LiteralPath $out | Should -BeFalse
        Test-Path -LiteralPath "$out.tmp" | Should -BeFalse
        Test-Path -LiteralPath (Split-Path -Parent $out) | Should -BeFalse -Because '-WhatIf must not even create the directory'
    }

    It 'still reports the payload it would have written' {
        $out = Join-Path $TestDrive 'whatif2.yaml'
        $report = @(Invoke-Extractor -OutPath $out -WhatIf) -join "`n"
        $report | Should -Match 'proxy group: OpenConnectUs911\s+\(5 lifted\)'
        $report | Should -Match '\-WhatIf: nothing written'
    }
}

Describe 'Update-Clashmi911Rules - failure modes' {
    It 'refuses a provider with no top-level rules: block instead of writing an empty payload' {
        $bad = Join-Path $TestDrive 'no-rules.yaml'
        [IO.File]::WriteAllText($bad, "proxies:`r`n  - name: x`r`n", (New-Object Text.UTF8Encoding($false)))
        $out = Join-Path $TestDrive 'no-rules-out.yaml'
        { Invoke-Extractor -OutPath $out -ProviderPath $bad } | Should -Throw "*no top-level 'rules:' section*"
        Test-Path -LiteralPath $out | Should -BeFalse -Because 'an empty payload would silently switch the 911 list off'
    }

    It 'refuses a provider file that is not there' {
        $missing = Join-Path $TestDrive 'never-fetched.yaml'
        { Invoke-Extractor -OutPath (Join-Path $TestDrive 'x.yaml') -ProviderPath $missing } |
            Should -Throw '*provider not found*'
    }
}
