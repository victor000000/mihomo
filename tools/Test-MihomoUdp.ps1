<#
.SYNOPSIS
    Send a UDP datagram through a local SOCKS5 listener and report the answer.

.DESCRIPTION
    Written 2026-10-12 to test mihomo's own UDP path, which differs from a plain SOCKS5 server:
    mihomo accepts UDP ASSOCIATE and then relays the datagram through the OUTBOUND that the routing
    rules select. That makes this script the end-to-end test for "can outbound X carry UDP?" -
    no packet capture, no guessing.

    The payload is a DNS query, so a reply can only come from a working relay.

.EXAMPLE
    # destination 1.1.1.1:53 is routed to the outbound under test
    .\Test-MihomoUdp.ps1 -TargetHost 1.1.1.1 -TargetPort 53
#>
param(
    [string] $ServerHost = '127.0.0.1',
    [int]    $ServerPort = 7897,
    [string] $TargetHost = '1.1.1.1',
    [int]    $TargetPort = 53,
    [int]    $TimeoutMs = 8000
)
$ErrorActionPreference = 'Stop'

function Read-Exact($stream, [int]$n) {
    $buf = New-Object byte[] $n; $got = 0
    while ($got -lt $n) {
        $r = $stream.Read($buf, $got, $n - $got)
        if ($r -le 0) { throw 'connection closed while reading' }
        $got += $r
    }
    return $buf
}

$out = [ordered]@{ listener = "${ServerHost}:${ServerPort}"; target = "${TargetHost}:${TargetPort}" }
$tcp = New-Object System.Net.Sockets.TcpClient
try {
    $tcp.Connect($ServerHost, $ServerPort)
    $s = $tcp.GetStream()
    $s.Write([byte[]]@(5,1,0), 0, 3); $s.Flush()
    $g = Read-Exact $s 2
    $out.greeting = "ver=$($g[0]) method=$($g[1])"

    $s.Write([byte[]]@(5,3,0,1, 0,0,0,0, 0,0), 0, 10); $s.Flush()
    $h = Read-Exact $s 4
    $out.udpAssociate = "rep=$($h[1])"
    if ($h[1] -ne 0) { return [pscustomobject]$out }
    if ($h[3] -eq 1) { $relay = ((Read-Exact $s 4) -join '.') } else { throw "unexpected ATYP $($h[3])" }
    $pb = Read-Exact $s 2
    $rport = $pb[0] * 256 + $pb[1]
    if ($relay -eq '0.0.0.0') { $relay = $ServerHost }
    $out.relay = "${relay}:${rport}"

    $u = New-Object System.Net.Sockets.UdpClient
    $u.Client.ReceiveTimeout = $TimeoutMs
    $u.Connect($relay, $rport)
    $q = [byte[]]@(0xAB,0xCD, 0x01,0x00, 0x00,0x01, 0x00,0x00, 0x00,0x00, 0x00,0x00)
    foreach ($label in 'example','com') { $q += [byte[]]@([byte]$label.Length); $q += [Text.Encoding]::ASCII.GetBytes($label) }
    $q += [byte[]]@(0x00, 0x00,0x01, 0x00,0x01)
    $hdr = [byte[]]@(0,0,0,1) + [System.Net.IPAddress]::Parse($TargetHost).GetAddressBytes() +
           [byte[]]@([byte]($TargetPort -shr 8), [byte]($TargetPort -band 0xFF))
    $pkt = $hdr + $q
    $null = $u.Send($pkt, $pkt.Length)
    try {
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $reply = $u.Receive([ref]$ep)
        $dns = $reply[10..($reply.Length - 1)]
        $out.udpRelay = "RELAYED - $($reply.Length) bytes, $($dns[6] * 256 + $dns[7]) DNS answer(s)"
    } catch { $out.udpRelay = "NO REPLY within $($TimeoutMs / 1000) s" }
    $u.Close()
} catch {
    $out.error = $_.Exception.Message.Split("`n")[0]
} finally { $tcp.Close() }

[pscustomobject]$out | Format-List
