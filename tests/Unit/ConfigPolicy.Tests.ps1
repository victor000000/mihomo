BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'src\NetStack\ConfigPolicy.psm1') -Force
    $script:Template = @'
allow-lan: false
bind-address: 127.0.0.1
ipv6: true
dns:
  enable: true
  nameserver-policy:
    "+.example.com":
      - https://1.1.1.1/dns-query
proxies:
  - name: fixture
    uuid: REPLACE-UUID
proxy-groups:
  - name: AUTO
    type: fallback
    proxies:
      - first
      - second
rules:
  - DOMAIN-SUFFIX,example.com,AUTO
  - MATCH,DIRECT
'@
}

Describe 'redacted configuration-policy drift reporting' {
    It 'ignores credential payload differences' {
        $deployed = $script:Template.Replace('REPLACE-UUID', 'REPLACE-DIFFERENT-UUID')
        $r = Compare-MihomoPolicy $script:Template $deployed
        $r.RequiresReview | Should -BeFalse
        ($r | ConvertTo-Json -Depth 5) | Should -Not -Match 'REPLACE-DIFFERENT-UUID|REPLACE-UUID'
    }

    It 'detects policy membership order changes without printing group payloads' {
        $deployed = $script:Template.Replace("      - first`n      - second", "      - second`n      - first")
        $r = Compare-MihomoPolicy $script:Template $deployed
        $r.RequiresReview | Should -BeTrue
        @($r.Changes | Where-Object { $_.Area -eq 'group' }).Count | Should -Be 1
    }

    It 'detects first-match rule order changes even when counts match' {
        $deployed = $script:Template.Replace("  - DOMAIN-SUFFIX,example.com,AUTO`n  - MATCH,DIRECT", "  - MATCH,DIRECT`n  - DOMAIN-SUFFIX,example.com,AUTO")
        $r = Compare-MihomoPolicy $script:Template $deployed
        @($r.Changes | Where-Object { $_.Area -eq 'rules' }).Count | Should -Be 1
    }

    It 'reports changed LAN binding explicitly' {
        $r = Compare-MihomoPolicy $script:Template ($script:Template.Replace('allow-lan: false', 'allow-lan: true'))
        $change = $r.Changes | Where-Object { $_.Name -eq 'allow-lan' }
        $change.Template | Should -Be 'false'
        $change.Deployed | Should -Be 'true'
    }

    It 'counts obsolete domain-prefixed DNS keys' {
        $r = Compare-MihomoPolicy $script:Template ($script:Template.Replace('+.example.com', 'domain:example.com'))
        $r.ObsoleteDeployedDnsKeys | Should -Be 1
    }

    It 'ignores comments and compares equivalent line endings' {
        $deployed = "# fixture`r`n" + ($script:Template -replace "`n", "`r`n")
        (Compare-MihomoPolicy $script:Template $deployed).RequiresReview | Should -BeFalse
    }

    It 'detects removal of subscription-backed members' {
        $withProvider = $script:Template.Replace('rules:', "    use:`n      - clashmi`nrules:")
        $r = Compare-MihomoPolicy $withProvider $script:Template
        $r.RequiresReview | Should -BeTrue
        @($r.Changes | Where-Object { $_.Area -eq 'group' }).Count | Should -Be 1
    }

    It 'supports inline provider memberships and preserves their source kind' {
        $withProvider = $script:Template.Replace('rules:', "    use: [clashmi]`nrules:")
        $withProxy = $script:Template.Replace('rules:', "    proxies: [clashmi]`nrules:")
        (Compare-MihomoPolicy $withProvider $script:Template).RequiresReview | Should -BeTrue
        (Compare-MihomoPolicy $withProvider $withProxy).RequiresReview | Should -BeTrue
    }

    It 'does not interpret outbound secrets as proxy-group membership' {
        $summary = Get-MihomoPolicySummary $script:Template
        $summary.Groups.Count | Should -Be 1
        $summary.Groups.ContainsKey('fixture') | Should -BeFalse
    }
}
