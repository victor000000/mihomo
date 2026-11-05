<#
.SYNOPSIS
    Parsing for the Windows hosts-file pin blocks this stack maintains.

.DESCRIPTION
    Two names are pinned in the Windows hosts file because the local resolver answers
    them with a wrong address (a poisoned or hijacked answer), and both pins can silently
    rot:

      * www.usvisascheduling.com - the resolver answered 141.193.154.210, which is not a
        Cloudflare address and does not accept TCP 443, while every public resolver and
        DoH-through-the-tunnel agreed on 172.64.146.157. The site is a Cloudflare property,
        so its edge IP can change.
      * the StrategyQuant CDN fleet - cdn001..cdn005 plus the generic name, pinned to the
        HK edge (8.210.228.126) because the EU edges are 380-800 ms away against 71-98 ms.
        A vendor can move an edge.

    The parsing lives here, not inside start-network.ps1, so it can be unit tested without
    a live hosts file, a network, or elevation - the script does the live half (TCP 443
    against each pinned address) and this module does the pure half.

    Both functions are pure: text in, objects out. No file IO, no network.

.NOTES
    Delimiter convention, matching what the pin blocks in the hosts file use:

        # mihomo: <marker>        <- the marker line, inside a comment run
        # ...free-form comment lines...
        8.210.228.126  cdn001.strategyquantcdn.com
        8.210.228.126  cdn002.strategyquantcdn.com

    Everything after the marker up to the first blank line or the first line that is
    neither a comment nor an entry ends the block.
#>

function Get-HostsPinBlock {
    <#
    .SYNOPSIS
        Returns the entries of the pin block whose marker matches, or $null.
    .PARAMETER Text
        The whole hosts file as a string.
    .PARAMETER Marker
        The marker as it appears after `# mihomo: `, e.g. 'strategyquant cdn'.
    .OUTPUTS
        PSCustomObject with Marker, Line (1-based) and Entries (IP, Names, Line).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Marker
    )

    if ([string]::IsNullOrWhiteSpace($Text) -or [string]::IsNullOrWhiteSpace($Marker)) { return $null }

    $lines = $Text -split "\r?\n"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        # The marker line carries prose after it in practice ('# mihomo: strategyquant cdn - use
        # the HK edge, not the EU ones'), so match the marker and allow a suffix - requiring the
        # marker to be the whole line made the parser return $null for every real block.
        if ($lines[$i] -match ('^#\s*mihomo:\s*' + [regex]::Escape($Marker) + '(?:\s|$|-)')) { $start = $i; break }
    }
    if ($start -lt 0) { return $null }

    $entries = New-Object System.Collections.Generic.List[object]
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $line = $raw.Trim()
        if ($line -eq '') { break }                       # blank line ends the block
        if ($line.StartsWith('#')) { continue }           # the prose that documents the pin
        # An entry is <address> <name> [<name> ...], whitespace separated.
        $m = [regex]::Match($line, '^(\S+)\s+(\S.*)$')
        if (-not $m.Success) { break }                    # anything else ends the block too
        $names = @($m.Groups[2].Value -split '\s+' | Where-Object { $_ })
        $entries.Add([pscustomobject]@{
            IP    = $m.Groups[1].Value
            Names = $names
            Line  = $i + 1
        })
    }

    return [pscustomobject]@{
        Marker  = $Marker
        Line    = $start + 1
        Entries = $entries
    }
}

function Test-HostsPinBlock {
    <#
    .SYNOPSIS
        Returns a list of problems with a parsed pin block; empty means it is well formed.
    .DESCRIPTION
        Checks the shape, not the reachability: a valid IPv4 address per entry, at least
        one name per entry, no name claimed twice inside the block, and no name claimed by
        the block that is also claimed elsewhere in the file (a second entry for the same
        name is a silent override in hosts-file semantics - the first one wins, so the
        second is dead and misleading).
    .PARAMETER Block
        Output of Get-HostsPinBlock.
    .PARAMETER AllText
        Optional: the whole hosts file, to detect a name claimed outside this block.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()] $Block,
        [AllowEmptyString()][string] $AllText = ''
    )

    $problems = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Block) { $problems.Add('no block parsed'); return $problems.ToArray() }
    if ($Block.Entries.Count -eq 0) { $problems.Add("block '$($Block.Marker)' has no entries") }

    $seen = @{}
    foreach ($e in $Block.Entries) {
        $parsed = $null
        if (-not [System.Net.IPAddress]::TryParse($e.IP, [ref]$parsed) -or $parsed.AddressFamily -ne 'InterNetwork') {
            $problems.Add("line $($e.Line): '$($e.IP)' is not an IPv4 address")
        }
        if (-not $e.Names -or $e.Names.Count -eq 0) {
            $problems.Add("line $($e.Line): no host name")
        }
        foreach ($n in $e.Names) {
            if ($seen.ContainsKey($n)) {
                $problems.Add("line $($e.Line): '$n' is claimed twice in the block (first at line $($seen[$n]))")
            } else { $seen[$n] = $e.Line }
            if ($n -notmatch '^[A-Za-z0-9]([A-Za-z0-9\-\.]*[A-Za-z0-9])?$') {
                $problems.Add("line $($e.Line): '$n' is not a host name")
            }
        }
    }

    if ($AllText) {
        foreach ($n in $seen.Keys) {
            $outside = @()
            $lines = $AllText -split "\r?\n"
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($i + 1 -eq $Block.Line) { continue }
                $l = $lines[$i].Trim()
                if ($l -eq '' -or $l.StartsWith('#')) { continue }
                if (($l -split '\s+') -contains $n) { $outside += ($i + 1) }
            }
            # Entries of THIS block are expected; only count lines that are not ours.
            $ours = @($Block.Entries | Where-Object { $_.Names -contains $n } | ForEach-Object { $_.Line })
            $foreign = @($outside | Where-Object { $ours -notcontains $_ })
            if ($foreign.Count) {
                $problems.Add("'$n' is also mapped outside this block (line(s) $($foreign -join ', ')) - hosts-file semantics keep the FIRST entry, so one of them is dead")
            }
        }
    }

    return $problems.ToArray()
}

Export-ModuleMember -Function Get-HostsPinBlock, Test-HostsPinBlock
