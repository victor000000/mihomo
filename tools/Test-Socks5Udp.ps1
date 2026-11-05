<#
.SYNOPSIS
    Probe a SOCKS5 server for TCP CONNECT and UDP ASSOCIATE, with optional user/password auth.

.DESCRIPTION
    Written 2026-10-12 to answer one question with evidence rather than assumption: can this
    SOCKS5 server carry UDP? `HypoMux`'s answers `rep=7` (command not supported); 3proxy on the
    Aliyun box is meant to answer 0. Both results came from this script.

    It performs the real protocol, not a port check:
      1. greeting (offers no-auth, then user/pass if a credential is given),
      2. TCP CONNECT to -TargetHost:-TargetPort,
      3. UDP ASSOCIATE, then a real DNS query through the relay and reads the answer back.

.PARAMETER ServerHost / ServerPort
    The SOCKS5 server. Defaults to 127.0.0.1:10800 (HypoMux's listener).

.PARAMETER User / Password
    Credentials, if the server requires them.

.PARAMETER TargetHost / TargetPort
    Where the TCP CONNECT and the UDP datagram are aimed. Default 8.8.8.8:53 - a DNS query makes
    the UDP path self-proving, because a reply can only come from a working relay.

.EXAMPLE
    .\Test-Socks5Udp.ps1                                   # HypoMux, expect rep=7
    .\Test-Socks5Udp.ps1 -ServerPort 1081 -User mihomo -Password '...'   # 3proxy over a tunnel
#>
param(
    [string] $ServerHost = '127.0.0.1',
    [int]    $ServerPort = 10800,
    [string] $User,
    [string] $Password,
    [string] $TargetHost = '8.8.8.8',
    [int]    $TargetPort = 53
)
$ErrorActionPreference = 'Stop'

function Read-Exact($stream, [int]$n) {
    $buf = New-Object byte[] $n; $got = 0
    while ($got -lt $n) {
        $r = $stream.Read($buf, $got, $n - $got)
        if ($r -le 0) { throw "connection closed while reading" }
        $got += $r
    }
    return $buf
}

$result = [ordered]@{ server = "${ServerHost}:${ServerPort}"; target = "${TargetHost}:${TargetPort}" }
$tcp = New-Object System.Net.Sockets.TcpClient
try {
    $tcp.Connect($ServerHost, $ServerPort)
    $s = $tcp.GetStream()

    # --- greeting: offer no-auth, and user/pass when we have one
    if ($User) { $s.Write([byte[]]@(5,2,0,2), 0, 4) } else { $s.Write([byte[]]@(5,1,0), 0, 3) }
    $s.Flush()
    $resp = Read-Exact $s 2
    $result.greeting = "ver=$($resp[0]) method=$($resp[1])"
    if ($resp[0] -ne 5) { throw "not a SOCKS5 server (ver=$($resp[0]))" }
    if ($resp[1] -eq 0xFF) { $result.tcpConnect = 'REFUSED (no acceptable auth method)'; return [pscustomobject]$result }

    if ($resp[1] -eq 2) {
        if (-not $User) { $result.tcpConnect = 'server wants user/password but none was supplied'; return [pscustomobject]$result }
        $u = [Text.Encoding]::ASCII.GetBytes($User); $p = [Text.Encoding]::ASCII.GetBytes($Password)
        $auth = [byte[]]@(1, $u.Length) + $u + [byte[]]@($p.Length) + $p
        $s.Write($auth, 0, $auth.Length); $s.Flush()
        $ar = Read-Exact $s 2
        $result.auth = "ver=$($ar[0]) status=$($ar[1])"
        if ($ar[1] -ne 0) { $result.tcpConnect = 'AUTH FAILED'; return [pscustomobject]$result }
    }

    # --- TCP CONNECT
    $th = [System.Net.IPAddress]::Parse($TargetHost).GetAddressBytes()
    $req = [byte[]]@(5,1,0,1) + $th + [byte[]]@([byte]($TargetPort -shr 8), [byte]($TargetPort -band 0xFF))
    $s.Write($req, 0, $req.Length); $s.Flush()
    $cr = Read-Exact $s 4
    $s.Read((New-Object byte[] 6), 0, 6) | Out-Null      # drain BND.ADDR/PORT (IPv4)
    $result.tcpConnect = "rep=$($cr[1]) $(if ($cr[1] -eq 0) { 'OK' } else { 'FAILED' })"

    # --- UDP ASSOCIATE on a fresh connection
    $tcp2 = New-Object System.Net.Sockets.TcpClient
    $tcp2.Connect($ServerHost, $ServerPort)
    $s2 = $tcp2.GetStream()
    if ($User) { $s2.Write([byte[]]@(5,2,0,2), 0, 4) } else { $s2.Write([byte[]]@(5,1,0), 0, 3) }
    $s2.Flush(); $null = Read-Exact $s2 2
    if ($User) {
        $u = [Text.Encoding]::ASCII.GetBytes($User); $p = [Text.Encoding]::ASCII.GetBytes($Password)
        $auth = [byte[]]@(1, $u.Length) + $u + [byte[]]@($p.Length) + $p
        $s2.Write($auth, 0, $auth.Length); $s2.Flush(); $null = Read-Exact $s2 2
    }
    $s2.Write([byte[]]@(5,3,0,1, 0,0,0,0, 0,0), 0, 10); $s2.Flush()
    $head = Read-Exact $s2 4
    $result.udpAssociate = "rep=$($head[1]) $(if ($head[1] -eq 0) { 'GRANTED' } elseif ($head[1] -eq 7) { '(command not supported)' } else { '' })"
    if ($head[1] -ne 0) { return [pscustomobject]$result }

    if ($head[3] -eq 1) { $relayIp = ((Read-Exact $s2 4) -join '.') } else { throw "unexpected ATYP $($head[3])" }
    $pb = Read-Exact $s2 2
    $relayPort = $pb[0] * 256 + $pb[1]
    $result.relay = "${relayIp}:${relayPort}"
    if ($relayIp -eq '0.0.0.0') { $relayIp = $ServerHost }

    # --- a real UDP payload through the relay: a DNS query whose answer proves the round trip
    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.Client.ReceiveTimeout = 6000
    $udp.Connect($relayIp, $relayPort)
    $q = [byte[]]@(0x12,0x34, 0x01,0x00, 0x00,0x01, 0x00,0x00, 0x00,0x00, 0x00,0x00)
    foreach ($label in 'example','com') { $q += [byte[]]@([byte]$label.Length); $q += [Text.Encoding]::ASCII.GetBytes($label) }
    $q += [byte[]]@(0x00, 0x00,0x01, 0x00,0x01)
    $hdr = [byte[]]@(0,0,0,1) + [System.Net.IPAddress]::Parse($TargetHost).GetAddressBytes() +
           [byte[]]@([byte]($TargetPort -shr 8), [byte]($TargetPort -band 0xFF))
    $pkt = $hdr + $q
    $null = $udp.Send($pkt, $pkt.Length)
    try {
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $reply = $udp.Receive([ref]$ep)
        $dns = $reply[10..($reply.Length - 1)]
        $result.udpRelay = "RELAYED - $($reply.Length) bytes, $($dns[6] * 256 + $dns[7]) DNS answer(s)"
    } catch { $result.udpRelay = "NO REPLY within 6 s" }
    $udp.Close(); $tcp2.Close()
} catch {
    $result.error = $_.Exception.Message.Split("`n")[0]
} finally { $tcp.Close() }

[pscustomobject]$result | Format-List
