BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module "$root\src\NetStack\Repository.psm1" -Force
}
Describe 'Version discovery without Git' {
    BeforeEach {
        $fixture = Join-Path $TestDrive 'source'
        New-Item $fixture -ItemType Directory -Force | Out-Null
        '0.0.3' | Set-Content (Join-Path $fixture 'VERSION')
        'must not publish' | Set-Content (Join-Path $fixture 'private-password.txt')
    }
    It 'includes the toolkit version in a source export' {
        @(Get-RepositoryFile -Root $fixture -WithoutGit) | Should -Contain 'VERSION'
    }
    It 'does not broaden publication to arbitrary root files' {
        $files = @(Get-RepositoryFile -Root $fixture -WithoutGit)
        $files | Should -Not -Contain 'private-password.txt'
        $files.Count | Should -Be 1
    }
}
