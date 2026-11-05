BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . (Join-Path $script:Root 'tests\helpers\TestEnvironment.ps1')

    function New-RunnerFixture {
        param([string] $Name)
        $root = Join-Path $TestDrive $Name
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'tests\helpers') -Force
        foreach ($name in @('Run-Tests.ps1', 'Dependencies.psd1', 'helpers\TestEnvironment.ps1')) {
            Copy-Item -LiteralPath (Join-Path $script:Root "tests\$name") -Destination (Join-Path $root "tests\$name")
        }
        return $root
    }

    $script:FixtureRoot = New-RunnerFixture -Name 'runner'
    $local = Get-RepositoryPesterSpec -RepositoryRoot $script:Root
    $moduleParent = Join-Path $script:FixtureRoot '.tools\Modules\Pester'
    $null = New-Item -ItemType Directory -Path $moduleParent -Force
    Copy-Item -LiteralPath $local.Directory -Destination (Join-Path $moduleParent '5.5.0') -Recurse
    $script:Runner = Join-Path $script:FixtureRoot 'tests\Run-Tests.ps1'

    function Invoke-RunnerFixture {
        param([string] $Path, [string] $Xml, [string] $Runner = $script:Runner)
        Invoke-TestPowerShell -ScriptPath $Runner -ArgumentList @('-CI', '-Verbosity', 'None', '-Path', $Path, '-ResultsPath', $Xml)
    }
}

Describe 'the recursive exact-dependency test runner' {
    It 'runs nested tests under this selected engine, excludes Machine BeforeAll and emits usable XML' {
        $path = Join-Path $TestDrive 'passing'
        $null = New-Item -ItemType Directory -Path (Join-Path $path 'nested')
        [IO.File]::WriteAllText((Join-Path $path 'nested\Passing.Tests.ps1'), @'
Describe 'nested hermetic fixture' {
    It 'runs in its parent matrix engine' { $PSVersionTable.PSVersion.Major | Should -BeGreaterOrEqual 5 }
}
Describe 'machine-only fixture' -Tag 'Machine' {
    BeforeAll { throw 'Machine BeforeAll must never execute in the default suite' }
    It 'must be excluded' { throw 'Machine It must never execute in the default suite' }
}
'@)
        # Non-test support scripts must not become containers.
        [IO.File]::WriteAllText((Join-Path $path 'not-a-test.ps1'), "throw 'support file was executed'")
        $xml = Join-Path $TestDrive 'results\passing.xml'
        $child = Invoke-RunnerFixture -Path $path -Xml $xml
        $child.ExitCode | Should -Be 0 -Because ($child.Output -join "`n")
        ($child.Output -join "`n") | Should -Match ('Pester 5\.5\.0 \| PowerShell ' + [regex]::Escape([string]$PSVersionTable.PSVersion))
        Test-Path -LiteralPath $xml | Should -BeTrue
        $report = [xml][IO.File]::ReadAllText($xml)
        $report.DocumentElement.LocalName | Should -Be 'test-results'
        [int]$report.'test-results'.failures | Should -Be 0
    }

    It 'fails a missing repository-local dependency rather than installing or importing a global module' {
        $root = New-RunnerFixture -Name 'missing-dependency'
        $path = Join-Path $root 'tests\Passing.Tests.ps1'
        [IO.File]::WriteAllText($path, "Describe 'passing' { It 'passes' { 1 | Should -Be 1 } }")
        $child = Invoke-RunnerFixture -Path $path -Xml (Join-Path $TestDrive 'missing.xml') -Runner (Join-Path $root 'tests\Run-Tests.ps1')
        $child.ExitCode | Should -Not -Be 0
        ($child.Output -join "`n") | Should -Match 'Initialize-TestEnvironment.ps1'
        ($child.Output -join "`n") | Should -Match 'No dependencies were installed'
        Test-Path -LiteralPath (Join-Path $root '.tools') | Should -BeFalse
    }

    It 'fails a directory with no test files' {
        $path = Join-Path $TestDrive 'empty-directory'
        $null = New-Item -ItemType Directory -Path $path
        $child = Invoke-RunnerFixture -Path $path -Xml (Join-Path $TestDrive 'empty-directory.xml')
        $child.ExitCode | Should -Not -Be 0
        ($child.Output -join "`n") | Should -Match 'No \*\.Tests.ps1 files were found'
    }

    It 'fails <Kind>, even when no individual test is reported failed' -ForEach @(
        @{ Kind = 'zero discovered tests'; Body = '# no Describe or It' },
        @{ Kind = 'a discovery error'; Body = "throw 'synthetic discovery failure'" },
        @{ Kind = 'a container setup error'; Body = "BeforeAll { throw 'synthetic BeforeAll failure' }; Describe 'container' { It 'cannot run' { 1 | Should -Be 1 } }" },
        @{ Kind = 'only excluded Machine tests'; Body = "Describe 'machine' -Tag 'Machine' { It 'must not run' { throw 'excluded' } }" },
        @{ Kind = 'a failed assertion'; Body = "Describe 'failure' { It 'fails' { 1 | Should -Be 2 } }" }
    ) {
        $id = [guid]::NewGuid().ToString('N')
        $path = Join-Path $TestDrive ($id + '.Tests.ps1')
        [IO.File]::WriteAllText($path, $Body)
        $child = Invoke-RunnerFixture -Path $path -Xml (Join-Path $TestDrive ($id + '.xml'))
        $child.ExitCode | Should -Not -Be 0 -Because ($child.Output -join "`n")
    }
}
