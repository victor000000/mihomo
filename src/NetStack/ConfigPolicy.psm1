function Get-MihomoPolicySummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Text)

    $core = @{}
    $groups = @{}
    $rules = New-Object System.Collections.Generic.List[string]
    $dnsKeys = New-Object System.Collections.Generic.List[string]
    $section = ''; $group = ''; $inMembers = $false; $memberSource = ''; $inDnsPolicy = $false
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^\s*(#|$)') { continue }
        if ($line -match '^([a-z][a-z0-9-]*):') { $section = $Matches[1]; $inDnsPolicy = $false }
        if ($line -match '^(allow-lan|bind-address|ipv6):\s*([^#]+)') {
            $core[$Matches[1]] = $Matches[2].Trim().Trim("'").Trim('"')
        }
        if ($section -in @('tun', 'dns', 'sniffer') -and $line -match '^  (enable|ipv6):\s*(true|false)\b') {
            $core["$section.$($Matches[1])"] = $Matches[2]
        }
        if ($section -eq 'dns') {
            if ($line -match '^  nameserver-policy:\s*$') { $inDnsPolicy = $true; continue }
            if ($line -match '^  \S') { $inDnsPolicy = $false }
            if ($inDnsPolicy -and $line -match '^    ["'']?([+*.a-zA-Z0-9_!,:/-]+)["'']?:\s*$') { $dnsKeys.Add($Matches[1]) }
        }
        if ($section -eq 'proxy-groups') {
            if ($line -match '^  - name:\s*([^#]+)') {
                $group = $Matches[1].Trim().Trim("'").Trim('"')
                $groups[$group] = @{ type = ''; members = New-Object System.Collections.Generic.List[string]; filter = '' }
                $inMembers = $false
            } elseif ($group -and $line -match '^    type:\s*([^#]+)') {
                $groups[$group].type = $Matches[1].Trim()
            } elseif ($group -and $line -match '^    filter:\s*(.+)$') {
                $groups[$group].filter = $Matches[1].Trim()
                $inMembers = $false
            } elseif ($line -match '^    (proxies|use):\s*$') { $memberSource = $Matches[1]; $inMembers = $true }
            elseif ($line -match '^    (proxies|use):\s*\[([^\]]*)\]') {
                $source = $Matches[1]
                foreach ($member in ($Matches[2] -split ',')) {
                    $value = $member.Trim().Trim("'").Trim('"')
                    if ($value) { $groups[$group].members.Add("$source|$value") }
                }
                $inMembers = $false
            }
            elseif ($line -match '^    [a-z]') { $inMembers = $false }
            elseif ($group -and $inMembers -and $line -match '^      -\s+([^#]+)') { $groups[$group].members.Add("$memberSource|$($Matches[1].Trim())") }
        }
        if ($section -eq 'rules' -and $line -match '^\s*-\s*(.+)$') { $rules.Add(($Matches[1] -replace '\s+#.*$', '').Trim()) }
    }
    [pscustomobject]@{ Core = $core; Groups = $groups; Rules = $rules.ToArray(); DnsKeys = $dnsKeys.ToArray() }
}

function Compare-MihomoPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Template, [Parameter(Mandatory)] [string] $Deployed)

    $left = Get-MihomoPolicySummary $Template
    $right = Get-MihomoPolicySummary $Deployed
    $changes = New-Object System.Collections.Generic.List[object]
    foreach ($key in @(@($left.Core.Keys) + @($right.Core.Keys) | Sort-Object -Unique)) {
        if ($left.Core[$key] -ne $right.Core[$key]) {
            $changes.Add([pscustomobject]@{ Area = 'core'; Name = $key; Template = $left.Core[$key]; Deployed = $right.Core[$key] })
        }
    }
    foreach ($name in @(@($left.Groups.Keys) + @($right.Groups.Keys) | Sort-Object -Unique)) {
        $a = $left.Groups[$name]; $b = $right.Groups[$name]
        $different = $null -eq $a -or $null -eq $b
        if (-not $different) {
            $different = $a.type -ne $b.type -or ($a.members -join "`n") -cne ($b.members -join "`n") -or $a.filter -cne $b.filter
        }
        if ($different) { $changes.Add([pscustomobject]@{ Area = 'group'; Name = $name; TemplatePresent = ($null -ne $a); DeployedPresent = ($null -ne $b) }) }
    }
    if (($left.Rules -join "`n") -cne ($right.Rules -join "`n")) {
        $changes.Add([pscustomobject]@{ Area = 'rules'; Name = 'ordered-rules'; TemplateCount = $left.Rules.Count; DeployedCount = $right.Rules.Count })
    }
    if (($left.DnsKeys -join "`n") -cne ($right.DnsKeys -join "`n")) {
        $changes.Add([pscustomobject]@{ Area = 'dns'; Name = 'policy-keys'; TemplateCount = $left.DnsKeys.Count; DeployedCount = $right.DnsKeys.Count })
    }
    [pscustomobject]@{
        RequiresReview = $changes.Count -gt 0
        Changes = $changes.ToArray()
        ObsoleteDeployedDnsKeys = @($right.DnsKeys | Where-Object { $_ -like 'domain:*' }).Count
        Scope = 'Core switches, proxy-group membership/filter and rule/DNS-key order; credentials and endpoint payloads excluded.'
    }
}

Export-ModuleMember -Function Get-MihomoPolicySummary, Compare-MihomoPolicy
