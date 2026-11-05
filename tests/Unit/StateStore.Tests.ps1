BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'src\NetStack\StateStore.psm1') -Force
    Import-Module (Join-Path $root 'src\NetStack\Repository.psm1') -Force
}

Describe 'atomic JSON state publication' {
    It 'creates missing directories and emits JSON without a UTF8 BOM' {
        $path = Join-Path $TestDrive 'new\state.json'
        Write-AtomicJson -Path $path -Value @{ enabled = $false; values = @('a', 'b') }
        $back = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        $back.enabled | Should -BeFalse
        @($back.values).Count | Should -Be 2
        $bytes = [IO.File]::ReadAllBytes($path)
        $bytes[0] | Should -Not -Be 239
    }

    It 'resolves relative paths against the PowerShell location' {
        $location = Join-Path $TestDrive 'relative-location'
        $null = New-Item -ItemType Directory -Path $location
        Push-Location $location
        try { Write-AtomicJson -Path '.\state.json' -Value @{ here = $true } }
        finally { Pop-Location }
        Test-Path -LiteralPath (Join-Path $location 'state.json') | Should -BeTrue
    }

    It 'replaces existing state without leaving temporary files' {
        $path = Join-Path $TestDrive 'replace\state.json'
        Write-AtomicJson -Path $path -Value @{ version = 1 }
        Write-AtomicJson -Path $path -Value @{ version = 2 }
        ([IO.File]::ReadAllText($path) | ConvertFrom-Json).version | Should -Be 2
        @(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -Filter '*.tmp').Count | Should -Be 0
    }

    It 'preserves the old state if replacement is denied' {
        $path = Join-Path $TestDrive 'locked\state.json'
        Write-AtomicJson -Path $path -Value @{ version = 1 }
        $reader = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { { Write-AtomicJson -Path $path -Value @{ version = 2 } } | Should -Throw }
        finally { $reader.Dispose() }
        ([IO.File]::ReadAllText($path) | ConvertFrom-Json).version | Should -Be 1
        @(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -Filter '*.tmp').Count | Should -Be 0
    }
}

Describe 'state locks shared by all command paths' {
    It 'prevents overlapping writers and releases after disposal' {
        $path = Join-Path $TestDrive 'locks\hotspot.lock'
        $held = Enter-StateLock -Path $path -TimeoutMilliseconds 10
        try { { Enter-StateLock -Path $path -TimeoutMilliseconds 10 } | Should -Throw '*holds the state lock*' }
        finally { $held.Dispose() }
        $next = Enter-StateLock -Path $path -TimeoutMilliseconds 10
        $next.CanWrite | Should -BeTrue
        $next.Dispose()
    }

    It 'serializes the same device name across independent processes' {
        $name = 'Global\Mihomo-test-' + [guid]::NewGuid().ToString('N')
        $held = Enter-StateMutex -Name $name -TimeoutMilliseconds 10
        $job = $null
        try {
            $module = Join-Path $root 'src\NetStack\StateStore.psm1'
            $job = Start-Job -ArgumentList $module, $name -ScriptBlock {
                param($Module, $Name)
                Import-Module $Module -Force
                try {
                    $handle = Enter-StateMutex -Name $Name -TimeoutMilliseconds 50
                    $handle.ReleaseMutex(); $handle.Dispose()
                    'UnexpectedlyAcquired'
                } catch [TimeoutException] { 'TimedOut' }
            }
            $null = Wait-Job -Job $job -Timeout 15
            $job.State | Should -Be 'Completed'
            @(Receive-Job $job) | Should -Contain 'TimedOut'
        } finally {
            if ($job) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force }
            $held.ReleaseMutex(); $held.Dispose()
        }
    }

    It 'does not let independent state roots block each other' {
        $one = Enter-StateLock -Path (Join-Path $TestDrive 'one\state.lock')
        $two = $null
        try {
            $two = Enter-StateLock -Path (Join-Path $TestDrive 'two\state.lock') -TimeoutMilliseconds 1
            $two.CanWrite | Should -BeTrue
        } finally { if ($two) { $two.Dispose() }; $one.Dispose() }
    }
}

Describe 'repository inventory without Git' {
    BeforeAll {
        $script:ExportRoot = Join-Path $TestDrive 'export'
        foreach ($relative in @(
            'README.md', '.gitignore', 'credentials.ps1', 'passwords.ps1', 'secrets.md', 'src\module.psm1', 'tests\Unit\sample.Tests.ps1',
            'config\mihomo-config.template.yaml', 'config\hysteria2.json',
            'runtime\mihomo-supervisor.ps1', 'runtime\config.yaml', 'runtime\mihomo.log',
            'state\private.json', 'mihomo-src\source.go', 'OpenMPTCProuter_test\source.ps1',
            '.tools\Modules\Pester.psm1', 'artifacts\result.xml',
            'tools\nested\module.ps1', 'tools\nested\subrepo\.git', 'tools\nested\subrepo\private.ps1'
        )) {
            $path = Join-Path $script:ExportRoot $relative
            $null = New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force
            [IO.File]::WriteAllText($path, 'fixture')
        }
        $script:Inventory = @(Get-RepositoryFile -Root $script:ExportRoot -WithoutGit)
    }

    It 'includes maintained code and the sole tracked runtime script' {
        foreach ($path in 'README.md', 'src\module.psm1', 'tests\Unit\sample.Tests.ps1', 'runtime\mihomo-supervisor.ps1', 'tools\nested\module.ps1') {
            $script:Inventory | Should -Contain $path
        }
    }

    It 'never enters live deployments, dependency folders or nested repositories' {
        foreach ($path in 'credentials.ps1', 'passwords.ps1', 'secrets.md', 'config\hysteria2.json', 'runtime\config.yaml', 'runtime\mihomo.log', 'state\private.json', 'mihomo-src\source.go', 'OpenMPTCProuter_test\source.ps1', '.tools\Modules\Pester.psm1', 'artifacts\result.xml', 'tools\nested\subrepo\private.ps1') {
            $script:Inventory | Should -Not -Contain $path
        }
    }

    It 'returns unique stable relative paths' {
        @($script:Inventory | Sort-Object -Unique).Count | Should -Be $script:Inventory.Count
        @($script:Inventory | Where-Object { [IO.Path]::IsPathRooted($_) }).Count | Should -Be 0
    }
}
