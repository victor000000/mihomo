[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path $PSScriptRoot -Parent),
    [string] $OutputPath,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
if (-not $OutputPath) { $OutputPath = Join-Path $RepositoryRoot 'artifacts\mihomo-toolkit.zip' }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) { throw 'Output already exists; use -Force to replace the source bundle.' }
Import-Module (Join-Path $PSScriptRoot '..\src\NetStack\Repository.psm1') -Force
$paths = @(Get-RepositoryFile -Root $RepositoryRoot | Where-Object {
    $_ -match '^(src|tools|tests|docs|web|archive)[\\/]' -or
    $_ -match '^[^\\/]+\.(bat|ps1|md|mobileconfig)$' -or
    $_ -in @('.gitignore', '.gitattributes', 'runtime\mihomo-supervisor.ps1',
        'config\mihomo-config.template.yaml', 'config\clashmi-recommended-rules.yaml',
        'config\domestic-suffixes.txt', 'config\paid-mix.json',
        'config\mihomo-adapters.json', 'config\network-architecture.json', '.github\workflows\ci.yml')
})
$paths = @($paths | Where-Object {
    [IO.Path]::GetExtension($_) -notin @('.exe', '.dll', '.zip', '.nupkg', '.pcap', '.pfx', '.pem', '.key') -and
    $_ -notmatch '(?i)^[^\\/]*(credential|password|secret)[^\\/]*$'
})
if (-not $paths.Count) { throw 'No maintained source files found.' }

$stage = Join-Path ([IO.Path]::GetTempPath()) ('mihomo-source-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($stage)
try {
    foreach ($relative in $paths) {
        $source = Join-Path $RepositoryRoot $relative
        if ((Get-Item -LiteralPath $source).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Source bundles cannot include symbolic links.' }
        $target = Join-Path $stage $relative
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        Copy-Item -LiteralPath $source -Destination $target
    }
    $manifest = @(
        foreach ($relative in $paths) {
            [pscustomobject]@{ path = ($relative -replace '\\', '/'); sha256 = (Get-FileHash -LiteralPath (Join-Path $stage $relative) -Algorithm SHA256).Hash }
        }
    )
    [IO.File]::WriteAllText((Join-Path $stage 'source-manifest.json'), (ConvertTo-Json -InputObject $manifest -Depth 3), [Text.UTF8Encoding]::new($false))
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($OutputPath))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $temporaryArchive = "$OutputPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.Compression.ZipFile]::CreateFromDirectory($stage, $temporaryArchive)
        Move-Item -LiteralPath $temporaryArchive -Destination $OutputPath -Force
    } finally { if (Test-Path -LiteralPath $temporaryArchive) { Remove-Item -LiteralPath $temporaryArchive -Force } }
    [pscustomobject]@{ Path = $OutputPath; Files = $paths.Count; DeploymentReady = $false }
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force
}
