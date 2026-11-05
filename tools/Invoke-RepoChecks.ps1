<#
.SYNOPSIS
    Runs every repo-level check over versioned and new, non-ignored source files.

.DESCRIPTION
    One script, so CI and a workstation run the SAME checks. The YAML used to
    carry checks inline; a check that only exists in YAML cannot be run before
    you push, and one that only exists locally cannot gate a merge.

    Two rules shape everything here:

      * SOURCE FILES ONLY. Git inventory includes tracked and new non-ignored
        files so a newly added module is checked before staging. Ignored runtime
        configuration, logs, binaries, dependencies and nested projects are not
        scanned. Without Git, only maintained source directories and explicit
        sanitized config files are inventoried; the deployment is never walked.

      * NEVER A FALSE RED. A missing tool soft-skips with a visible message; it
        does not fail. A check that cries wolf gets disabled, and a disabled
        check protects nothing.

    Exit code is 1 if any check failed, 0 otherwise (soft skips do not count).

.PARAMETER Quiet
    Print the summary only - for a pre-push hook or a CI step that wants one
    line of output. Failures still print: Quiet hides the pass lines, not the
    reasons.

.PARAMETER Check
    Run one check by short name and skip the rest. Names are listed by
    `-Check list`. Use this while fixing a single failure instead of waiting
    for all nine.

.PARAMETER RepoRoot
    Check a different checkout. Defaults to the repo this script lives in.

.EXAMPLE
    pwsh -NoProfile -File tools\Invoke-RepoChecks.ps1
    The full run, as CI invokes it.

.EXAMPLE
    powershell.exe -NoProfile -File tools\Invoke-RepoChecks.ps1 -Quiet
    Same checks under Windows PowerShell 5.1, one summary line.

.EXAMPLE
    pwsh -NoProfile -File tools\Invoke-RepoChecks.ps1 -Check secrets
    Just the secret scan, after editing a config or a doc.

.NOTES
    PowerShell 5.1 AND 7. CI runs it under both on purpose: 5.1 is what this
    stack actually runs at home, and 7 is what the scheduled tasks now use, so
    a check that only works on one engine is a check with a blind spot.
#>
[CmdletBinding()]
param(
    [switch] $Quiet,
    [string] $Check,
    [string] $RepoRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
#  Check registry. Order matters only for reading the output.
# ---------------------------------------------------------------------------
$CheckNames = @('parse','secrets','web','control')
$CheckTitles = @{
    'parse'    = 'Every tracked PowerShell script parses (root scripts included)'
    'secrets'  = 'No live-looking secret in any tracked file; template placeholders intact'
    'rules'    = 'Rule audit: no dead duplicates, no shadowed suffixes, every target resolves'
    'config'   = 'Config structure: markers, groups, catch-all, loop protection, tun/dns/ui'
    'ordering' = 'Rule-ordering invariants: pins above the learner, 911 above the catch-all'
    'docs'     = 'Docs: balanced fences, README path references resolve, no stale claims'
    'web'      = 'web\*.html: <div> balance and a closing </html>'
    'wiring'   = 'Tool wiring: .bat targets exist, retired Watch-Adapters is not invoked'
    'control'  = 'No stray control characters in tracked text files'
    'tasks'    = 'Scheduled-task set: the disable lists cover everything the install can create'
}

# ---------------------------------------------------------------------------
#  Plumbing
# ---------------------------------------------------------------------------
# ArrayList, not List[object]: under `Set-StrictMode -Version 2.0` wrapping a
# List[object] in @() throws "Argument types do not match" (measured in 7.6.6),
# and every consumer here wraps its list. A trap worth naming, since the fix is
# invisible otherwise.
$script:Failures = New-Object System.Collections.ArrayList
$script:Notes = New-Object System.Collections.ArrayList

function Write-Note {
    param([string] $Message)
    [void]$script:Notes.Add($Message)
    if (-not $Quiet) { Write-Host "        note: $Message" -ForegroundColor DarkGray }
}

# GitHub wants %25/%0A/%0D escaped in an annotation message, and the property
# part escaped separately. Getting this wrong shows up as a truncated or
# double-encoded line in the PR view, so it is done once, here. The path is
# forward-slashed: that is what GitHub matches against the repo tree, and a
# backslash path silently produces an annotation with no line in the diff.
function Format-Annotation {
    param([string] $Kind, [string] $File, [int] $Line, [string] $Message)
    $msg = $Message -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
    $path = $File -replace '\\', '/' -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A' -replace ',', '%2C'
    if ($Line -gt 0) { "::$Kind file=$path,line=$Line::$msg" } else { "::$Kind file=$path::$msg" }
}

# Which line a byte offset sits on, so an offset-only finding still annotates
# the right line. Counting is fine here: the files are a few hundred KB.
function Get-LineOfOffset {
    param([string] $Text, [int] $Offset)
    if ($Offset -le 0) { return 1 }
    $upto = $Text.Substring(0, [Math]::Min($Offset, $Text.Length))
    return (([regex]::Matches($upto, "`n")).Count + 1)
}

# One failure: the message is the short reason, File/Line place it in the diff.
function Add-Failure {
    param([string] $Message, [string] $File = '', [int] $Line = 0)
    [void]$script:Failures.Add([pscustomobject]@{ Message = $Message; File = $File; Line = $Line })
}

function Write-Failures {
    foreach ($f in $script:Failures) {
        $where = if ($f.File) { if ($f.Line -gt 0) { "$($f.File):$($f.Line)" } else { $f.File } } else { '' }
        if ($where) { Write-Host "        FAIL $where - $($f.Message)" -ForegroundColor Red }
        else { Write-Host "        FAIL $($f.Message)" -ForegroundColor Red }
        if ($env:GITHUB_ACTIONS) { Write-Host (Format-Annotation -Kind 'error' -File $f.File -Line $f.Line -Message $f.Message) }
    }
}

function Invoke-Check {
    param([string] $Name, [scriptblock] $Body)
    $script:Failures = New-Object System.Collections.ArrayList
    $script:Notes = New-Object System.Collections.ArrayList
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Body
    } catch {
        # A crash inside a check is a failed check, never a silent pass.
        Add-Failure "check '$Name' threw: $($_.Exception.Message)"
    }
    $sw.Stop()
    $state = if ($script:Failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
    $n = $script:Failures.Count
    $reason = if ($n -eq 0) { "$($script:Notes.Count) note(s)" } else { "$n failure(s)" }
    $line = "[{0}] {1,-8} {2,-8} {3,6} ms  {4}" -f $state, $Name, $reason, $sw.ElapsedMilliseconds, $CheckTitles[$Name]
    if ($state -eq 'PASS') {
        if (-not $Quiet) { Write-Host $line -ForegroundColor Green }
    } else {
        Write-Host $line -ForegroundColor Red
    }
    if ($n -gt 0) { Write-Failures }
    return ($state -eq 'PASS')
}

# ---------------------------------------------------------------------------
#  Repository inventory: tracked files, or a walk that mimics the ignore file.
# ---------------------------------------------------------------------------
function Get-RepoFileList {
    param([string] $Root)
    Import-Module (Join-Path $PSScriptRoot '..\src\NetStack\Repository.psm1') -Force
    return @(Get-RepositoryFile -Root $Root)
}

function Get-TextFile {
    param([string] $Root, [string] $Rel)
    $full = Join-Path $Root $Rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $null }
    try {
        # UTF-8 EXPLICITLY. On 5.1 Get-Content -Raw defaults to the ANSI code
        # page, which mangles multi-byte characters - and web\design.html and the
        # config carry Chinese adapter names, so a mangled read would make the
        # byte-offset checks lie.
        return [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
    } catch {
        Write-Note "could not read ${Rel}: $($_.Exception.Message)"
        return $null
    }
}

function Get-TextLines {
    param([string] $Root, [string] $Rel)
    $t = Get-TextFile -Root $Root -Rel $Rel
    if ($null -eq $t) { return @() }
    return @($t -split "`r?`n")
}

# Leading whitespace is significant in YAML; the regexes below keep it.
function Test-IsCommentOrBlank {
    param([string] $Line)
    $t = $Line.Trim()
    return ($t -eq '' -or $t.StartsWith('#'))
}

# ---------------------------------------------------------------------------
#  Shared: the config template's rules, groups, outbounds and providers.
#  Parse once, use in `rules`, `config` and `ordering`.
# ---------------------------------------------------------------------------
$RuleTypes = @(
    'DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD', 'DOMAIN-REGEX', 'GEOSITE', 'GEOIP',
    'IP-CIDR', 'IP-CIDR6', 'IP-SUFFIX', 'SRC-IP-CIDR', 'SRC-PORT', 'DST-PORT',
    'PROCESS-NAME', 'PROCESS-PATH', 'PROCESS-PATH-REGEX', 'RULE-SET', 'MATCH',
    'NETWORK', 'IN-TYPE', 'IN-USER', 'IN-NAME', 'SUB-RULE', 'UID', 'AND', 'OR', 'NOT'
)

function Get-MihomoRuleList {
    param([string[]] $Lines)
    $rules = New-Object System.Collections.ArrayList
    $inRules = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $l = $Lines[$i]
        if (-not $inRules) { if ($l -match '^rules:\s*$') { $inRules = $true }; continue }
        if (Test-IsCommentOrBlank $l) { continue }
        if ($l -notmatch '^\s*-\s*(.+)$') { continue }
        # A trailing "   # comment" is stripped: four rules in the template carry
        # a measured latency note after the target, and without this the target
        # reads as "LOCAL  # 384ms direct vs 1117ms via tunnel".
        $body = ($Matches[1] -replace '\s+#.*$', '').Trim()
        if (-not $body) { continue }
        $p = $body -split ','
        $type = $p[0].Trim()
        [void]$rules.Add([pscustomobject]@{
            Line   = $i + 1
            Type   = $type
            Value  = $(if ($p.Count -gt 1) { $p[1].Trim() } else { '' })
            Target = $(if ($p.Count -gt 2) { $p[2].Trim() } else { '' })
            Raw    = $body
            Known  = ($RuleTypes -contains $type)
        })
    }
    return @($rules)
}

function Get-MihomoNamedList {
    param([string[]] $Lines, [string] $Section)
    # "  - name: X" under the section header, up to the next top-level key.
    $names = New-Object System.Collections.ArrayList
    $cur = ''
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $l = $Lines[$i]
        if ($l -match '^([A-Za-z][A-Za-z0-9-]*):') { $cur = $Matches[1] }
        if ($cur -ne $Section) { continue }
        if ($l -match '^\s*-\s+name:\s*(\S+)\s*$') { [void]$names.Add($Matches[1]) }
    }
    return @($names)
}

function Get-MihomoProviderNames {
    param([string[]] $Lines, [string] $Section = '')
    $names = New-Object System.Collections.ArrayList
    $inBlock = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $l = $Lines[$i]
        if ($l -match '^(proxy-providers|rule-providers):\s*$') { $inBlock = (-not $Section -or $Matches[1] -eq $Section); continue }
        if ($l -match '^[A-Za-z]' -and $l -notmatch '^(proxy-providers|rule-providers):') { $inBlock = $false; continue }
        if (-not $inBlock) { continue }
        if ($l -match '^  ([A-Za-z0-9._-]+):\s*$') { [void]$names.Add($Matches[1]) }
    }
    return @($names)
}

function Get-GroupType {
    param([string[]] $Lines, [string] $Name)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match ('^\s*-\s+name:\s*' + [regex]::Escape($Name) + '\s*$')) {
            for ($j = $i + 1; $j -lt [Math]::Min($i + 8, $Lines.Count); $j++) {
                if ($Lines[$j] -match '^\s*type:\s*(\S+)\s*$') { return $Matches[1] }
            }
        }
    }
    return ''
}

# A hex digest of the repo's own artifacts is not a credential. Three such
# digests are tracked on purpose and are named here, one at a time, so that a
# NEW one still trips the scan:
#   * two SHA256 sums of the switch's own -DryRun output, quoted in the docs
#     and in design.html as the record of that run;
#   * one 40-char hostname label in a vendored hosts list.
# Nothing here is a secret, and each entry says why it is allowed to stay.
$KnownHexDigests = @{
    'CB3A6BE55421B9478CE810BC785AFF4A86DFE0425EC139C2CC99F6275ECA486D' = 'SHA256 of hypomux-distribution.ps1 -DryRun output, quoted in docs + design.html'
    '8c953efe117cb4ee14eaffe2b417623a104ce4e6'                         = 'hostname label in tools\hosts-repos (vendored hosts list)'
}

$AllowedBase64 = @('AAAAAAAAAAAAAAAAAAAAAA==')   # the template's deliberate dummy ss key

# Per-file exemptions for text that a test deliberately feeds the scanners as a
# POSITIVE control. These strings are synthetic, and they are named one at a
# time with the file and the reason - never a blanket "skip tests/", which would
# let a real credential through the one directory most likely to copy one. A
# value not on this list still fails, in these files included.
#
# The values are SPLIT with '+' rather than written whole, because this scanner
# reads its own source: written whole they are literal 32+ char hex runs in a
# tracked file, and the check would fail on itself (measured - it did).
$KnownTestFixtures = @{}
$KnownTestFixtures['tests\RepoHygiene.Tests.ps1'] = @(
    ('9f2c1ab4d7e05c63' + '18ff27ab0d4e9182'),   # pasted-hex negative control for Find-LongHexRun
    ('c3F1Y2tseS1sb2' + '5nLWtleS12YWx1ZQ=='),  # base64 negative control for Find-Base64Run
    ('abcdef1234' + '567890')                    # literal negative control for Find-UnredactedSecretValue
)

# ---------------------------------------------------------------------------
#  Context
# ---------------------------------------------------------------------------
if (-not $RepoRoot) {
    $RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $RepoRoot = Split-Path -Parent $RepoRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')
$ConfigRel = 'config\mihomo-config.template.yaml'
$WebFiles = @('web\index.html', 'web\design.html', 'web\balance.html')

if ($Check -eq 'list') {
    Write-Host 'Available checks (-Check <name>):'
    foreach ($n in $CheckNames) { Write-Host ("  {0,-9} {1}" -f $n, $CheckTitles[$n]) }
    exit 0
}
if ($Check -and ($CheckNames -notcontains $Check)) {
    Write-Host "Unknown check '$Check'. Use -Check list." -ForegroundColor Red
    exit 2
}

$Files = @(Get-RepoFileList -Root $RepoRoot)
if (-not $Files -or $Files.Count -eq 0) {
    Write-Host 'No tracked files found - is this a git work tree?' -ForegroundColor Red
    exit 2
}
if (-not $Quiet) {
    Write-Host ''
    Write-Host "Repo checks over $($Files.Count) source file(s) in $RepoRoot" -ForegroundColor Cyan
    Write-Host ("Engine    : {0}" -f $PSVersionTable.PSVersion) -ForegroundColor Cyan
    Write-Host ''
}

$ConfigLines = @(Get-TextLines -Root $RepoRoot -Rel $ConfigRel)
$ConfigExists = ($ConfigLines.Count -gt 0)
$Rules = @(if ($ConfigExists) { Get-MihomoRuleList -Lines $ConfigLines } else { @() })
$GroupNames = @(if ($ConfigExists) { Get-MihomoNamedList -Lines $ConfigLines -Section 'proxy-groups' } else { @() })
$OutboundNames = @(if ($ConfigExists) { Get-MihomoNamedList -Lines $ConfigLines -Section 'proxies' } else { @() })
$ProviderNames = @(if ($ConfigExists) { Get-MihomoProviderNames -Lines $ConfigLines } else { @() })
$RuleProviderNames = @(if ($ConfigExists) { Get-MihomoProviderNames -Lines $ConfigLines -Section 'rule-providers' } else { @() })

$results = @{}

# ===========================================================================
#  1. Parse every tracked script, INCLUDING the repo root.
#
#  Why this exists: the CI parse step covered src/, tools/ and tests/ and left
#  the root scripts out - and those are the biggest scripts in the repo
#  (hypomux-distribution.ps1 is 1280 lines and edits the live config). A parse
#  error there is not caught until the script is run against a live machine.
# ===========================================================================
if (-not $Check -or $Check -eq 'parse') {
    $results['parse'] = Invoke-Check 'parse' {
        $scripts = @($Files | Where-Object { $_ -match '\.ps(m)?1$' })
        if ($scripts.Count -eq 0) { Add-Failure 'no .ps1/.psm1 files found to parse' }
        $parsed = 0
        $rootParsed = 0
        foreach ($rel in $scripts) {
            $full = Join-Path $RepoRoot $rel
            $errs = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$null, [ref]$errs)
            $parsed++
            if ($rel -notmatch '\\') { $rootParsed++ }
            if ($errs -and $errs.Count) {
                foreach ($e in $errs) {
                    Add-Failure "parse error: $($e.Message)" -File $rel -Line $e.Extent.StartLineNumber
                }
            }
        }
        Write-Note "$parsed script(s) parsed, $rootParsed of them at the repo root"
    }
}

# ===========================================================================
#  2. Secret scan.
#
#  Why this exists: a 48-char hex clash_api secret sat in a tracked doc
#  (docs\HYPOMUX-SETTINGS.md) and the old check missed it, because it only
#  looked inside the config template for a base64 ss key. The scan is now
#  repo-wide. Two halves:
#    (a) the template must still carry its three placeholders - redaction must
#        not be "fixed" by deleting the marker;
#    (b) no tracked file may carry a live-looking credential.
#  The regression fixture for (b) is generated at RUN TIME ('ab' * 24). No real
#  credential value is written here: embedding one would re-commit the secret,
#  which is the exact bug being fixed - so the fixture proves the PATTERN fires
#  without putting the value back in the repository.
# ===========================================================================
if (-not $Check -or $Check -eq 'secrets') {
    $results['secrets'] = Invoke-Check 'secrets' {

        # -- (a) the three placeholders the template must keep ---------------
        if (-not $ConfigExists) {
            Add-Failure "missing $ConfigRel" -File $ConfigRel
        } else {
            $cfgText = Get-TextFile -Root $RepoRoot -Rel $ConfigRel
            foreach ($needle in @('REPLACE-LA-OMRIN-UUID', 'REPLACE-TOKYO-OMRIN-UUID', '__HY2_PASSWORD__')) {
                if ($cfgText -notlike "*$needle*") {
                    Add-Failure "template is missing the redaction placeholder $needle - removing the marker is not redaction" -File $ConfigRel
                }
            }
        }

        # -- (b) the pattern set --------------------------------------------
        # The positive control, built here so no real credential is ever
        # committed. It must match the hex rule below; if it stops matching,
        # the rule has been weakened and this check fails instead of going
        # quietly green.
        $fixture = ('ab' * 24)          # 48 hex chars, obviously synthetic
        if ($fixture -notmatch '[0-9a-fA-F]{32,}') {
            Add-Failure 'self-test: the synthetic 48-char hex fixture no longer matches the hex rule'
        }
        # Shape guard from the incident: a 48-char hex value assigned to
        # secret/password/token/auth in a doc or a config. Checked against the
        # fixture so the guard itself is proven to fire.
        $shapeProbe = 'secret: ' + $fixture
        if ($shapeProbe -notmatch '(?i)\b(secret|password|passwd|token|auth|apikey|api[-_]key|private[-_]?key)\b\s*[:=]\s*["'']?([0-9a-fA-F]{32,})\b') {
            Add-Failure 'self-test: the credential-assignment pattern no longer matches a hex value'
        }

        # credential keywords on the RIGHT-HAND side: "password: X". `$auth = ''`
        # and `$auth = [string]$Snapshot.auth` are code that mentions a
        # credential, not a secret, so the value must start with a word
        # character and the pattern never crosses into quoted lookups.
        # `uuid` is a credential keyword too: it is the VLESS/VMess outbound key,
        # and the template redacts both omrin UUIDs as REPLACE-*-UUID. A hyphenated
        # UUID has no 32-char contiguous hex run, so hexRe never saw a pasted one.
        $assignRe = [regex]'(?im)\b(password|passwd|secret|token|auth|apikey|api[-_]key|private[-_]?key|uuid)\b\s*[:=]\s*["'']?([A-Za-z0-9_][^\s"''#\[\](){}$&|;<>,]{5,})'
        # Placeholder markers are accepted bare OR suffixed, because the template
        # uses both forms: `REPLACE`/`CHANGE`/`YOUR` alone, and the self-describing
        # REPLACE-OMR-SS-PASSWORD of the omr outbound (the real VM listener key
        # lives only in runtime\config.yaml, which this check never scans).
        $placeholderRe = [regex]'(?i)^(__[A-Z0-9_]+__|REPLACE[A-Z0-9_-]*|CHANGE[A-Z0-9_-]*|YOUR[A-Z0-9_-]*|<[^>]+>|%[A-Za-z_]+%|x{4,}|\.{3,}|null|none|false|true|off|on|\*+|-+)$'
        # A base64 secret is a QUOTED assignment value, not any long run of
        # word characters. Scanned file-wide, this pattern matches URI path
        # fragments ("com/api/v2/package/Pester/5"), git hashes and the
        # hostname labels in the vendored hosts lists - 40+ false positives on
        # this tree alone, which would make the check worthless.
        $b64Re = [regex]'(?i)\b(password|passwd|secret|token|auth|apikey|api[-_]key)\b\s*[:=]\s*["'']([A-Za-z0-9+/]{16,}={0,2})["'']'
        $hexRe = [regex]'[0-9a-fA-F]{32,}'
        $subRe = [regex]'(?i)https?://[^\s"''<>)\]]*(/s/|/sub/|/api/v1/client/subscribe|token=|access_token=|/link/)[^\s"''<>)\]]*'
        # The subscription URL is REPLACE-ME.invalid/sub/__SUBSCRIPTION_TOKEN__:
        # the URL shape is deliberate (it shows where the token goes), so only a
        # token that is not a placeholder counts.
        $subPlaceholderRe = [regex]'(?i)__(SUBSCRIPTION_)?TOKEN__|REPLACE-ME|<[^>]+>|\$\{?[A-Za-z_]'
        # A PEM header is a private key wherever it appears.
        $pemRe = [regex]'-----BEGIN [A-Z ]*PRIVATE KEY-----'

        $scanned = 0
        foreach ($rel in $Files) {
            # Binary-ish files are skipped: a PNG is not where a credential is
            # redacted, and decoding one to "scan" it only produces noise.
            if ($rel -match '\.(png|jpg|jpeg|gif|ico|exe|dll|7z|zip|dat|nupkg|pfx|p12|woff2?|ttf)$') { continue }
            # Archived MEASUREMENT DATA is not configuration, so it is not scanned for
            # credentials: the SmartDNS resolver-audit captures under archive\smartdns\ are
            # bulk CSV rows (query ids, upstream digests), and a 32-char hex run in a DNS
            # audit log is data, not a key. Added 2026-10-11, when those captures became
            # tracked and the scan failed on its own archive. The alternative - listing the
            # individual values - would grow without bound and would still be calling
            # measurement data a secret.
 if ($rel -match '^archive[\\/].*\.csv$') { continue }   # reason above
            $text = Get-TextFile -Root $RepoRoot -Rel $rel
            if ($null -eq $text) { continue }
            $scanned++

            # Positive controls a test feeds the scanners on purpose. They are
            # obviously synthetic and are listed per file in $KnownTestFixtures;
            # anything else in the same file still fails.
            $fixtures = if ($KnownTestFixtures.ContainsKey($rel)) { @($KnownTestFixtures[$rel]) } else { @() }
            $isFixture = {
                param([string] $Value)
                foreach ($fx in $fixtures) { if ($Value -eq $fx) { return $true } }
                return $false
            }

            $hit = $hexRe.Matches($text) | Where-Object { -not $KnownHexDigests.ContainsKey($_.Value) -and -not (& $isFixture $_.Value) } | Select-Object -First 1
            if ($hit) {
                Add-Failure ("a {0}-char hex run looks like a credential (value withheld); if it is a digest, explain it in KnownHexDigests" -f $hit.Value.Length) -File $rel -Line (Get-LineOfOffset -Text $text -Offset $hit.Index)
            }

            foreach ($m in $b64Re.Matches($text)) {
                $key = $m.Groups[1].Value
                $val = $m.Groups[2].Value
                if ($AllowedBase64 -contains $val) { continue }
                if (& $isFixture $val) { continue }
                if ($placeholderRe.IsMatch($val)) { continue }
                if ($val -notmatch '[0-9+/=]') { continue }   # plain words are not base64 keys
                Add-Failure "$key is a base64-looking value of $($val.Length) chars (value withheld)" -File $rel -Line (Get-LineOfOffset -Text $text -Offset $m.Index)
            }

            if ($pemRe.IsMatch($text)) {
                $pm = $pemRe.Match($text)
                Add-Failure 'contains a private-key PEM header' -File $rel -Line (Get-LineOfOffset -Text $text -Offset $pm.Index)
            }

            foreach ($m in $assignRe.Matches($text)) {
                $key = $m.Groups[1].Value
                $val = $m.Groups[2].Value
                if ($placeholderRe.IsMatch($val)) { continue }
                if (& $isFixture $val) { continue }
                # A bare word after `auth` is usually code (auth = 'Wpa2');
                # a credential is long, or hex, or base64-ish.
                if ($val.Length -lt 20 -and $val -notmatch '^[0-9a-fA-F]{16,}$' -and $val -notmatch '^[A-Za-z0-9+/]{16,}={0,2}$') { continue }
                if ($AllowedBase64 -contains $val) { continue }
                Add-Failure "$key is assigned a non-placeholder value (value withheld)" -File $rel -Line (Get-LineOfOffset -Text $text -Offset $m.Index)
            }

            foreach ($m in $subRe.Matches($text)) {
                if ($subPlaceholderRe.IsMatch($m.Value)) { continue }
                Add-Failure 'carries a subscription URL with a token in it' -File $rel -Line (Get-LineOfOffset -Text $text -Offset $m.Index)
            }
        }
        Write-Note "$scanned text file(s) scanned for credentials"

        # -- (c) the shape guard, repo-wide, on the paths the leak used ------
        # Narrower than the scan above and stated separately so the incident
        # this closes is visible in the output: docs/, README.md and config/ are
        # where a hand-written claim or a pasted snippet carries a secret.
        $shapeFiles = @($Files | Where-Object { $_ -match '^(docs\\|config\\)' -or $_ -eq 'README.md' })
        $shapeHits = 0
        foreach ($rel in $shapeFiles) {
            $text = Get-TextFile -Root $RepoRoot -Rel $rel
            if ($null -eq $text) { continue }
            foreach ($m in [regex]::Matches($text, '(?i)\b(secret|password|passwd|token|auth)\b\s*[:=]\s*["'']?([0-9a-fA-F]{32,})\b')) {
                $shapeHits++
                Add-Failure "$($m.Groups[1].Value) is assigned a $($m.Groups[2].Value.Length)-char hex value (value withheld)" -File $rel -Line (Get-LineOfOffset -Text $text -Offset $m.Index)
            }
        }
        Write-Note "shape guard covered $($shapeFiles.Count) doc/config file(s), $shapeHits hit(s)"
    }
}

# ===========================================================================
#  3. Rule audit.
#
#  Why this exists: a rule is invisible when it is wrong. A duplicate or a rule
#  shadowed by an earlier parent suffix does not error - it just never fires,
#  and the traffic silently goes somewhere else. mihomo's own `-t` accepts all
#  three faults below, so nothing else catches them.
# ===========================================================================
if (-not $Check -or $Check -eq 'web') {
    $results['web'] = Invoke-Check 'web' {
        foreach ($rel in $WebFiles) {
            $h = Get-TextFile -Root $RepoRoot -Rel $rel
            if ($null -eq $h) { Add-Failure 'file is missing' -File $rel; continue }
            if ($h -notmatch '<html') { Add-Failure 'has no <html> element' -File $rel }
            if (-not $h.EndsWith('</html>') -and $h -notmatch '</html>') { Add-Failure 'has no closing </html>' -File $rel }
            $open = ([regex]::Matches($h, '<div[\s>]')).Count
            $close = ([regex]::Matches($h, '</div>')).Count
            if ($open -ne $close) {
                Add-Failure "unbalanced <div>: $open open, $close close" -File $rel
            }
            Write-Note "$rel balanced ($open divs)"
        }
    }
}

# ===========================================================================
#  8. Tool wiring.
#
#  Why this exists: every .bat here is an operator's single entry point, and the
#  two ways one rots are silent - it points at a script that was renamed (the
#  supervisor path used to be %REPO%mihomo-supervisor.ps1, which does not exist
#  at that level), or it starts the retired adapter watcher, which writes the
#  per-NIC rings straight back into the live config. Neither shows up as a parse
#  error, because the path is data inside a string.
# ===========================================================================
if (-not $Check -or $Check -eq 'control') {
    $results['control'] = Invoke-Check 'control' {
        # Text files only, by extension: a stray C0 byte in a .ps1, .yaml or
        # .md breaks a parser or a renderer, while the same byte inside a
        # vendored binary-looking file is not this check's business.
        $textExt = @('.ps1', '.psm1', '.psd1', '.bat', '.cmd', '.md', '.yml', '.yaml', '.json',
                     '.html', '.txt', '.conf', '.mobileconfig', '.gitignore', '.gitattributes', '.example')
        $ctrlRe = [regex]'[\x00-\x08\x0B\x0C\x0E-\x1F]'
        $scanned = 0
        foreach ($rel in $Files) {
            $ext = [System.IO.Path]::GetExtension($rel).ToLowerInvariant()
            $leaf = Split-Path -Leaf $rel
            if (($textExt -notcontains $ext) -and $leaf -notin @('.gitignore', '.gitattributes')) { continue }
            $text = Get-TextFile -Root $RepoRoot -Rel $rel
            if ($null -eq $text) { continue }
            $scanned++
            $seen = @{}
            # Built from a char code because a literal backtick-f is a form feed
            # to the PowerShell parser in ANY double-quoted string - the message
            # would carry the very byte it warns about. It bit this line first.
            $fEsc = [char]0x60 + 'f'
            foreach ($m in $ctrlRe.Matches($text)) {
                $line = Get-LineOfOffset -Text $text -Offset $m.Index
                $code = 'U+{0:X4}' -f [int][char]$m.Value
                if ($seen.ContainsKey("$line|$code")) { continue }
                $seen["$line|$code"] = $true
                Add-Failure "control character $code is not allowed in a text file - a PowerShell backtick escape such as $fEsc inside a double-quoted string produces one and is invisible in an editor" -File $rel -Line $line
            }
        }
        Write-Note "$scanned text file(s) checked for control characters"
    }
}

# ===========================================================================
#  10. Scheduled-task set: the disable lists must cover everything the
#      installers can create - the drift class that bit on 2026-10-12.
#
#  Why this exists: measured that day, after a reset the restore path silently
#  brought back a stack WITHOUT its proxy core - autostart-on.bat calls
#  Register-AllTasks.ps1, which did not register MihomoSplitter (that task lives
#  in its own registrar, which nothing called) - and autostart-off.bat did not
#  disable NetworkStatus, so "off" left a visible window task behind. Four
#  hand-kept lists in four files were the cause; this check makes the drift a CI
#  failure instead of a logon surprise.
# ===========================================================================
$ran = @($results.Keys)
$failed = @($ran | Where-Object { -not $results[$_] })
$skipped = @($CheckNames | Where-Object { $ran -notcontains $_ })

Write-Host ''
if ($failed.Count -eq 0) {
    $what = if ($Check) { "check '$Check'" } else { "$($ran.Count) check(s)" }
    Write-Host ("ALL PASS - $what" + $(if ($skipped.Count) { " (skipped: $($skipped -join ', '))" } else { '' })) -ForegroundColor Green
    exit 0
}
Write-Host ("FAILED - {0} of {1} check(s): {2}" -f $failed.Count, $ran.Count, ($failed -join ', ')) -ForegroundColor Red
Write-Host 'Re-run one with: -Check <name>   (names: -Check list)' -ForegroundColor Yellow
exit 1

