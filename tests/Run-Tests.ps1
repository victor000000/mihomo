<#
.SYNOPSIS
    Run hermetic tests with the exact repository-local Pester dependency.
.DESCRIPTION
    First explicitly run tools/Initialize-TestEnvironment.ps1 (the only network
    step). Then run this script under either Windows PowerShell 5.1 or PowerShell 7.
    Tests are discovered recursively. Machine-tagged tests are excluded unless
    -IncludeMachine is explicitly supplied: those tests inspect the real machine
    and may run recovery tools, access app stores and make network probes.
    XML defaults to artifacts/test-results/powershell-<engine>.xml.
.EXAMPLE
    ./tests/Run-Tests.ps1 -CI
    ./tests/Run-Tests.ps1 -Path ./tests/Integration -Verbosity Detailed
#>
[CmdletBinding()]
param(
    [switch] $CI,
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string] $Verbosity = 'Normal',
    [string[]] $Path,
    [string] $ResultsPath,
    [switch] $IncludeMachine
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $PSBoundParameters.ContainsKey('Path')) { $Path = @($PSScriptRoot) }
if (-not $Path -or @($Path | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    throw 'At least one non-empty test path must be supplied.'
}
$engine = if ($PSVersionTable.PSVersion.Major -eq 5) { '5.1' } else { [string]$PSVersionTable.PSVersion.Major }
if (-not $ResultsPath) { $ResultsPath = Join-Path $root "artifacts\test-results\powershell-$engine.xml" }
$ResultsPath = [IO.Path]::GetFullPath($ResultsPath)
# Even an early dependency/discovery failure must not leave a previous success's
# XML at the artifact path.
if (Test-Path -LiteralPath $ResultsPath) { Remove-Item -LiteralPath $ResultsPath -Force }
. (Join-Path $PSScriptRoot 'helpers\TestEnvironment.ps1')
$spec = Get-RepositoryPesterSpec -RepositoryRoot $root
if (-not (Test-RepositoryPester -Manifest $spec.Manifest -Version $spec.Version)) {
    throw "Pester $($spec.Version) is required at $($spec.Manifest). Run ./tools/Initialize-TestEnvironment.ps1 explicitly first. No dependencies were installed."
}

# Resolve paths ourselves so empty input/globs fail instead of silently becoming
# a green run. Directories include all nested *.Tests.ps1, including Integration.
$testFiles = @(
    foreach ($item in $Path) {
        foreach ($resolved in @(Get-Item -Path $item -ErrorAction Stop)) {
            if ($resolved.PSIsContainer) {
                Get-ChildItem -LiteralPath $resolved.FullName -Recurse -File -Filter '*.Tests.ps1'
            } elseif ($resolved.Name -like '*.Tests.ps1') {
                $resolved
            } else { throw "Not a *.Tests.ps1 file or test directory: $item" }
        }
    }
) | Sort-Object FullName -Unique
if (@($testFiles).Count -eq 0) { throw 'No *.Tests.ps1 files were found. Refusing an empty test run.' }

$oldModulePath = $env:PSModulePath
try {
    $env:PSModulePath = $spec.ModuleRoot + [IO.Path]::PathSeparator + $oldModulePath
    # Remove an already-imported global Pester: command resolution must not select
    # the Windows inbox version or a newer workstation version over our exact pin.
    Get-Module Pester | Remove-Module -Force
    $pester = Import-Module -Name $spec.Manifest -RequiredVersion $spec.Version -Force -PassThru -ErrorAction Stop
    if ($pester.Version -ne $spec.Version -or $pester.ModuleBase -ne $spec.Directory) {
        throw "Imported an unexpected Pester dependency: $($pester.Path) $($pester.Version)"
    }
    Write-Host ("Pester {0} | PowerShell {1} | {2} test file(s)" -f $pester.Version, $PSVersionTable.PSVersion, @($testFiles).Count)

    $null = New-Item -ItemType Directory -Path (Split-Path $ResultsPath -Parent) -Force
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = @($testFiles.FullName)
    $cfg.Run.PassThru = $true
    $cfg.Run.Exit = $false
    $cfg.Output.Verbosity = $Verbosity
    if (-not $IncludeMachine) { $cfg.Filter.ExcludeTag = @('Machine') }
    if ($CI) { $cfg.Output.CIFormat = 'GithubActions' }
    $cfg.TestResult.Enabled = $true
    $cfg.TestResult.OutputFormat = 'NUnitXml'
    $cfg.TestResult.OutputPath = $ResultsPath

    $result = Invoke-Pester -Configuration $cfg
    if ($null -eq $result) { throw 'Pester returned no result.' }
    Write-Host ("Passed {0} | Failed {1} | Skipped {2} | Total {3}" -f $result.PassedCount, $result.FailedCount, $result.SkippedCount, $result.TotalCount)

    # FailedCount alone misses discovery errors and failed BeforeAll containers.
    $failedContainers = @($result.Containers | Where-Object { $_.Result -eq 'Failed' -or ($_.ErrorRecord -and @($_.ErrorRecord).Count -gt 0) })
    if ($result.TotalCount -eq 0 -or $result.PassedCount -eq 0 -or $result.FailedCount -gt 0 -or
        $result.FailedContainersCount -gt 0 -or $result.FailedBlocksCount -gt 0 -or
        $failedContainers.Count -gt 0 -or $result.Result -ne 'Passed') {
        throw "Tests failed or no tests executed (result=$($result.Result), total=$($result.TotalCount), failed containers=$($failedContainers.Count)). XML: $ResultsPath"
    }
    if (-not (Test-Path -LiteralPath $ResultsPath -PathType Leaf) -or (Get-Item -LiteralPath $ResultsPath).Length -eq 0) {
        throw "Pester did not produce the required XML artifact: $ResultsPath"
    }
    Write-Host "All tests passed. XML: $ResultsPath"
} finally {
    $env:PSModulePath = $oldModulePath
}
