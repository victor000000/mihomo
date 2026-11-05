# Shared by the explicit bootstrap, runner and child-process fixtures. No installs or I/O
# against the live stack belong here.
function Get-RepositoryPesterSpec {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepositoryRoot)

    $data = Import-PowerShellDataFile -LiteralPath (Join-Path $RepositoryRoot 'tests\Dependencies.psd1')
    if (-not $data.Pester -or [string]$data.Pester.RequiredVersion -ne '5.5.0') {
        throw 'tests/Dependencies.psd1 must pin Pester to exactly 5.5.0.'
    }
    $uri = 'https://www.powershellgallery.com/api/v2/package/Pester/' + $data.Pester.RequiredVersion
    if ([string]$data.Pester.PackageUri -cne $uri) {
        throw 'Pester must be downloaded from its exact-version official PowerShell Gallery endpoint.'
    }
    $moduleRoot = Join-Path $RepositoryRoot '.tools\Modules'
    $directory = Join-Path $moduleRoot ('Pester\' + $data.Pester.RequiredVersion)
    [pscustomobject]@{
        Version = [version]$data.Pester.RequiredVersion
        PackageUri = $uri
        ModuleRoot = $moduleRoot
        Directory = $directory
        Manifest = Join-Path $directory 'Pester.psd1'
    }
}

function Test-RepositoryPester {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Manifest, [Parameter(Mandatory)][version] $Version)

    if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { return $false }
    $data = Import-PowerShellDataFile -LiteralPath $Manifest
    if ([version]$data.ModuleVersion -ne $Version -or $data.RootModule -ne 'Pester.psm1') { return $false }
    return (Test-Path -LiteralPath (Join-Path (Split-Path $Manifest -Parent) 'Pester.psm1') -PathType Leaf)
}

function Get-TestPowerShellPath {
    # Resolve from this engine, never PATH: a 5.1 matrix leg must not secretly run
    # its integration tests under pwsh just because it happens to be installed.
    $name = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $path = Join-Path $PSHOME $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Selected test engine not found: $path" }
    return $path
}

function Invoke-TestPowerShell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ScriptPath,
        [string[]] $ArgumentList = @()
    )

    $shell = Get-TestPowerShellPath
    $oldPreference = $ErrorActionPreference
    try {
        # Native stderr is an ErrorRecord in 5.1. Capture it as diagnostic text;
        # the CHILD's exit code, not the parent's preference, defines failure.
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        $output = @(& $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ScriptPath @ArgumentList 2>&1 |
            ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    [pscustomobject]@{ ExitCode = $code; Output = $output }
}
