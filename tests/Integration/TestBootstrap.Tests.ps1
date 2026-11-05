BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . (Join-Path $script:Root 'tests\helpers\TestEnvironment.ps1')
    $script:Bootstrap = Join-Path $script:Root 'tools\Initialize-TestEnvironment.ps1'
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    function New-BootstrapFixture {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'tests')
        Copy-Item -LiteralPath (Join-Path $script:Root 'tests\Dependencies.psd1') -Destination (Join-Path $root 'tests\Dependencies.psd1')
        return $root
    }

    function New-PackageFixture {
        param([string] $Path, [string] $ExtraEntry, [string] $Version = '5.5.0')
        $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entries = @{
                'Pester.psd1' = "@{ ModuleVersion = '$Version'; RootModule = 'Pester.psm1' }"
                # This would fail immediately if the bootstrap imported downloaded code.
                'Pester.psm1' = "throw 'Bootstrap must not execute the extracted module.'"
            }
            if ($ExtraEntry) { $entries[$ExtraEntry] = 'untrusted fixture content' }
            foreach ($name in $entries.Keys) {
                $entry = $archive.CreateEntry($name)
                $writer = New-Object IO.StreamWriter($entry.Open())
                try { $writer.Write($entries[$name]) } finally { $writer.Dispose() }
            }
        } finally { $archive.Dispose() }
    }
}

Describe 'explicit local dependency bootstrap (mocked download)' {
    BeforeEach {
        $script:FixtureRoot = New-BootstrapFixture
        $script:FixturePackage = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.nupkg')
        $script:DownloadPath = $null
        $script:DownloadWorkingDirectory = $null
        Mock Invoke-WebRequest {
            param($Uri, $OutFile)
            $script:DownloadPath = $OutFile
            $script:DownloadWorkingDirectory = $PWD.Path
            # The destination must be empty before anything is downloaded.
            @(Get-ChildItem -LiteralPath (Split-Path $OutFile -Parent) -Force).Count | Should -Be 0
            Copy-Item -LiteralPath $script:FixturePackage -Destination $OutFile
        }
    }

    It 'publishes exactly 5.5.0 locally, never executes package code, and reuses it without another download' {
        New-PackageFixture -Path $script:FixturePackage
        $protocol = [Net.ServicePointManager]::SecurityProtocol
        . $script:Bootstrap -RepositoryRoot $script:FixtureRoot
        $spec = Get-RepositoryPesterSpec -RepositoryRoot $script:FixtureRoot
        Test-RepositoryPester -Manifest $spec.Manifest -Version $spec.Version | Should -BeTrue
        $spec.Directory | Should -Be (Join-Path $script:FixtureRoot '.tools\Modules\Pester\5.5.0')
        $script:DownloadWorkingDirectory | Should -Be (Join-Path $script:Root 'tools')
        $tempRoot = Split-Path (Split-Path $script:DownloadPath -Parent) -Parent
        Test-Path -LiteralPath $tempRoot | Should -BeFalse -Because 'temporary download/extraction data must be removed'
        [Net.ServicePointManager]::SecurityProtocol | Should -Be $protocol
        . $script:Bootstrap -RepositoryRoot $script:FixtureRoot
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://www.powershellgallery.com/api/v2/package/Pester/5.5.0'
        }
    }

    It 'copies from TEMP to a fresh destination-volume sibling before publishing (no second drive required)' {
        New-PackageFixture -Path $script:FixturePackage -ExtraEntry 'assets/nested.txt'
        $script:PublicationStages = @()
        $script:PublicationCopyCommand = Get-Command Copy-Item -CommandType Cmdlet
        Mock Copy-Item {
            param($LiteralPath, $Destination)
            $parent = Join-Path $script:FixtureRoot '.tools\Modules\Pester'
            (Split-Path $Destination -Parent) | Should -Be $parent -Because 'the final rename must have both ends in the same destination-volume directory'
            $sourceRoot = Split-Path (Split-Path $script:DownloadPath -Parent) -Parent
            (Split-Path $LiteralPath -Parent) | Should -Be (Join-Path $sourceRoot 'extract')
            if ($script:PublicationStages.Count -eq 0) {
                @(Get-ChildItem -LiteralPath $Destination -Force).Count | Should -Be 0 -Because 'destination staging must start empty'
            }
            $script:PublicationStages += $Destination
            & $script:PublicationCopyCommand -LiteralPath $LiteralPath -Destination $Destination -Recurse -Force -ErrorAction Stop
        } -ParameterFilter { $Destination -and (Split-Path $Destination -Leaf) -like '.bootstrap-*' }

        . $script:Bootstrap -RepositoryRoot $script:FixtureRoot
        Should -Invoke Copy-Item -Times 3 -Exactly -ParameterFilter {
            $Destination -and (Split-Path $Destination -Leaf) -like '.bootstrap-*'
        }
        @($script:PublicationStages | Sort-Object -Unique).Count | Should -Be 1
        Test-Path -LiteralPath $script:PublicationStages[0] | Should -BeFalse -Because 'the staging directory is consumed by publication'
        $published = Get-RepositoryPesterSpec -RepositoryRoot $script:FixtureRoot
        Test-RepositoryPester -Manifest $published.Manifest -Version $published.Version | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $published.Directory 'assets\nested.txt')) | Should -Be 'untrusted fixture content'
    }

    It 'cleans failed destination-volume staging without publishing a partial dependency' {
        New-PackageFixture -Path $script:FixturePackage
        $script:FailedPublicationStage = $null
        Mock Copy-Item {
            param($Destination)
            $script:FailedPublicationStage = $Destination
            throw 'synthetic cross-volume copy failure'
        } -ParameterFilter { $Destination -and (Split-Path $Destination -Leaf) -like '.bootstrap-*' }
        { . $script:Bootstrap -RepositoryRoot $script:FixtureRoot } | Should -Throw '*synthetic cross-volume copy failure*'
        $script:FailedPublicationStage | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $script:FailedPublicationStage | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:FixtureRoot '.tools\Modules\Pester\5.5.0') | Should -BeFalse
        $tempRoot = Split-Path (Split-Path $script:DownloadPath -Parent) -Parent
        Test-Path -LiteralPath $tempRoot | Should -BeFalse
    }

    It 'rejects unsafe archive entries before publishing a module: <Entry>' -ForEach @(
        @{ Entry = '../escape.txt' },
        @{ Entry = '/rooted.txt' },
        @{ Entry = 'file.txt:stream' },
        @{ Entry = 'nested/../../escape.txt' }
    ) {
        New-PackageFixture -Path $script:FixturePackage -ExtraEntry $Entry
        { . $script:Bootstrap -RepositoryRoot $script:FixtureRoot } | Should -Throw '*Unsafe package entry*'
        Test-Path -LiteralPath (Join-Path $script:FixtureRoot '.tools\Modules\Pester\5.5.0') | Should -BeFalse
        $tempRoot = Split-Path (Split-Path $script:DownloadPath -Parent) -Parent
        Test-Path -LiteralPath $tempRoot | Should -BeFalse
    }

    It 'rejects a different module version instead of silently upgrading or falling back' {
        New-PackageFixture -Path $script:FixturePackage -Version '5.6.0'
        { . $script:Bootstrap -RepositoryRoot $script:FixtureRoot } | Should -Throw '*does not contain Pester 5.5.0*'
        Test-Path -LiteralPath (Join-Path $script:FixtureRoot '.tools\Modules\Pester\5.5.0') | Should -BeFalse
    }

    It 'surfaces download failures and leaves no partial dependency behind' {
        Mock Invoke-WebRequest { throw 'synthetic download failure' }
        { . $script:Bootstrap -RepositoryRoot $script:FixtureRoot } | Should -Throw '*synthetic download failure*'
        Test-Path -LiteralPath (Join-Path $script:FixtureRoot '.tools\Modules\Pester\5.5.0') | Should -BeFalse
    }

    It 'does not merge with or repair an invalid existing module implicitly' {
        $dest = Join-Path $script:FixtureRoot '.tools\Modules\Pester\5.5.0'
        $null = New-Item -ItemType Directory -Path $dest
        [IO.File]::WriteAllText((Join-Path $dest 'sentinel.txt'), 'leave me intact')
        { . $script:Bootstrap -RepositoryRoot $script:FixtureRoot } | Should -Throw '*Invalid local Pester dependency*'
        [IO.File]::ReadAllText((Join-Path $dest 'sentinel.txt')) | Should -Be 'leave me intact'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }
}
