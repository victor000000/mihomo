BeforeAll {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # Dot-source is intentionally inert: these are the same helpers used by the
    # scheduled server, not a model of the handler and not an admin HTTP socket.
    . (Join-Path $repo 'src\dashboard\Server.ps1')
}

Describe 'Dashboard file-only responses' {
    BeforeEach {
        $script:fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'web') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'state') -Force
        [IO.File]::WriteAllText((Join-Path $fixture 'web\index.html'), '<h1>index fixture</h1>')
        [IO.File]::WriteAllText((Join-Path $fixture 'web\design.html'), '<h1>design fixture</h1>')
        [IO.File]::WriteAllText((Join-Path $fixture 'web\balance.html'), '<h1>balance fixture</h1>')
    }

    It 'serves each existing scheduled URL from the selected root' {
        foreach ($entry in @(
            @{ Path = '/'; Text = 'index fixture' },
            @{ Path = '/index.html'; Text = 'index fixture' },
            @{ Path = '/design'; Text = 'design fixture' },
            @{ Path = '/balance'; Text = 'balance fixture' },
            @{ Path = '/balance.html'; Text = 'balance fixture' }
        )) {
            $response = Get-DashboardResponse -Root $fixture -Path $entry.Path
            $response.StatusCode | Should -Be 200
            $response.ContentType | Should -Be 'text/html; charset=utf-8'
            $response.Body | Should -Match $entry.Text
        }
    }

    It 'returns HTTP 503 before the separate collector has run' {
        $response = Get-DashboardResponse -Root $fixture -Path '/api/status'
        $response.StatusCode | Should -Be 503
        $response.ContentType | Should -Be 'application/json; charset=utf-8'
        ($response.Body | ConvertFrom-Json).error | Should -Match 'not built yet'
        Test-Path (Join-Path $fixture 'state\status.json') | Should -BeFalse
    }

    It 'serves the snapshot verbatim without rewriting or collecting it' {
        $path = Join-Path $fixture 'state\status.json'
        $json = '{"updated":"fixture","mihomo":{"connections":17},"host":"offline"}'
        [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
        $before = (Get-Item $path).LastWriteTimeUtc
        1..3 | ForEach-Object {
            (Get-DashboardResponse -Root $fixture -Path '/api/status').Body | Should -BeExactly $json
        }
        [IO.File]::ReadAllText($path) | Should -BeExactly $json
        (Get-Item $path).LastWriteTimeUtc | Should -Be $before
    }

    It 'bounds status reads at 256 KB and still serves the exact boundary' {
        $path = Join-Path $fixture 'state\status.json'
        $boundary = '{"padding":"' + ('x' * (262144 - 14)) + '"}'
        $boundary.Length | Should -Be 262144
        [IO.File]::WriteAllText($path, $boundary, [Text.UTF8Encoding]::new($false))
        $response = Get-DashboardResponse -Root $fixture -Path '/api/status'
        $response.StatusCode | Should -Be 200
        $response.Body.Length | Should -Be 262144
        [IO.File]::WriteAllText($path, (' ' * 262145), [Text.UTF8Encoding]::new($false))
        $response = Get-DashboardResponse -Root $fixture -Path '/api/status'
        $response.StatusCode | Should -Be 503
        ($response.Body | ConvertFrom-Json).error | Should -Match 'exceeds 256 KB'
        $response.Body.Length | Should -BeLessThan 300
    }

    It 'rejects corrupt, empty, scalar, array and invalid UTF-8 status with HTTP 503' {
        $path = Join-Path $fixture 'state\status.json'
        foreach ($json in @('', ' ', '{"broken":', 'null', 'true', '[]', '[{"host":"not-an-object"}]', '"string"')) {
            [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
            $response = Get-DashboardResponse -Root $fixture -Path '/api/status'
            $response.StatusCode | Should -Be 503
            ($response.Body | ConvertFrom-Json).error | Should -Not -BeNullOrEmpty
        }
        [IO.File]::WriteAllBytes($path, [byte[]]@(123, 34, 120, 34, 58, 34, 255, 34, 125))
        $response = Get-DashboardResponse -Root $fixture -Path '/api/status'
        $response.StatusCode | Should -Be 503
        ($response.Body | ConvertFrom-Json).error | Should -Match 'corrupt'
    }

    It 'does not expose arbitrary files or traverse outside the web allowlist' {
        foreach ($path in @('/state/status.json', '/../README.md', '/web/index.html', '/api/unknown')) {
            (Get-DashboardResponse -Root $fixture -Path $path).StatusCode | Should -Be 404
        }
        Remove-Item -LiteralPath (Join-Path $fixture 'web\balance.html')
        (Get-DashboardResponse -Root $fixture -Path '/balance').StatusCode | Should -Be 404
    }

    It 'sets response metadata in UTF-8 bytes and closes a socket-free response double' {
        $stream = New-Object IO.MemoryStream
        $http = [pscustomobject]@{ StatusCode = 0; ContentType = ''; ContentLength64 = 0; OutputStream = $stream; Closed = $false }
        $http | Add-Member -MemberType ScriptMethod -Name Close -Value { $this.Closed = $true }
        $context = [pscustomobject]@{ Response = $http }
        $body = 'unicode ' + [char]0x4E2D
        try {
            Send-DashboardResponse -Context $context -Response @{ StatusCode = 200; ContentType = 'application/json; charset=utf-8'; Body = $body }
            $http.Closed | Should -BeTrue
            $http.StatusCode | Should -Be 200
            $http.ContentType | Should -Be 'application/json; charset=utf-8'
            $http.ContentLength64 | Should -Be ([Text.Encoding]::UTF8.GetByteCount($body))
            [Text.Encoding]::UTF8.GetString($stream.ToArray()) | Should -BeExactly $body
        } finally { $stream.Dispose() }
    }

    It 'permits only HTTP loopback origins as listener prefixes without opening sockets' {
        foreach ($prefix in @('http://127.0.0.1:8899/', 'http://localhost:8899/', 'http://[::1]:8899/')) {
            Test-DashboardPrefix $prefix | Should -BeTrue
        }
        foreach ($prefix in @('http://+:8899/', 'http://*:8899/', 'http://0.0.0.0:8899/',
                'http://192.168.1.2:8899/', 'http://localhost:8899/other/', 'http://user@localhost:8899/',
                'http://localhost:8899/?a=b', 'https://localhost:8899/', 'http://localhost:8899')) {
            Test-DashboardPrefix $prefix | Should -BeFalse
        }
    }
}
