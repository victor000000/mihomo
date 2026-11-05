# =============================================================================
#  mihomo-pac-server.ps1 - serve a LIVE-GENERATED proxy.pac to LAN clients.
#
#  The PAC is rebuilt from the current mihomo rules on every request (with the
#  fixed domestic/WeChat base list merged in), so whenever mihomo's DIRECT /
#  LOCAL rules change, the iPhone's PAC follows automatically. The generated
#  file is also written to tools\proxy.pac for inspection and versioning.
#
#  Routing model:
#    - private/loopback hosts                  -> DIRECT
#    - mihomo rules ... DIRECT|LOCAL domains  -> DIRECT
#    - the base domestic list (WeChat, Apple,
#      major CN services)                      -> DIRECT
#    - everything else                         -> PROXY 192.168.137.1:7897
#  (the PROXY line carries "; DIRECT" so the phone falls back to direct if the
#  PC proxy is unreachable).
#
#  Raw TcpListener on purpose: HttpListener needs a URL ACL (admin) for
#  non-loopback binds; this needs no elevation. Single instance via port guard.
#  Started hidden at logon by Mihomo-PacServer.vbs (Startup folder).
# =============================================================================
$ErrorActionPreference = 'Continue'
$root=Split-Path $PSScriptRoot -Parent
Import-Module "$root\src\NetStack\RebootTrace.psm1" -Force
$trace=New-RebootTrace $root 'pac-server'


$pacPath  = Join-Path $PSScriptRoot '..\state\proxy.pac'
$logPath  = Join-Path $PSScriptRoot '..\state\pac-server.log'
$mihomoCfg = 'C:\Users\victo\mihomo\runtime\config.yaml'
$port     = 8080

$baseDirect = @(
    'qq.com', 'tencent.com', 'weixin.com', 'wechat.com', 'weixinbridge.com',
    'servicewechat.com', 'wechatpay.com', 'tenpay.com', 'qpic.cn', 'qlogo.cn',
    'gtimg.cn', 'gtimg.com', 'myqcloud.com', 'qcloud.com',
    'apple.com', 'icloud.com', 'me.com', 'cdn-apple.com',
    'baidu.com', 'bdstatic.com', 'taobao.com', 'tmall.com', 'alicdn.com',
    'alipay.com', 'alipayobjects.com', 'jd.com', '360buyimg.com',
    'pinduoduo.com', 'yangkeduo.com', 'bilibili.com', 'hdslb.com',
    'douyin.com', 'bytedance.com', 'snssdk.com', 'weibo.com', 'sinaimg.cn',
    '163.com', '126.net', 'zhihu.com', 'zhimg.com', 'csdn.net', 'aliyun.com',
    'aliyuncs.com', 'amap.com', 'autonavi.com', 'meituan.com', 'dianping.com',
    'bing.com', 'msn.com'
)

function Log([string]$m) {
    try { Add-Content -LiteralPath $logPath -Encoding UTF8 -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) } catch { }
}

function Get-DirectDomains {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    if (Test-Path -LiteralPath $mihomoCfg) {
        foreach ($line in [System.IO.File]::ReadAllLines($mihomoCfg, [System.Text.Encoding]::UTF8)) {
            $m = [regex]::Match($line, '^\s*-\s*DOMAIN(?:-SUFFIX|-KEYWORD)?,\s*([^,\s#]+)\s*,\s*(DIRECT|LOCAL)\b')
            if ($m.Success) {
                $d = $m.Groups[1].Value.Trim().ToLowerInvariant()
                if ($d -match '^[a-z0-9.*_-]+$' -and $d -notmatch '^\*') { [void]$set.Add($d) }
            }
        }
    }
    foreach ($d in $baseDirect) { [void]$set.Add($d) }
    return @($set | Sort-Object)
}

function Build-Pac {
    $domains = Get-DirectDomains
    $list = ($domains | ForEach-Object { '"' + $_ + '"' }) -join ', '
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $pac = @"
// proxy.pac - generated from mihomo rules + domestic base list at $stamp
// direct domains: $($domains.Count)
function FindProxyForURL(url, host) {
  host = host.toLowerCase();
  if (isPlainHostName(host) || host === "localhost" ||
      shExpMatch(host, "127.*") || shExpMatch(host, "10.*") ||
      shExpMatch(host, "192.168.*") || shExpMatch(host, "172.1[6-9].*") ||
      shExpMatch(host, "172.2[0-9].*") || shExpMatch(host, "172.3[0-1].*") ||
      shExpMatch(host, "169.254.*")) return "DIRECT";
  var direct = [$list];
  for (var i = 0; i < direct.length; i++) {
    var d = direct[i];
    if (host === d || dnsDomainIs(host, "." + d)) return "DIRECT";
  }
  return "PROXY 192.168.137.1:7897; DIRECT";
}
"@
    # Persist only when the effective rules change: the stamp line is excluded
    # from the comparison so repeated fetches don't churn the tracked file.
    $stampLine = '^// proxy\.pac - generated[^\r\n]*\r?\n'
    $oldBody = ''
    try {
        if (Test-Path -LiteralPath $pacPath) {
            $oldBody = [regex]::Replace([System.IO.File]::ReadAllText($pacPath), $stampLine, '')
        }
    } catch { }
    $newBody = [regex]::Replace($pac, $stampLine, '')
    if ($oldBody -ne $newBody) {
        try { [System.IO.File]::WriteAllText($pacPath, $pac, (New-Object System.Text.UTF8Encoding($false))) } catch { }
    }
    return $pac
}

if (-not (Test-Path -LiteralPath $mihomoCfg)) { Log "warning: mihomo config not found at $mihomoCfg (base list only)" }

$inUse = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
if ($inUse) { Write-RebootTrace $trace 'listener-already-present' @{Port=$port;Owners=@($inUse.OwningProcess)};Log 'port 8080 already in use - exiting (single instance)'; exit 0 }

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $port)
try { $listener.Start();Write-RebootTrace $trace 'listener-ready' @{Port=$port} } catch { Write-RebootTrace $trace 'listener-error' @{Message=$_.Exception.Message};Log ('bind failed: ' + $_.Exception.Message); exit 1 }
Log ('pac server listening on port ' + $port + ' (live generation from ' + $mihomoCfg + ')')

while ($true) {
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 5000
        $remote = $client.Client.RemoteEndPoint.ToString()
        $stream = $client.GetStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $reqLine = $reader.ReadLine()
        while ($true) { $line = $reader.ReadLine(); if (-not $line) { break } }

        $body = Build-Pac
        Log ('served pac to ' + $remote + ' [' + $reqLine + ']')
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $header = "HTTP/1.1 200 OK`r`nContent-Type: application/x-ns-proxy-autoconfig`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
        $hb = [System.Text.Encoding]::ASCII.GetBytes($header)
        $stream.Write($hb, 0, $hb.Length)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } catch { } finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}
