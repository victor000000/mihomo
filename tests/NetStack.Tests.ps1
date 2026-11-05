<#
.SYNOPSIS
    Unit tests for the NetStack module.

.DESCRIPTION
    Every test here corresponds to a bug that actually occurred in this project,
    or to a rule the auto-learner must never break. They are regression tests,
    not decoration.

    Run:
        Invoke-Pester -Path .\tests -Output Detailed
    or
        .\tests\Run-Tests.ps1
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\NetStack\NetStack.psm1'
    $modulePath = (Resolve-Path $modulePath).Path
    Import-Module $modulePath -Force
}

Describe 'ConvertTo-NSJsonString' {
    It 'returns an empty JSON string for null' {
        ConvertTo-NSJsonString $null | Should -Be '""'
    }

    It 'escapes double quotes' {
        ConvertTo-NSJsonString 'he said "hi"' | Should -Be '"he said \"hi\""'
    }

    It 'escapes backslashes' {
        ConvertTo-NSJsonString 'C:\path\to' | Should -Be '"C:\\path\\to"'
    }

    It 'escapes backslashes BEFORE quotes, so escapes are not double-escaped' {
        # a naive order (quotes then backslashes) turns \" into \\" and breaks JSON
        ConvertTo-NSJsonString '\"' | Should -Be '"\\\""'
    }

    It 'replaces newlines and tabs with spaces so a value cannot break a line' {
        ConvertTo-NSJsonString "a`r`nb`tc" | Should -Be '"a  b c"'
    }

    It 'passes plain text through' {
        ConvertTo-NSJsonString 'hello' | Should -Be '"hello"'
    }

    It 'handles a value made only of special characters' {
        ConvertTo-NSJsonString '"""' | Should -Be '"\"\"\""'
    }
}

Describe 'ConvertTo-NSJsonNumber' {
    It 'renders null as null' { ConvertTo-NSJsonNumber $null | Should -Be 'null' }

    It 'renders integers' { ConvertTo-NSJsonNumber 42 | Should -Be '42' }

    It 'renders zero' { ConvertTo-NSJsonNumber 0 | Should -Be '0' }

    It 'renders negative numbers' { ConvertTo-NSJsonNumber -7 | Should -Be '-7' }

    It 'renders booleans as JSON booleans, not numbers' {
        ConvertTo-NSJsonNumber $true  | Should -Be 'true'
        ConvertTo-NSJsonNumber $false | Should -Be 'false'
    }

    It 'renders a non-numeric string as null rather than emitting invalid JSON' {
        # 'n/a' appears whenever a probe failed; emitting it bare would corrupt
        # status.json and break the dashboard
        ConvertTo-NSJsonNumber 'n/a' | Should -Be 'null'
    }

    It 'uses invariant culture so a comma-decimal locale cannot emit 1,5' {
        (ConvertTo-NSJsonNumber 1.5) | Should -Not -Match ','
    }
}

Describe 'ConvertTo-NSJsonBool' {
    It 'renders truthy as true'  { ConvertTo-NSJsonBool 1     | Should -Be 'true' }
    It 'renders falsy as false'  { ConvertTo-NSJsonBool 0     | Should -Be 'false' }
    It 'renders empty string as false' { ConvertTo-NSJsonBool '' | Should -Be 'false' }
    It 'renders null as false'   { ConvertTo-NSJsonBool $null | Should -Be 'false' }
}

Describe 'Split-CsvLine' {
    It 'splits a plain record' {
        $r = Split-CsvLine 'a,b,c'
        $r.Count | Should -Be 3
        $r[1]    | Should -Be 'b'
    }

    It 'keeps a comma inside double quotes in one field' {
        $r = Split-CsvLine 'a,"x,y",c'
        $r.Count | Should -Be 3
        $r[1]    | Should -Be 'x,y'
    }

    It 'unescapes doubled quotes' {
        $r = Split-CsvLine 'a,"say ""hi""",c'
        $r[1] | Should -Be 'say "hi"'
    }

    It 'returns nothing for null' {
        # NOTE: asserted with -BeNullOrEmpty rather than a Count. PowerShell
        # cannot return a DISTINGUISHABLE empty array through the pipeline:
        # plain @() unwraps to $null and ,@() becomes a one-element array, so
        # `@(f).Count` is 1 either way. The meaningful contract is "no entries".
        Split-CsvLine $null | Should -BeNullOrEmpty
    }

    It 'handles an empty line as a single empty field' {
        $r = Split-CsvLine ''
        $r.Count | Should -Be 1
        $r[0]    | Should -Be ''
    }
}

Describe 'ConvertFrom-NetstatOutput' {
    BeforeAll {
        # Verbatim shapes captured from `netstat -ano` on Windows 11.
        $script:Sample = @(
            '  TCP    127.0.0.1:7897         0.0.0.0:0              LISTENING       47980',
            '  TCP    192.168.1.100:60236    192.0.2.10:443      ESTABLISHED     46664',
            '  TCP    192.168.1.100:60237    192.0.2.10:443      ESTABLISHED     46664',
            '  TCP    10.90.126.200:51000    223.5.5.5:443          ESTABLISHED     1234',
            '  UDP    127.0.0.1:53           *:*                                    41324',
            '  UDP    [::1]:53               *:*                                    41324',
            '  UDP    0.0.0.0:5353           *:*                                    9999',
            'garbage line that should be ignored'
        )
        $script:Parsed = ConvertFrom-NetstatOutput $script:Sample
    }

    It 'detects a TCP listening port' {
        $script:Parsed.Listen['7897'] | Should -Be 'TCP'
    }

    It 'detects a UDP socket on 127.0.0.1' {
        # REGRESSION: an earlier version tested $Matches[3] AFTER another -match
        # had already overwritten $Matches, so UDP was never recorded and
        # SmartDNS was permanently reported as down.
        $script:Parsed.Listen['53'] | Should -Be 'UDP'
    }

    It 'detects a UDP socket on an IPv6 address' {
        $script:Parsed.Listen.ContainsKey('53') | Should -BeTrue
    }

    It 'does not treat a wildcard foreign endpoint as a listening TCP port' {
        $script:Parsed.Listen.ContainsKey('0') | Should -BeFalse
    }

    It 'counts established connections per local IP' {
        $script:Parsed.Established['192.168.1.100'] | Should -Be 2
        $script:Parsed.Established['10.90.126.200'] | Should -Be 1
    }

    It 'uses STRING port keys because PS 5.1 cannot serialise integer keys' {
        $keys = @($script:Parsed.Listen.Keys)
        $keys | Where-Object { $_ -isnot [string] } | Should -BeNullOrEmpty
    }

    It 'ignores unparseable lines without throwing' {
        { ConvertFrom-NetstatOutput @('total nonsense', '  TCP  bad') } | Should -Not -Throw
    }

    It 'handles null input' {
        $r = ConvertFrom-NetstatOutput $null
        $r.Listen.Count      | Should -Be 0
        $r.Established.Count | Should -Be 0
    }
}

Describe 'ConvertFrom-MihomoLogLine' {
    It 'extracts domain, rule and outbound' {
        $l = 'time="2026-10-10T21:27:59Z" level=info msg="[TCP] 127.0.0.1:59054 --> www.google.com:443 match DomainSuffix(google.com) using AUTO[aliyun-native]"'
        $r = ConvertFrom-MihomoLogLine $l
        $r.Domain | Should -Be 'www.google.com'
        $r.Rule   | Should -Be 'DomainSuffix(google.com)'
        $r.Out    | Should -Be 'AUTO[aliyun-native]'
    }

    It 'strips the stray trailing quote mihomo emits on bracketed outbounds' {
        # REGRESSION: the dashboard literally rendered LOCAL[hypomux]" with a quote
        $l = 'msg="[TCP] 127.0.0.1:1 --> x.com:443 match Match using LOCAL[hypomux]""'
        (ConvertFrom-MihomoLogLine $l).Out | Should -Be 'LOCAL[hypomux]'
    }

    It 'returns null for a non-routing line' {
        ConvertFrom-MihomoLogLine 'level=info msg="Start initial provider clashmi"' | Should -BeNullOrEmpty
    }

    It 'returns null for null and empty input' {
        ConvertFrom-MihomoLogLine $null | Should -BeNullOrEmpty
        ConvertFrom-MihomoLogLine ''    | Should -BeNullOrEmpty
    }
}

Describe 'Get-FailedRouteCandidate' {
    BeforeAll {
        $script:Now = [datetimeoffset]'2026-10-10T22:00:00+08:00'
        $script:Lines = @(
            'time="2026-10-10T21:55:00.1+08:00" level=warning msg="[TCP] dial LOCAL (match Match/) 127.0.0.1:1 --> a.example.com:443 error: context deadline exceeded"',
            'time="2026-10-10T21:55:01.1+08:00" level=warning msg="[TCP] dial LOCAL (match Match/) 127.0.0.1:2 --> a.example.com:443 error: context deadline exceeded"',
            'time="2026-10-10T21:55:02.1+08:00" level=warning msg="[TCP] dial AUTO (match DomainSuffix/yahoo.com) 127.0.0.1:3 --> q.finance.yahoo.com:443 error: 192.0.2.10:443 connect error: context deadline exceeded"',
            'time="2026-10-10T10:00:00.1+08:00" level=warning msg="[TCP] dial LOCAL (match Match/) 127.0.0.1:4 --> old.example.com:443 error: context deadline exceeded"',
            'time="2026-10-10T21:55:03.1+08:00" level=warning msg="[TCP] dial LOCAL (match Match/) 127.0.0.1:5 --> 128.242.245.253:443 error: i/o timeout"'
        )
        $script:C = Get-FailedRouteCandidate -Lines $script:Lines -SinceMinutes 30 -Now $script:Now
    }

    It 'classifies a LOCAL failure as the direct route' {
        ($script:C | Where-Object { $_.Domain -eq 'a.example.com' }).Route | Should -Be 'direct'
    }

    It 'classifies an AUTO failure as the proxy route' {
        ($script:C | Where-Object { $_.Domain -eq 'q.finance.yahoo.com' }).Route | Should -Be 'proxy'
    }

    It 'classifies a DISPATCH failure as the direct route, not as unlearnable' {
        # DISPATCH is this design's direct path - `MATCH,DISPATCH` is the catch-all and
        # DISPATCH = fallback [hypomux, DIRECT]. It was missing from the route map until
        # 2026-10-12, so HALF of the failed dials in a real log (182 DISPATCH against 269 LOCAL)
        # were labelled 'other' and dropped before the learner ever saw them. The cost was
        # concrete: `cdn-cookieyes.com` x6, `api.deepseek.com` x50 and `www.msftncsi.com` x7 sat
        # in that blind spot, and the first of those had to be found and fixed by hand on
        # 2026-10-12 while the learner stayed silent about it.
        $line = 'time="2026-10-10T21:55:04.1+08:00" level=warning msg="[TCP] dial DISPATCH (match Match/) 127.0.0.1:6 --> cdn-cookieyes.com:443 error: context deadline exceeded"'
        $c = @(Get-FailedRouteCandidate -Lines @($line) -SinceMinutes 30 -Now $script:Now)
        $c.Count | Should -Be 1
        # @() around the result is load-bearing: with exactly one candidate PowerShell unwraps it to
        # a bare Hashtable, and `$c[0]` on a Hashtable is a PowerShell 7 feature - under 5.1 (the
        # engine this suite runs on, see tests\Run-Tests.ps1) it returns $null, so the assertion
        # would fail with "got $null" on a function that is working correctly. Cost one debug cycle.
        $c[0].Route | Should -BeExactly 'direct'
        $c[0].Domain | Should -BeExactly 'cdn-cookieyes.com'
    }

    It 'classifies a DATA failure as a PAID-route failure, not as a free-proxy failure' {
        # DATA dials the same paid 911 provider (filter 香港|新加坡|日本|德国), so a
        # destination failing there has failed the PAID path. Escalating it to PAID
        # cannot help; it can only refresh the rule that sent it there.
        $line = 'time="2026-10-10T21:55:05.1+08:00" level=warning msg="[TCP] dial DATA (match IPCIDR/194.8.15.0/24) 127.0.0.1:7 --> feed.example.net:443 error: context deadline exceeded"'
        $c = @(Get-FailedRouteCandidate -Lines @($line) -SinceMinutes 30 -Now $script:Now)
        $c.Count | Should -Be 1
        $c[0].Route | Should -BeExactly 'paid'
    }

    It 'classifies a PAID failure as its own route - the loop that kept DNS escalated' {
        # Measured 2026-10-18: counting PAID failures as 'proxy' let every failed
        # paid retry refresh the paid rule that caused it. dns.alidns.com and doh.pub
        # reached 25,203 and 24,690 hits that way while mihomo's DNS was dialled
        # through an Australian 911 exit and failed.
        $line = 'time="2026-10-10T21:55:06.1+08:00" level=warning msg="[TCP] dial PAID (match RuleSet/autolearn-paid) mihomo --> dns.alidns.com:443 error: failed to create session: EOF"'
        $c = @(Get-FailedRouteCandidate -Lines @($line) -SinceMinutes 30 -Now $script:Now)
        $c.Count | Should -Be 1
        $c[0].Route | Should -BeExactly 'paid'
    }

    It 'counts repeated failures' {
        ($script:C | Where-Object { $_.Domain -eq 'a.example.com' }).Count | Should -Be 2
    }

    It 'IGNORES lines older than the window' {
        # REGRESSION: without this the learner kept re-proposing docker.com from
        # entries written before that rule was added.
        @($script:C | Where-Object { $_.Domain -eq 'old.example.com' }).Count | Should -Be 0
    }

    It 'skips bare IP destinations because a domain rule cannot match them' {
        @($script:C | Where-Object { $_.Domain -eq '128.242.245.253' }).Count | Should -Be 0
    }

    It 'sorts by failure count descending' {
        $script:C[0].Domain | Should -Be 'a.example.com'
    }

    It 'honours MinHits' {
        $c = Get-FailedRouteCandidate -Lines $script:Lines -MinHits 2 -SinceMinutes 30 -Now $script:Now
        @($c | Where-Object { $_.Domain -eq 'q.finance.yahoo.com' }).Count | Should -Be 0
    }

    It 'handles null input' {
        @(Get-FailedRouteCandidate -Lines $null).Count | Should -Be 0
    }
}

Describe 'Get-RegistrableDomain' {
    It 'reduces a host to its registrable suffix' {
        Get-RegistrableDomain 'query2.finance.yahoo.com' | Should -Be 'yahoo.com'
    }

    It 'keeps a two-label domain as-is' {
        Get-RegistrableDomain 'example.com' | Should -Be 'example.com'
    }

    It 'handles two-level public suffixes' {
        Get-RegistrableDomain 'a.b.example.co.uk' | Should -Be 'example.co.uk'
    }

    It 'handles .com.cn' {
        Get-RegistrableDomain 'www.taobao.com.cn' | Should -Be 'taobao.com.cn'
    }

    It 'rejects IPv4 literals' {
        Get-RegistrableDomain '128.242.245.253' | Should -Be ''
    }

    It 'rejects single-label names' {
        Get-RegistrableDomain 'localhost' | Should -Be ''
    }

    It 'lowercases and strips a trailing dot' {
        Get-RegistrableDomain 'WWW.Example.COM.' | Should -Be 'example.com'
    }

    It 'handles null' { Get-RegistrableDomain $null | Should -Be '' }
}

Describe 'Get-DnsResolverDomains' {
    # The learner must treat the stack's own resolvers as infrastructure. With
    # respect-rules: true, mihomo dials its DoH servers through the routing rules,
    # so a learned rule for dns.alidns.com sends DNS through the paid path that is
    # supposed to resolve the paid path's own servers.
    BeforeAll {
        $script:Cfg = @'
mixed-port: 7897
dns:
  enable: true
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  proxy-server-nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
  nameserver:
    - https://1.1.1.1/dns-query
    - tls://dns.google:853
  nameserver-policy:
    "domain:dukascopy.com":
      - https://cloudflare-dns.com/dns-query
rules:
  - MATCH,DIRECT
'@
        $script:Domains = @(Get-DnsResolverDomains -ConfigText $script:Cfg)
    }

    It 'returns the registrable domains of the scheme-based resolvers' {
        $script:Domains | Should -Contain 'alidns.com'
        $script:Domains | Should -Contain 'doh.pub'
        $script:Domains | Should -Contain 'dns.google'
        $script:Domains | Should -Contain 'cloudflare-dns.com'
    }

    It 'ignores IP literals, which a DOMAIN rule could never match' {
        $script:Domains | Should -Not -Contain '1.1.1.1'
        $script:Domains | Should -Not -Contain '223.5.5.5'
    }

    It 'does not misread a nameserver-policy routing key as a resolver' {
        # "domain:dukascopy.com" is a ROUTING destination; proxying it is the
        # whole point of its policy entry.
        $script:Domains | Should -Not -Contain 'dukascopy.com'
    }

    It 'handles a missing or dns-less config' {
        @(Get-DnsResolverDomains -ConfigText 'mixed-port: 7897').Count | Should -Be 0
        @(Get-DnsResolverDomains -ConfigText '').Count             | Should -Be 0
        @(Get-DnsResolverDomains -ConfigText $null).Count          | Should -Be 0
    }
}

Describe 'Remove-LearnedResolverDomains' {
    BeforeAll {
        function New-ResState {
            @{
                direct = @{ 'resolver-fixture.example' = @{ First = (Get-Date); Last = (Get-Date); Hits = 1 }
                            'kept.example'             = @{ First = (Get-Date); Last = (Get-Date); Hits = 1 } }
                paid   = @{ 'alidns.com' = @{ First = (Get-Date); Last = (Get-Date); Hits = 25203 }
                            'doh.pub'    = @{ First = (Get-Date); Last = (Get-Date); Hits = 24690 } }
            }
        }
    }

    It 'removes a resolver from EITHER bucket and reports what it removed' {
        $s = New-ResState
        $removed = @(Remove-LearnedResolverDomains -State $s -ResolverDomains @('alidns.com', 'doh.pub'))
        ($removed | Sort-Object) -join ',' | Should -BeExactly 'alidns.com,doh.pub'
        $s['paid'].ContainsKey('alidns.com') | Should -BeFalse
        $s['paid'].ContainsKey('doh.pub')    | Should -BeFalse
    }

    It 'leaves every other learned domain alone' {
        $s = New-ResState
        $null = Remove-LearnedResolverDomains -State $s -ResolverDomains @('alidns.com')
        $s['direct'].ContainsKey('kept.example') | Should -BeTrue
        $s['paid'].ContainsKey('doh.pub')        | Should -BeTrue
    }

    It 'is a no-op with no resolver domains' {
        $s = New-ResState
        @(Remove-LearnedResolverDomains -State $s -ResolverDomains @()).Count | Should -Be 0
        $s['paid'].Count | Should -Be 2
    }
}

Describe 'Test-DomesticDomain' {
    BeforeAll {
        $script:Suffixes = @('qq.com', 'doubao.com', 'aliyuncs.com')
    }

    It 'treats anything under .cn as domestic' {
        Test-DomesticDomain -Domain 'example.cn'        -DomesticSuffixes $script:Suffixes | Should -BeTrue
        Test-DomesticDomain -Domain 'a.b.example.com.cn' -DomesticSuffixes $script:Suffixes | Should -BeTrue
    }

    It 'matches a listed suffix' {
        Test-DomesticDomain -Domain 'qq.com'          -DomesticSuffixes $script:Suffixes | Should -BeTrue
        Test-DomesticDomain -Domain 'sec.qq.com'      -DomesticSuffixes $script:Suffixes | Should -BeTrue
        Test-DomesticDomain -Domain 'www.doubao.com'  -DomesticSuffixes $script:Suffixes | Should -BeTrue
    }

    It 'does NOT match a foreign domain' {
        Test-DomesticDomain -Domain 'yahoo.com'       -DomesticSuffixes $script:Suffixes | Should -BeFalse
        Test-DomesticDomain -Domain 'docker.com'      -DomesticSuffixes $script:Suffixes | Should -BeFalse
    }

    It 'is not fooled by a suffix that merely contains a listed name' {
        # 'notqq.com' must not match 'qq.com'
        Test-DomesticDomain -Domain 'notqq.com'       -DomesticSuffixes $script:Suffixes | Should -BeFalse
    }

    It 'matches the domestic set as well as the suffix list' {
        Test-DomesticDomain -Domain 'x.example.org' -DomesticSet @('example.org') | Should -BeTrue
    }

    It 'returns false for null and empty input' {
        Test-DomesticDomain -Domain $null | Should -BeFalse
        Test-DomesticDomain -Domain ''    | Should -BeFalse
    }
}

Describe 'Update-AutoLearnState' {
    BeforeAll {
        $script:Now = [datetime]'2026-10-10T14:00:00Z'
        function New-State { @{ direct = @{}; paid = @{} } }
    }

    It 'records a direct failure in the direct bucket' {
        $s = New-State
        $c = @(@{ Domain = 'a.example.com'; Route = 'direct'; Count = 5; Error = 'x' })
        $r = Update-AutoLearnState -State $s -Candidates $c -Now $script:Now -MinHits 1
        $r.Added | Should -Be 1
        $s.direct.ContainsKey('example.com') | Should -BeTrue
    }

    It 'records a proxy failure in the paid bucket' {
        $s = New-State
        $c = @(@{ Domain = 'q.finance.yahoo.com'; Route = 'proxy'; Count = 50; Error = 'x' })
        $r = Update-AutoLearnState -State $s -Candidates $c -Now $script:Now -MinHits 1
        $s.paid.ContainsKey('yahoo.com') | Should -BeTrue
    }

    It 'records a PAID failure nowhere - there is no tier above PAID' {
        # Counting it would refresh the rule that routed the connection to the
        # failing paid path in the first place (the DNS-resolver loop).
        $s = New-State
        $s.paid['alidns.com'] = @{ First = $script:Now.AddDays(-1); Last = $script:Now.AddDays(-1); Hits = 25203 }
        $c = @(@{ Domain = 'dns.alidns.com'; Route = 'paid'; Count = 60; Error = 'EOF' })
        $r = Update-AutoLearnState -State $s -Candidates $c -Now $script:Now -MinHits 1
        $r.Added       | Should -Be 0
        $r.Refreshed   | Should -Be 0
        $s.paid['alidns.com'].Hits | Should -Be 25203
        $s.direct.ContainsKey('alidns.com') | Should -BeFalse
    }

    It 'refreshes rather than duplicates an existing entry' {
        $s = New-State
        $c = @(@{ Domain = 'a.example.com'; Route = 'direct'; Count = 5; Error = 'x' })
        $null = Update-AutoLearnState -State $s -Candidates $c -Now $script:Now -MinHits 1
        $r2 = Update-AutoLearnState -State $s -Candidates $c -Now $script:Now.AddMinutes(1) -MinHits 1
        $r2.Added     | Should -Be 0
        $r2.Refreshed | Should -Be 1
        $s.direct['example.com'].Hits | Should -Be 10
    }

    It 'never learns a domain that already has a manual rule' {
        $s = New-State
        $c = @(@{ Domain = 'www.google.com'; Route = 'direct'; Count = 99; Error = 'x' })
        $r = Update-AutoLearnState -State $s -Candidates $c -ManualDomains @('google.com') -Now $script:Now -MinHits 1
        $r.Added | Should -Be 0
        $s.direct.ContainsKey('google.com') | Should -BeFalse
    }

    It 'moves a domain out of the direct bucket when it escalates to paid' {
        $s = New-State
        $d = @(@{ Domain = 'x.example.com'; Route = 'direct'; Count = 9; Error = 'x' })
        $null = Update-AutoLearnState -State $s -Candidates $d -Now $script:Now -MinHits 1
        $s.direct.ContainsKey('example.com') | Should -BeTrue

        $p = @(@{ Domain = 'x.example.com'; Route = 'proxy'; Count = 90; Error = 'x' })
        $null = Update-AutoLearnState -State $s -Candidates $p -Now $script:Now -MinHits 1
        $s.direct.ContainsKey('example.com') | Should -BeFalse
        $s.paid.ContainsKey('example.com')   | Should -BeTrue
    }

    It 'never demotes a paid escalation back to direct, whatever the candidate order' {
        # The script passes candidates sorted by failure count DESC. With the old
        # unconditional "move out of the other bucket", the lower-count direct
        # candidate was processed LAST and won: a 50-failure proxy escalation was
        # knocked back to AUTO by a 6-failure direct one.
        $s = New-State
        $c = @(
            @{ Domain = 'api.foo.com';  Route = 'proxy';  Count = 50; Error = 'x' },
            @{ Domain = 'www.foo.com';  Route = 'direct'; Count = 6;  Error = 'x' }
        )
        $null = Update-AutoLearnState -State $s -Candidates $c -Now $script:Now -MinHits 1
        $s.paid.ContainsKey('foo.com')   | Should -BeTrue -Because 'paid is the stricter route and must win'
        $s.direct.ContainsKey('foo.com') | Should -BeFalse
    }

    It 'keeps a paid entry alive while the direct path is still failing' {
        $s = New-State
        $s.paid['example.com'] = @{ First = $script:Now.AddDays(-20); Last = $script:Now.AddDays(-20); Hits = 90 }
        $d = @(@{ Domain = 'www.example.com'; Route = 'direct'; Count = 9; Error = 'x' })
        $r = Update-AutoLearnState -State $s -Candidates $d -Now $script:Now -MinHits 1
        $s.paid.ContainsKey('example.com')   | Should -BeTrue
        $s.direct.ContainsKey('example.com') | Should -BeFalse
        $s.paid['example.com'].Last          | Should -Be $script:Now
        $r.Refreshed                         | Should -Be 1
    }

    It 'ignores candidates below MinHits' {
        $s = New-State
        $c = @(@{ Domain = 'a.example.com'; Route = 'direct'; Count = 1; Error = 'x' })
        (Update-AutoLearnState -State $s -Candidates $c -Now $script:Now -MinHits 5).Added | Should -Be 0
    }

    It 'prunes entries older than the TTL' {
        $s = New-State
        $s.direct['old.com'] = @{ First = $script:Now.AddDays(-90); Last = $script:Now.AddDays(-60); Hits = 3 }
        $r = Update-AutoLearnState -State $s -Candidates @() -TtlDays 30 -Now $script:Now
        $r.Pruned | Should -Be 1
        $s.direct.ContainsKey('old.com') | Should -BeFalse
    }

    It 'keeps entries inside the TTL' {
        $s = New-State
        $s.direct['recent.com'] = @{ First = $script:Now.AddDays(-2); Last = $script:Now.AddDays(-1); Hits = 3 }
        $r = Update-AutoLearnState -State $s -Candidates @() -TtlDays 30 -Now $script:Now
        $r.Pruned | Should -Be 0
        $s.direct.ContainsKey('recent.com') | Should -BeTrue
    }

    It 'caps a bucket at MaxPerRoute by dropping the oldest' {
        $s = New-State
        for ($i = 0; $i -lt 10; $i++) {
            $s.direct["d$i.com"] = @{ First = $script:Now.AddDays(-10); Last = $script:Now.AddMinutes(-$i); Hits = 1 }
        }
        $r = Update-AutoLearnState -State $s -Candidates @() -MaxPerRoute 4 -Now $script:Now
        $s.direct.Count | Should -Be 4
        $s.direct.ContainsKey('d9.com') | Should -BeFalse   # oldest
        $s.direct.ContainsKey('d0.com') | Should -BeTrue    # newest
    }

    It 'skips candidates with an unusable route' {
        $s = New-State
        $c = @(@{ Domain = 'a.example.com'; Route = 'other'; Count = 9; Error = 'x' })
        (Update-AutoLearnState -State $s -Candidates $c -Now $script:Now -MinHits 1).Added | Should -Be 0
    }

    It 'NEVER learns a domestic domain, even without the caller filtering' {
        # REGRESSION: the domestic guard originally lived in the calling script,
        # so a direct call to this function learned qq.com - caught by the CI
        # dry run. The guard now lives here and is enforced unconditionally.
        $s = New-State
        $c = @(
            @{ Domain = 'sec.qq.com';            Route = 'direct'; Count = 40; Error = 'x' }
            @{ Domain = 'www.doubao.com';        Route = 'direct'; Count = 60; Error = 'x' }
            @{ Domain = 'real.example.com';      Route = 'direct'; Count = 10; Error = 'x' }
        )
        $r = Update-AutoLearnState -State $s -Candidates $c -Now $script:Now -MinHits 1 `
                -DomesticSuffixes @('qq.com', 'doubao.com')
        $s.direct.ContainsKey('qq.com')     | Should -BeFalse
        $s.direct.ContainsKey('doubao.com') | Should -BeFalse
        $s.direct.ContainsKey('example.com') | Should -BeTrue
        $r.SkippedDomestic | Should -Be 2
    }

    It 'treats a .cn domain as domestic regardless of the suffix list' {
        $s = New-State
        $c = @(@{ Domain = 'shop.example.cn'; Route = 'direct'; Count = 99; Error = 'x' })
        $r = Update-AutoLearnState -State $s -Candidates $c -Now $script:Now -MinHits 1
        $s.direct.Count    | Should -Be 0
        $r.SkippedDomestic | Should -Be 1
    }
    It 'skips IP-literal domains' {
        $s = New-State
        $c = @(@{ Domain = '1.2.3.4'; Route = 'direct'; Count = 9; Error = 'x' })
        (Update-AutoLearnState -State $s -Candidates $c -Now $script:Now -MinHits 1).Added | Should -Be 0
    }
}

Describe 'Rule provider payload round-trip' {
    It 'writes a classical payload with the DOMAIN-SUFFIX prefix' {
        $y = ConvertTo-RuleProviderPayload -Domains @('yahoo.com') -RulePrefix 'DOMAIN-SUFFIX,'
        $y | Should -Match "DOMAIN-SUFFIX,yahoo\.com"
    }

    It 'writes a bare payload when the prefix is empty' {
        $y = ConvertTo-RuleProviderPayload -Domains @('yahoo.com') -RulePrefix ''
        $y | Should -Match "- 'yahoo\.com'"
        $y | Should -Not -Match 'DOMAIN-SUFFIX'
    }

    It 'always emits a payload: key, even when empty' {
        (ConvertTo-RuleProviderPayload -Domains @()) | Should -Match 'payload:'
    }

    It 'round-trips losslessly and strips the classical prefix on read' {
        $domains = @('yahoo.com', 'docker.com', 'a.b.example.org')
        $y = ConvertTo-RuleProviderPayload -Domains $domains -RulePrefix 'DOMAIN-SUFFIX,'
        $back = Get-RuleProviderPayload $y
        @($back | Sort-Object) | Should -Be @($domains | Sort-Object)
    }

    It 'de-duplicates and sorts' {
        $y = ConvertTo-RuleProviderPayload -Domains @('b.com', 'a.com', 'b.com')
        $back = Get-RuleProviderPayload $y
        $back.Count | Should -Be 2
        $back[0]    | Should -Be 'a.com'
    }

    It 'parses an empty payload list as no entries' {
        Get-RuleProviderPayload "payload:`n  []`n" | Should -BeNullOrEmpty
    }

    It 'handles null' {
        @(Get-RuleProviderPayload $null).Count | Should -Be 0
    }
}

Describe 'Get-MihomoRules' {
    It 'extracts rules from a config block' {
        $cfg = @"
mixed-port: 7897
rules:
  - DOMAIN-SUFFIX,a.com,AUTO
  - DOMAIN-SUFFIX,b.com,LOCAL
  - MATCH,LOCAL
other-key: 1
"@
        $r = Get-MihomoRules $cfg
        $r.Count | Should -Be 3
        $r[0]    | Should -Be 'DOMAIN-SUFFIX,a.com,AUTO'
        $r[-1]   | Should -Be 'MATCH,LOCAL'
    }

    It 'ignores comments and blanks inside the block' {
        $cfg = "rules:`n  # a comment`n`n  - MATCH,LOCAL`n"
        (Get-MihomoRules $cfg).Count | Should -Be 1
    }

    It 'strips inline comments' {
        $cfg = "rules:`n  - DOMAIN-SUFFIX,a.com,LOCAL   # measured faster`n"
        (Get-MihomoRules $cfg)[0] | Should -Be 'DOMAIN-SUFFIX,a.com,LOCAL'
    }

    It 'accepts quoted rules' {
        $cfg = "rules:`n  - 'DOMAIN-SUFFIX,a.com,AUTO'`n"
        (Get-MihomoRules $cfg)[0] | Should -Be 'DOMAIN-SUFFIX,a.com,AUTO'
    }

    It 'stops at the next top-level key' {
        $cfg = "rules:`n  - MATCH,LOCAL`nproxy-groups:`n  - name: X`n"
        (Get-MihomoRules $cfg).Count | Should -Be 1
    }

    It 'returns empty for null' {
        @(Get-MihomoRules $null).Count | Should -Be 0
    }
}

Describe 'Test-MihomoRuleSet' {
    BeforeAll {
        $script:Good = @(
            'DOMAIN-SUFFIX,google.com,AUTO'
            'DOMAIN-SUFFIX,cn,LOCAL'
            'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve'
            'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve'
            'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve'
            'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve'
            'MATCH,LOCAL'
        )
    }

    It 'accepts a well-formed rule set' {
        (Test-MihomoRuleSet $script:Good).Ok | Should -BeTrue
    }

    It 'rejects a set that does not end with MATCH' {
        $r = Test-MihomoRuleSet @('DOMAIN-SUFFIX,a.com,AUTO')
        $r.Ok | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match 'MATCH'
    }

    It 'requires the 127.0.0.0/8 loop-protection rule' {
        # Without it mihomo would reach HypoMux through HypoMux - an infinite loop
        $bad = @($script:Good | Where-Object { $_ -notmatch '^IP-CIDR,127\.' })
        $r = Test-MihomoRuleSet $bad
        $r.Ok | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match '127\.0\.0\.0/8'
    }

    It 'requires the 192.168.0.0/16 loop-protection rule' {
        $bad = @($script:Good | Where-Object { $_ -notmatch '^IP-CIDR,192\.168\.' })
        (Test-MihomoRuleSet $bad).Ok | Should -BeFalse
    }

    It 'flags a malformed rule' {
        $bad = @($script:Good) + @('NOCOMMAHERE')
        $bad = @($bad | Where-Object { $_ -ne 'MATCH,LOCAL' }) + @('MATCH,LOCAL')
        (Test-MihomoRuleSet $bad).Ok | Should -BeFalse
    }

    It 'errors on an empty rule set' {
        (Test-MihomoRuleSet @()).Ok | Should -BeFalse
    }

    It 'warns when the catch-all is LOCAL, since unmatched proxy traffic then goes direct' {
        $r = Test-MihomoRuleSet $script:Good
        ($r.Warnings -join ' ') | Should -Match 'catch-all'
    }
}

Describe 'Traffic accounting' {
    BeforeAll {
        function New-Conn($id, $chain, $down, $up) {
            [pscustomobject]@{
                id       = $id
                chains   = $chain
                download = $down
                upload   = $up
                metadata = [pscustomobject]@{ host = "h-$id" }
            }
        }
    }

    It 'starts with zero totals' {
        $s = New-TrafficState
        $s.Totals.proxy.down  | Should -Be 0
        $s.Totals.direct.down | Should -Be 0
    }

    It 'attributes an AUTO chain to the proxy route' {
        $s = New-TrafficState
        $null = Update-ConnectionTraffic -Connections @((New-Conn 'a' @('aliyun-native','AUTO') 1000 10)) -State $s
        $s.Totals.proxy.down | Should -Be 1000
    }

    It 'attributes a LOCAL chain to the direct route' {
        $s = New-TrafficState
        $null = Update-ConnectionTraffic -Connections @((New-Conn 'a' @('hypomux','LOCAL') 2000 20)) -State $s
        $s.Totals.direct.down | Should -Be 2000
    }

    It 'attributes the renewed design: HYPOMUX-PATH is the proxied route' {
        # Design of record 2026-10-11: HYPOMUX-PATH is what rules send proxied
        # traffic to (the catch-all is MATCH,DISPATCH) and its members dial through
        # HypoMux, so anything riding it is proxied traffic.
        $s = New-TrafficState
        $null = Update-ConnectionTraffic -Connections @((New-Conn 'a' @('aliyun-native','HYPOMUX-PATH') 1500 15)) -State $s
        $s.Totals.proxy.down | Should -Be 1500
        $s.Totals.direct.down | Should -Be 0
    }

    It 'attributes plain DIRECT (LOCAL selecting DIRECT) to the direct route' {
        $s = New-TrafficState
        $null = Update-ConnectionTraffic -Connections @((New-Conn 'a' @('DIRECT','LOCAL') 700 7)) -State $s
        $s.Totals.direct.down | Should -Be 700
        $s.Totals.proxy.down | Should -Be 0
    }

    It 'does not mistake the legacy per-NIC names for the direct route' {
        # `DIRECT` must not match `DIRECT-LB`, and `direct-nic5` is not `DIRECT`:
        # the old per-NIC material belongs to the retired design, and a chain that
        # only carries those names stays 'other' rather than inflating 'direct'.
        $s = New-TrafficState
        $null = Update-ConnectionTraffic -Connections @((New-Conn 'a' @('direct-nic5','DIRECT-LB') 900 9)) -State $s
        $s.Totals.direct.down | Should -Be 0
        $s.Totals.other.down | Should -Be 900
    }

    It 'accumulates only the DELTA on a second poll' {
        # This is the whole point: mihomo reports per-connection cumulative bytes,
        # so naive summing would multiply the figure by the number of polls.
        $s = New-TrafficState
        $null = Update-ConnectionTraffic -Connections @((New-Conn 'a' @('AUTO') 1000 10)) -State $s
        $null = Update-ConnectionTraffic -Connections @((New-Conn 'a' @('AUTO') 3000 30)) -State $s
        $s.Totals.proxy.down | Should -Be 3000
        $s.Totals.proxy.up   | Should -Be 30
    }

    It 'forgets a connection once it disappears' {
        $s = New-TrafficState
        $null = Update-ConnectionTraffic -Connections @((New-Conn 'a' @('AUTO') 100 1)) -State $s
        $null = Update-ConnectionTraffic -Connections @() -State $s
        $s.Seen.Count | Should -Be 0
    }

    It 'clamps a negative delta, which happens when a connection id is reused' {
        $s = New-TrafficState
        $null = Update-ConnectionTraffic -Connections @((New-Conn 'a' @('AUTO') 5000 5)) -State $s
        $null = Update-ConnectionTraffic -Connections @((New-Conn 'a' @('AUTO') 100 1)) -State $s
        $s.Totals.proxy.down | Should -Be 5000
    }

    It 'handles null input without throwing' {
        $s = New-TrafficState
        { Update-ConnectionTraffic -Connections $null -State $s } | Should -Not -Throw
    }

    It 'counts active proxy connections in the summary' {
        $c = @(
            (New-Conn 'a' @('aliyun-native','AUTO') 1 1),
            (New-Conn 'b' @('aliyun-native','AUTO') 2 2),
            (New-Conn 'c' @('hypomux','LOCAL') 3 3)
        )
        $sum = Get-ConnectionSummary $c
        $sum.Active      | Should -Be 3
        $sum.ProxyActive | Should -Be 2
    }
}

Describe 'Format-NSBytes' {
    It 'formats bytes'      { Format-NSBytes 512        | Should -Be '512 B' }
    It 'formats kilobytes'  { Format-NSBytes 2048       | Should -Match 'KB' }
    It 'formats megabytes'  { Format-NSBytes 5242880    | Should -Match 'MB' }
    It 'formats gigabytes'  { Format-NSBytes 2147483648 | Should -Match 'GB' }
    It 'handles null'       { Format-NSBytes $null      | Should -Be '0 B' }
}

Describe 'Get-HotspotState' {
    It 'is ok only when the adapter is up and fresh ICS evidence is positive' {
        (Get-HotspotState -AdapterUp $true -Snapshot @{ ics_ok = $true } -SnapshotAgeSec 20 -TaskState 'Ready').State | Should -Be 'ok'
    }

    It 'warns when the adapter is down but the launch task is Ready' {
        (Get-HotspotState -AdapterUp $false -TaskState 'Ready').State | Should -Be 'warn'
    }

    It 'is bad with no adapter and no task' {
        (Get-HotspotState -AdapterUp $false -TaskState 'absent').State | Should -Be 'bad'
    }

    It 'exposes snapshot details when the snapshot is fresh' {
        $snap = [pscustomobject]@{ ssid = 'HypoMux'; band = 'FiveGigahertz'; auth = 'Wpa2'; max_clients = 8; client_count = 1; clients = @() }
        $r = Get-HotspotState -AdapterUp $true -Snapshot $snap -SnapshotAgeSec 20
        $r.Ssid          | Should -Be 'HypoMux'
        $r.SnapshotFresh | Should -BeTrue
    }

    It 'ignores a stale snapshot instead of presenting it as current' {
        $snap = [pscustomobject]@{ ssid = 'HypoMux'; max_clients = 8; client_count = 1; clients = @() }
        $r = Get-HotspotState -AdapterUp $true -Snapshot $snap -SnapshotAgeSec 5000 -MaxSnapshotAgeSec 600
        $r.SnapshotFresh | Should -BeFalse
        $r.Ssid          | Should -Be ''
    }
}

Describe 'Test-HealthCheckUrl' {
    It 'accepts a real 204 endpoint' {
        (Test-HealthCheckUrl 'http://connect.rom.miui.com/generate_204').Ok | Should -BeTrue
    }

    It 'REJECTS a bare IP as the health-check host' {
        # REGRESSION: LOCAL used http://223.5.5.5 (AliDNS). It does not serve HTTP,
        # the probe failed every time, hypomux was marked dead, and LOCAL quietly
        # fell back to DIRECT - so HypoMux carried nothing while every dashboard
        # surface still showed green.
        $r = Test-HealthCheckUrl 'http://223.5.5.5'
        $r.Ok | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match 'bare IP'
    }

    It 'accepts an https URL' {
        (Test-HealthCheckUrl 'https://www.baidu.com').Ok | Should -BeTrue
    }

    It 'rejects an empty URL' {
        (Test-HealthCheckUrl '').Ok    | Should -BeFalse
        (Test-HealthCheckUrl $null).Ok | Should -BeFalse
    }

    It 'rejects a non-http scheme' {
        (Test-HealthCheckUrl 'ftp://example.com/x').Ok | Should -BeFalse
    }

    It 'rejects a blocked domain as the probe for a DIRECT-path group' {
        # HypoMux distributes across NICs; it is not a proxy, so it can never
        # reach google.com from the mainland.
        $r = Test-HealthCheckUrl -Url 'https://www.google.com/generate_204' -DirectPathGroup
        $r.Ok | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match 'blocked'
    }

    It 'allows a blocked domain for a PROXY group' {
        # AUTO/PAID go through a proxy, so google.com is a valid probe there
        (Test-HealthCheckUrl -Url 'https://www.google.com/generate_204').Ok | Should -BeTrue
    }
}
Describe 'Compare-AdapterState' {
    It 'does nothing when the adapter set is unchanged' {
        $r = Compare-AdapterState -Previous @('eth0') -Current @('eth0') -Pool @('eth0') -DnsServer '10.0.0.1' -DnsValid $true
        $r.Action      | Should -Be 'none'
        $r.PoolChanged | Should -BeFalse
    }

    It 'REQUESTS A RESTART when a pooled adapter goes bad' {
        # REGRESSION: a dead NIC left in the pool made HypoMux spread connections
        # onto it, so ~half of all requests failed - measured hypomux
        # `000 200 000 200` while direct was `200 200 200 200`.
        $r = Compare-AdapterState -Previous @('eth0','wlan0') -Current @('eth0') `
                -Pool @('eth0','wlan0') -DnsServer '10.0.0.1' -DnsValid $true
        $r.Action      | Should -Be 'restart'
        $r.Disappeared | Should -Contain 'wlan0'
        $r.NewPool     | Should -Be @('eth0')
    }

    It 'asks for an update when a new adapter appears' {
        $r = Compare-AdapterState -Previous @('eth0') -Current @('eth0','wlan0') -Pool @('eth0') -DnsServer '10.0.0.1' -DnsValid $true
        $r.Action  | Should -Be 'update'
        $r.Appeared | Should -Contain 'wlan0'
    }

    It 'asks for an update when the DNS address is no longer bound' {
        # HypoMux source-binds to a NIC and cannot use 127.0.0.1, so if the
        # configured address stops being bound, resolution breaks entirely.
        $r = Compare-AdapterState -Previous @('eth0') -Current @('eth0') -Pool @('eth0') `
                -DnsServer '192.168.1.100' -DnsValid $false
        $r.Action     | Should -Be 'update'
        $r.DnsChanged | Should -BeTrue
    }

    It 'flags a changed pool even when no adapter appeared or disappeared' {
        $r = Compare-AdapterState -Previous @('eth0') -Current @('eth0') -Pool @('eth0','wlan0') -DnsServer 'x' -DnsValid $true
        $r.PoolChanged | Should -BeTrue
        $r.Action      | Should -Be 'update'
    }

    It 'handles an empty usable set without throwing' {
        $r = Compare-AdapterState -Previous @('eth0') -Current @() -Pool @('eth0') -DnsServer 'x' -DnsValid $true
        $r.Action      | Should -Be 'restart'
        $r.UsableCount | Should -Be 0
    }

    It 'handles null inputs' {
        { Compare-AdapterState -Previous $null -Current $null } | Should -Not -Throw
    }
}

Describe 'Select-HypoMuxDnsAddress' {
    It 'prefers an address on a usable adapter' {
        $addrs = @{ 'eth0' = '10.0.0.5'; 'wlan0' = '192.168.1.5' }
        Select-HypoMuxDnsAddress -BoundAddresses @('127.0.0.1','192.168.1.5','10.0.0.5') `
            -AdapterAddresses $addrs | Should -Be '10.0.0.5'
    }

    It 'never returns loopback, which a NIC-bound socket cannot reach' {
        Select-HypoMuxDnsAddress -BoundAddresses @('127.0.0.1','::1') -AdapterAddresses @{} | Should -Be ''
    }

    It 'never returns the wildcard bind address' {
        Select-HypoMuxDnsAddress -BoundAddresses @('0.0.0.0') -AdapterAddresses @{} | Should -Be ''
    }

    It 'falls back to any non-loopback bound address' {
        Select-HypoMuxDnsAddress -BoundAddresses @('10.9.9.9') -AdapterAddresses @{ 'eth0' = '10.0.0.5' } | Should -Be '10.9.9.9'
    }

    It 'handles an empty list' {
        Select-HypoMuxDnsAddress -BoundAddresses @() -AdapterAddresses @{} | Should -Be ''
    }
}
Describe 'Get-SafeProperty' {
    It 'reads an existing property' {
        Get-SafeProperty ([pscustomobject]@{ a = 1 }) 'a' | Should -Be 1
    }

    It 'returns the default for a missing property instead of throwing' {
        # Set-StrictMode is on in the module, so this must not throw
        { Get-SafeProperty ([pscustomobject]@{ a = 1 }) 'zzz' 'fallback' } | Should -Not -Throw
        Get-SafeProperty ([pscustomobject]@{ a = 1 }) 'zzz' 'fallback'   | Should -Be 'fallback'
    }

    It 'returns the default for null input' {
        Get-SafeProperty $null 'a' 'd' | Should -Be 'd'
    }
}
