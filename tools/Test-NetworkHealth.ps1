# Read-only Mihomo health, proxy reachability and native adapter diagnostics.
[CmdletBinding()]
param(
    [int] $TimeoutSec = 15,
    [int] $WarnWindowMin = 15,
    [switch] $Quick,
    [switch] $Json,
    [switch] $FunctionsOnly
)

$ErrorActionPreference = 'SilentlyContinue'
# WSL-launched Windows shells may inherit a non-Windows PATHEXT.
if(($env:PATHEXT -split ';') -notcontains '.EXE'){$env:PATHEXT='.COM;.EXE;.BAT;.CMD'}

$Root      = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $Root 'src\NetStack\Architecture.psm1') -Force -ErrorAction Stop
$MihomoLog = Join-Path $Root 'runtime\mihomo.log'
$MihomoApi = 'http://127.0.0.1:9097'
$ProxyUrl  = 'http://127.0.0.1:7897'

$script:Results = New-Object System.Collections.ArrayList

function Add-Result {
    param(
        [string] $Group,
        [string] $Name,
        [string] $Status,   # ok | warn | fail | skip
        [string] $Detail,
        [int]    $Ms = -1
    )
    [void]$script:Results.Add([pscustomobject]@{
        Group  = $Group
        Name   = $Name
        Status = $Status
        Detail = $Detail
        Ms     = $Ms
    })
}

function Get-CurlExe {
    $native=Join-Path $env:WINDIR 'System32\curl.exe'
    if(Test-Path $native){return $native}
    $c = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Invoke-Probe {
    <# Returns @{ Code = '204'; Sec = 1.23 } or $null when curl is missing. #>
    param(
        [string] $Url,
        [bool]   $ViaProxy,
        [int]    $Timeout = $TimeoutSec
    )
    $curl = Get-CurlExe
    if (-not $curl) { return $null }

    $curlArgs = @('-sS', '-o', 'NUL', '--ssl-no-revoke', '-m', "$Timeout", '-w', '%{http_code}|%{time_total}')
    if ($ViaProxy) {
        $curlArgs += @('-x', $ProxyUrl)
    } else {
        $curlArgs += @('--noproxy', '*')
    }
    $curlArgs += $Url

    $raw = & $curl @curlArgs 2>$null
    if (-not $raw) { return @{ Code = '000'; Sec = -1 } }
    $parts = ("$raw").Trim() -split '\|'
    $sec = -1
    if ($parts.Count -ge 2 -and $parts[1] -match '^[0-9.]+$') { $sec = [double]$parts[1] }
    return @{ Code = $parts[0]; Sec = $sec }
}

function Get-ListeningPorts {
    <# One netstat pass instead of one Get-NetTCPConnection call per port.
       That cmdlet costs ~3.8 s per call on this box (documented repo trap);
       netstat is ~50 ms for the whole table. #>
    $ports = @{}
    $lines = & "$env:WINDIR\System32\netstat.exe" -ano -p TCP 2>$null
    foreach ($line in $lines) {
        if ($line -match '^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+\d+\s*$') {
            $ports[[int]$Matches[1]] = $true
        }
    }
    return $ports
}

$script:ListenPorts = if($FunctionsOnly){@{}}else{Get-ListeningPorts}

function Test-PortListening {
    param([int] $Port)
    return $script:ListenPorts.ContainsKey($Port)
}

function Get-CountInWindow {
    <# Counts lines matching $Pattern in the last $Minutes of a log. #>
    param(
        [string] $Path,
        [int]    $Minutes,
        [string] $Pattern,
        [Nullable[datetime]] $SinceUtc = $null
    )
    if (-not (Test-Path -LiteralPath $Path)) { return -1 }
    $cut = (Get-Date).AddMinutes(-1 * $Minutes)
    if($null -ne $SinceUtc -and $SinceUtc.ToLocalTime() -gt $cut){$cut=$SinceUtc.ToLocalTime()}
    $count = 0
    $lines = Get-Content -LiteralPath $Path -Tail 4000 -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        # One alternation, one match: two separate -match calls in an -or would
        # leave $Matches from whichever branch ran last (the documented trap).
        if ($line -match '^(?:time="([^"]+)"|(\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d))') {
            if ($Matches[1]) { $stamp = $Matches[1] } else { $stamp = $Matches[2] }
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse($stamp, [ref]$parsed)) {
                if ($parsed -lt $cut) { continue }
                if ($line -match $Pattern) { $count++ }
            }
        }
    }
    return $count
}

function Get-VerifiedRecoveryTime {
    param([string]$MarkerPath,[string]$ConfigPath,[datetime]$NowUtc=[datetime]::UtcNow)
    try {
        $m=Get-Content -LiteralPath $MarkerPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
        if(-not $m.EgressPassed -or -not $m.CodexConnected -or -not $m.HotspotSharing){return $null}
        if($m.ConfigSha256 -ne (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256 -ErrorAction Stop).Hash){return $null}
        # PowerShell 7.5+ may deserialize ISO JSON timestamps as DateTime.
        # Parsing its culture-formatted string would discard the UTC Kind.
        $when=if($m.VerifiedAtUtc -is [datetime]){$m.VerifiedAtUtc.ToUniversalTime()}else{([datetimeoffset]::Parse([string]$m.VerifiedAtUtc)).UtcDateTime}
        if($when -gt $NowUtc.ToUniversalTime()){return $null}
        return $when
    }catch{return $null}
}
if($FunctionsOnly){return}

# ---------------------------------------------------------------------------
# core
# ---------------------------------------------------------------------------
$proc = Get-Process mihomo -ErrorAction SilentlyContinue | Select-Object -First 1
if ($proc) {
    Add-Result 'core' 'mihomo process' 'ok' ("pid {0}, {1} MB" -f $proc.Id, [int]($proc.WorkingSet64 / 1MB))
} else {
    Add-Result 'core' 'mihomo process' 'fail' 'not running'
}

$ver = $null
try {
    $ver = Invoke-RestMethod -Uri "$MihomoApi/version" -TimeoutSec 5
} catch { }
if ($ver) {
    Add-Result 'core' 'controller API' 'ok' ("{0} on 9097" -f $ver.version)
} else {
    Add-Result 'core' 'controller API' 'fail' '9097 not answering'
}

if (Test-PortListening 7897) {
    Add-Result 'core' 'proxy port 7897' 'ok' 'listening'
} else {
    Add-Result 'core' 'proxy port 7897' 'fail' 'not listening'
}

$inet = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
$sysProxyOk = ($inet.ProxyEnable -eq 1 -and "$($inet.ProxyServer)" -match '7897')
if ($sysProxyOk) {
    Add-Result 'core' 'system proxy' 'ok' ("{0}" -f $inet.ProxyServer)
} else {
    Add-Result 'core' 'system proxy' 'warn' ("ProxyEnable={0} Server={1}" -f $inet.ProxyEnable, $inet.ProxyServer)
}

# ---------------------------------------------------------------------------
# policy
# ---------------------------------------------------------------------------
$historyCount = Get-CountInWindow -Path $MihomoLog -Minutes $WarnWindowMin -Pattern 'level=warning|level=error'
$recoveredAt=Get-VerifiedRecoveryTime -MarkerPath "$Root\state\network-recovery\verified.json" -ConfigPath "$Root\runtime\config.yaml"
$warnCount = Get-CountInWindow -Path $MihomoLog -Minutes $WarnWindowMin -Pattern 'level=warning|level=error' -SinceUtc $recoveredAt
$warningDetail=if($recoveredAt -and $recoveredAt.ToLocalTime() -gt (Get-Date).AddMinutes(-$WarnWindowMin)){"$warnCount since verified recovery; $historyCount historical warnings retained in $WarnWindowMin min"}else{"$warnCount in $WarnWindowMin min"}
if ($warnCount -lt 0) {
    Add-Result 'policy' 'mihomo warnings' 'skip' 'log not found'
} elseif ($warnCount -le 2) {
    Add-Result 'policy' 'mihomo warnings' 'ok' $warningDetail
} elseif ($warnCount -le 20) {
    Add-Result 'policy' 'mihomo warnings' 'warn' $warningDetail
} else {
    Add-Result 'policy' 'mihomo warnings' 'fail' $warningDetail
}

try {
    $proxies = Invoke-RestMethod -Uri "$MihomoApi/proxies" -TimeoutSec 8
} catch {
    $proxies = $null
}
if ($proxies) {
    $groupNames = @('CHATGPT', 'ANTHROPIC', 'LINGODA', 'YOUTUBE', 'GOOGLE', 'DEV', 'IB', 'STORE')
    foreach ($gName in $groupNames) {
        $g = $proxies.proxies.$gName
        if (-not $g) {
            Add-Result 'policy' ("group {0}" -f $gName) 'warn' 'not defined'
            continue
        }
        if ($g.type -eq 'LoadBalance') {
            Add-Result 'policy' ("group {0}" -f $gName) 'ok' ("{0} members" -f @($g.all).Count)
        } elseif ([string]::IsNullOrEmpty("$($g.now)")) {
            Add-Result 'policy' ("group {0}" -f $gName) 'fail' 'no member selected'
        } else {
            Add-Result 'policy' ("group {0}" -f $gName) 'ok' ("now = {0}" -f $g.now)
        }
    }
} else {
    Add-Result 'policy' 'groups' 'fail' 'controller API returned nothing'
}

# ---------------------------------------------------------------------------
# egress
# ---------------------------------------------------------------------------
$egressChecks = @(
    @{ Name = 'gstatic via proxy'; Url = 'https://www.gstatic.com/generate_204';          ViaProxy = $true;  Expect = @('204') },
    @{ Name = 'chatgpt.com';       Url = 'https://chatgpt.com/';                          ViaProxy = $true;  Expect = @('200','301','302','403') },
    @{ Name = 'api.openai.com';    Url = 'https://api.openai.com/v1/models';              ViaProxy = $true;  Expect = @('200','401','403') },
    @{ Name = 'lingoda account';   Url = 'https://learn.lingoda.com/en/account';          ViaProxy = $true;  Expect = @('200','302') },
    @{ Name = 'baidu (direct)';    Url = 'https://www.baidu.com/';                         ViaProxy = $false; Expect = @('200','302') }
)
foreach ($chk in $egressChecks) {
    $r = Invoke-Probe -Url $chk.Url -ViaProxy $chk.ViaProxy
    if ($null -eq $r) {
        Add-Result 'egress' $chk.Name 'skip' 'curl.exe missing'
        continue
    }
    if ($r.Code -eq '000' -or $r.Sec -lt 0) {
        Add-Result 'egress' $chk.Name 'fail' 'no response (timeout or reset)'
        continue
    }
    if ($chk.Expect -notcontains $r.Code) {
        Add-Result 'egress' $chk.Name 'fail' ("HTTP {0}" -f $r.Code) ([int]($r.Sec * 1000))
        continue
    }
    $ms = [int]($r.Sec * 1000)
    if ($ms -gt 4000) {
        Add-Result 'egress' $chk.Name 'warn' ("HTTP {0} in {1} ms" -f $r.Code, $ms) $ms
    } else {
        Add-Result 'egress' $chk.Name 'ok' ("HTTP {0} in {1} ms" -f $r.Code, $ms) $ms
    }
}

# ---------------------------------------------------------------------------
# transport
# ---------------------------------------------------------------------------
foreach($name in 'DISPATCH','aliyun-tokyo','aliyun-la'){
 $url=if($name -eq 'DISPATCH'){'https://www.baidu.com/'}else{'https://www.google.com/generate_204'}
 try{
  $r=Invoke-RestMethod ($MihomoApi+'/proxies/'+$name+'/delay?timeout=5000&url='+[uri]::EscapeDataString($url)) -TimeoutSec 7 -ErrorAction Stop
  Add-Result 'transport' $name 'ok' 'HTTPS verified' ([int]$r.delay)
 }catch{Add-Result 'transport' $name 'warn' 'Path unavailable; another upstream may be healthy'}
}
foreach($entry in (Get-Content "$Root\config\mihomo-adapters.json" -Raw|ConvertFrom-Json)){
 $n=Get-NetAdapter|Where-Object { $_.MacAddress -eq $entry.mac -or $_.InterfaceGuid -eq $entry.interfaceGuid -or $_.Name -eq $entry.name } | Select-Object -First 1
 Add-Result 'adapters' $entry.name $(if($n.Status -eq 'Up'){'ok'}else{'warn'}) ('Link '+$n.Status+'; observed MAC='+$n.MacAddress+'; configured MAC='+$entry.mac+'; link state alone does not prove Internet access')
}
Add-Result 'extras' 'PAC 8080' $(if(Test-PortListening 8080){'ok'}else{'warn'}) 'LAN proxy configuration server'
if(-not $Quick){
 $ip=Get-NetIPAddress -AddressFamily IPv4|Where-Object IPAddress -eq '192.168.137.1'
 Add-Result 'extras' 'hotspot ICS address' $(if($ip){'ok'}else{'warn'}) 'Use src/hotspot/Hotspot.ps1 status for full WinRT state'
}

# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
$fails = @($script:Results | Where-Object { $_.Status -eq 'fail' })
$warns = @($script:Results | Where-Object { $_.Status -eq 'warn' })
$oks   = @($script:Results | Where-Object { $_.Status -eq 'ok' })
$skips = @($script:Results | Where-Object { $_.Status -eq 'skip' })

if ($fails.Count -gt 0) {
    $verdict = 'UNHEALTHY'
    $exitCode = 2
} elseif ($warns.Count -gt 0) {
    $verdict = 'DEGRADED'
    $exitCode = 1
} else {
    $verdict = 'HEALTHY'
    $exitCode = 0
}

    $payload = [pscustomobject]@{
        verdict = $verdict
        checked = (Get-Date).ToString('s')
        host    = $env:COMPUTERNAME
        summary = [pscustomobject]@{ ok = $oks.Count; warn = $warns.Count; fail = $fails.Count; skip = $skips.Count }
        checks  = $script:Results
    }
# Save each diagnostic run, including failures; retain the latest 60 reports.
# Log failures must not change the connectivity verdict or exit code.
try {
    $historyDir = Join-Path $Root 'state\network-health'
    New-Item -ItemType Directory -Path $historyDir -Force -ErrorAction Stop | Out-Null
    $reportPath = Join-Path $historyDir ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-$PID.json")
    $payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding UTF8 -ErrorAction Stop
    Get-ChildItem -LiteralPath $historyDir -Filter '*.json' | Sort-Object Name -Descending | Select-Object -Skip 60 | Remove-Item -Force -ErrorAction Stop
} catch { Write-Warning "Health report could not be saved: $($_.Exception.Message)" }
if ($Json) {
    $payload | ConvertTo-Json -Depth 5
} else {
    $line = '-' * 78
    Write-Host ''
    Write-Host ("network health  -  {0}  -  {1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Host $line
    $group = ''
    foreach ($r in $script:Results) {
        if ($r.Group -ne $group) {
            $group = $r.Group
            Write-Host ("[{0}]" -f $group)
        }
        $color = 'Gray'
        if ($r.Status -eq 'ok')   { $color = 'Green' }
        if ($r.Status -eq 'warn') { $color = 'Yellow' }
        if ($r.Status -eq 'fail') { $color = 'Red' }
        Write-Host ("  {0,-26} " -f $r.Name) -NoNewline
        Write-Host ("{0,-5}" -f $r.Status.ToUpper()) -NoNewline -ForegroundColor $color
        Write-Host (" {0}" -f $r.Detail)
    }
    Write-Host $line
    Write-Host ("VERDICT: {0}   ok={1} warn={2} fail={3} skip={4}" -f $verdict, $oks.Count, $warns.Count, $fails.Count, $skips.Count)
    Write-Host ''
}

exit $exitCode
