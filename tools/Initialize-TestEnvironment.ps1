<#
.SYNOPSIS
    Explicitly bootstrap the exact test dependency into .tools/Modules.
.DESCRIPTION
    No Install-Module, NuGet provider, global module path or repository trust-policy
    changes. Both PowerShell engines use the same repository-local dependency.
    Only this command downloads anything; Run-Tests.ps1 never bootstraps implicitly.
#>
[CmdletBinding()]
param([string] $RepositoryRoot)

$ErrorActionPreference = 'Stop'
if (-not $RepositoryRoot) { $RepositoryRoot = Split-Path $PSScriptRoot -Parent }
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
. (Join-Path $PSScriptRoot '..\tests\helpers\TestEnvironment.ps1')
$spec = Get-RepositoryPesterSpec -RepositoryRoot $RepositoryRoot

if (Test-Path -LiteralPath $spec.Directory) {
    if (-not (Test-RepositoryPester -Manifest $spec.Manifest -Version $spec.Version)) {
        throw "Invalid local Pester dependency at $($spec.Directory). Remove that directory explicitly and rerun this bootstrap."
    }
    Write-Host "Pester $($spec.Version) already ready at $($spec.Manifest)"
    return
}

# The archive and extracted content each get their own NEW, EMPTY directory.
# All extraction code stays in this trusted repository script, never beside the
# downloaded files, and we never execute anything from the extraction directory.
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('mihomo-test-bootstrap-' + [guid]::NewGuid().ToString('N'))
$downloadDirectory = Join-Path $tempRoot 'download'
$extractDirectory = Join-Path $tempRoot 'extract'
$oldProtocol = [Net.ServicePointManager]::SecurityProtocol
$ownsTempRoot = $false
$stagingDirectory = $null
$ownsStagingDirectory = $false
Push-Location -LiteralPath $PSScriptRoot
try {
    $null = New-Item -ItemType Directory -Path $tempRoot
    $ownsTempRoot = $true
    $null = New-Item -ItemType Directory -Path $downloadDirectory
    $null = New-Item -ItemType Directory -Path $extractDirectory
    $package = Join-Path $downloadDirectory 'Pester.nupkg'
    [Net.ServicePointManager]::SecurityProtocol = $oldProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $spec.PackageUri -OutFile $package -UseBasicParsing -ErrorAction Stop

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($package)
    try {
        $extractPrefix = [IO.Path]::GetFullPath($extractDirectory) + [IO.Path]::DirectorySeparatorChar
        $destinations = @{}
        # Validate ALL paths before extracting any entry. Reject traversal, rooted
        # names, ADS, links/reparse points and duplicate (case-insensitive) targets.
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or
                $name.Contains(':') -or @($name.Split('/') | Where-Object { $_ -eq '..' }).Count) {
                throw "Unsafe package entry: $name"
            }
            $target = [IO.Path]::GetFullPath((Join-Path $extractDirectory $name))
            if (-not $target.StartsWith($extractPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Package entry escapes extraction directory: $name"
            }
            $attributes = [int64]$entry.ExternalAttributes
            if (($attributes -band 0x400) -ne 0 -or (($attributes -shr 16) -band 0xF000) -eq 0xA000) {
                throw "Package links/reparse points are not allowed: $name"
            }
            if ($destinations.ContainsKey($target)) { throw "Duplicate package entry: $name" }
            $destinations[$target] = $true
        }
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            $target = [IO.Path]::GetFullPath((Join-Path $extractDirectory $name))
            if ($name.EndsWith('/')) {
                $null = [IO.Directory]::CreateDirectory($target)
                continue
            }
            $null = [IO.Directory]::CreateDirectory((Split-Path $target -Parent))
            $source = $entry.Open()
            try {
                $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
                try { $source.CopyTo($output) } finally { $output.Dispose() }
            } finally { $source.Dispose() }
        }
    } finally { $archive.Dispose() }

    $manifest = Join-Path $extractDirectory 'Pester.psd1'
    if (-not (Test-RepositoryPester -Manifest $manifest -Version $spec.Version)) {
        throw "Downloaded package does not contain Pester $($spec.Version)."
    }
    # TEMP may be on a different volume from the checkout. Copy the validated
    # extraction into a NEW, EMPTY sibling of the final dependency, then publish
    # by a same-volume rename. Never merge into an existing dependency.
    $moduleParent = Split-Path $spec.Directory -Parent
    $null = New-Item -ItemType Directory -Path $moduleParent -Force
    $stagingDirectory = Join-Path $moduleParent ('.bootstrap-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $stagingDirectory
    $ownsStagingDirectory = $true
    foreach ($item in Get-ChildItem -LiteralPath $extractDirectory -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $stagingDirectory -Recurse -Force -ErrorAction Stop
    }
    if (-not (Test-RepositoryPester -Manifest (Join-Path $stagingDirectory 'Pester.psd1') -Version $spec.Version)) {
        throw "Staged package does not contain Pester $($spec.Version)."
    }
    [IO.Directory]::Move($stagingDirectory, $spec.Directory)
    Write-Host "Pester $($spec.Version) ready at $($spec.Manifest)"
} finally {
    [Net.ServicePointManager]::SecurityProtocol = $oldProtocol
    Pop-Location
    try {
        if ($ownsStagingDirectory -and (Test-Path -LiteralPath $stagingDirectory)) {
            Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
        }
    } finally {
        if ($ownsTempRoot -and (Test-Path -LiteralPath $tempRoot)) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}
