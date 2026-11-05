# Network Stack Dashboard - local read-only file server.
# Collector.ps1 is the ONLY status.json writer (scheduled separately).
# Existing URLs and the scheduled no-argument invocation remain unchanged.
[CmdletBinding()]
param(
    [string] $Root = '',
    [string] $Prefix = 'http://127.0.0.1:8899/'
)
if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

function Test-DashboardPrefix {
    param([string] $Value)
    $uri = $null
    if (-not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) { return $false }
    # Never permit wildcard/non-loopback listeners, credentials, or a path prefix
    # that would silently change the scheduled dashboard's route contract.
    $loopback = $uri.Host -in @('127.0.0.1', 'localhost')
    $address = $null
    if ([Net.IPAddress]::TryParse($uri.Host.Trim('[', ']'), [ref]$address)) {
        # .NET Framework expands ::1 to eight hextets; modern .NET compresses it.
        $loopback = $address.Equals([Net.IPAddress]::Loopback) -or $address.Equals([Net.IPAddress]::IPv6Loopback)
    }
    return ($uri.Scheme -eq 'http' -and $loopback -and
        -not $uri.UserInfo -and $uri.AbsolutePath -eq '/' -and -not $uri.Query -and -not $uri.Fragment -and
        $Value.EndsWith('/'))
}

function Get-DashboardResponse {
    <# File-only response builder, also used by offline tests without HttpListener.
       The status file is bounded WHILE reading, not only stat'ed before reading:
       replacement/growth between stat and ReadAllText used to bypass the guard. #>
    [CmdletBinding()]
    param([string] $Root, [string] $Path, [int] $MaxStatusBytes = 262144)

    $contentType = 'text/html; charset=utf-8'
    $status = 200
    $body = ''
    $relative = switch ($Path) {
        '/' { 'web\index.html' }
        '/index.html' { 'web\index.html' }
        '/design' { 'web\design.html' }
        '/balance' { 'web\balance.html' }
        '/balance.html' { 'web\balance.html' }
        '/api/status' { 'state\status.json' }
        default { $null }
    }
    if (-not $relative) {
        return @{ StatusCode = 404; ContentType = $contentType; Body = '' }
    }
    $file = Join-Path $Root $relative
    if ($Path -eq '/api/status') {
        $contentType = 'application/json; charset=utf-8'
        $status = 503
        $body = '{"error":"status.json not built yet"}'
        $stream = $null
        try {
            $stream = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $bytes = New-Object byte[] ($MaxStatusBytes + 1)
            $length = 0
            while ($length -lt $bytes.Length) {
                $read = $stream.Read($bytes, $length, $bytes.Length - $length)
                if ($read -eq 0) { break }
                $length += $read
            }
            if ($length -gt $MaxStatusBytes) {
                $body = '{"error":"status.json exceeds 256 KB - the collector is misbehaving; it will be replaced on the next refresh"}'
            } elseif ($length -gt 0) {
                try {
                    # Reject invalid UTF-8 and malformed/scalar JSON instead of
                    # returning a successful HTTP response that breaks the UI.
                    $utf8 = New-Object Text.UTF8Encoding($false, $true)
                    $candidate = $utf8.GetString($bytes, 0, $length).TrimStart([char]0xFEFF)
                    $snapshot = ConvertFrom-Json -InputObject $candidate -ErrorAction Stop
                    if ($snapshot -isnot [pscustomobject] -or -not $candidate.TrimStart().StartsWith('{')) {
                        throw 'Status snapshot must be a JSON object.'
                    }
                    $body = $candidate
                    $status = 200
                } catch { $body = '{"error":"status.json is corrupt or is not a JSON object"}' }
            } else { $body = '{"error":"status.json is empty"}' }
        } catch { } finally { if ($null -ne $stream) { $stream.Dispose() } }
    } else {
        try { $body = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) }
        catch { $status = 404; $body = '<h1>' + [IO.Path]::GetFileName($file) + ' not found</h1>' }
    }
    return @{ StatusCode = $status; ContentType = $contentType; Body = $body }
}

function Send-DashboardResponse {
    param($Context, $Response)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Response.Body)
        $Context.Response.StatusCode = $Response.StatusCode
        $Context.Response.ContentType = $Response.ContentType
        $Context.Response.ContentLength64 = $bytes.Length
        $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } finally { $Context.Response.Close() }
}

# Dot-sourcing exposes the actual response helpers, never starts a listener.
if ($MyInvocation.InvocationName -eq '.') { return }
if (-not (Test-DashboardPrefix $Prefix)) { throw 'Dashboard Prefix must be an HTTP loopback origin ending in /.' }
$LogFile = Join-Path $Root 'state\dashboard.log'
function Write-Log([string] $Message) {
    try { Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) }
    catch { }
}

$listener = New-Object System.Net.HttpListener
try {
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    Write-Log "dashboard listening on $Prefix (file-only; Collector.ps1 supplies status)"
    while ($listener.IsListening) {
        $ctx = $null
        try { $ctx = $listener.GetContext() } catch { break }
        if ($null -eq $ctx) { continue }
        try {
            $response = Get-DashboardResponse -Root $Root -Path $ctx.Request.Url.AbsolutePath
            Send-DashboardResponse -Context $ctx -Response $response
        } catch {
            Write-Log "request error: $($_.Exception.Message)"
            try { $ctx.Response.StatusCode = 500; $ctx.Response.Close() } catch { }
        }
    }
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
    Write-Log 'dashboard stopped'
}
