# Validate the published archive in isolation, without touching the live deployment.
[CmdletBinding()]
param([string] $RepositoryRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path $RepositoryRoot).Path
$export = Join-Path ([IO.Path]::GetTempPath()) ('mihomo-source-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($export)
$oldPathExt = $env:PATHEXT
try {
    # WSL can pass a Linux PATHEXT to Windows; ensure .exe runs synchronously.
    if (($env:PATHEXT -split ';') -notcontains '.EXE') { $env:PATHEXT = '.COM;.EXE;.BAT;.CMD' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $workspace 'artifacts/mihomo-toolkit.zip'), $export)
    if ((Get-Content (Join-Path $export 'VERSION') -Raw).Trim() -ne (Get-Content (Join-Path $workspace 'VERSION') -Raw).Trim()) { throw 'Packaged toolkit version mismatch.' }
    $manifest = Get-Content (Join-Path $export 'source-manifest.json') -Raw | ConvertFrom-Json
    foreach ($entry in $manifest) {
        if ((Get-FileHash -LiteralPath (Join-Path $export $entry.path) -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw 'Packaged source checksum mismatch.'
        }
    }
    foreach ($policy in @('network-architecture.json', 'dispatch-policy.json', 'codex-cloud-tunnel.json', 'mihomo-adapters.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $export ('config/' + $policy)) -PathType Leaf)) {
            throw "Packaged source is missing required policy: $policy"
        }
    }
    $modules = Join-Path $export '.tools/Modules/Pester'
    $null = New-Item -ItemType Directory -Path $modules -Force
    Copy-Item -LiteralPath (Join-Path $workspace '.tools/Modules/Pester/5.5.0') -Destination $modules -Recurse
    $shellName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $shell = Join-Path $PSHOME $shellName
    & $shell -NoProfile -NonInteractive -WindowStyle Hidden -File (Join-Path $export 'tools/Invoke-RepoChecks.ps1') -RepoRoot $export -Quiet
    if ($LASTEXITCODE -ne 0) { throw "Packaged source checks failed (exit $LASTEXITCODE; shell $shell)." }
    & $shell -NoProfile -NonInteractive -WindowStyle Hidden -File (Join-Path $export 'tests/Run-Tests.ps1') -CI -Verbosity Normal -ResultsPath (Join-Path $workspace 'artifacts/test-results/source-export-7.xml')
    if ($LASTEXITCODE -ne 0) { throw 'Packaged source tests failed.' }
    Push-Location $export
    try {
        & python -m unittest discover -s tests/gateway -p 'test_*.py'
        if ($LASTEXITCODE -ne 0) { throw 'Packaged Python tests failed.' }
        & node --test tests/web/dashboard.test.cjs
        if ($LASTEXITCODE -ne 0) { throw 'Packaged dashboard tests failed.' }
    } finally { Pop-Location }
} finally {
    $env:PATHEXT = $oldPathExt
    Remove-Item -LiteralPath $export -Recurse -Force
}
