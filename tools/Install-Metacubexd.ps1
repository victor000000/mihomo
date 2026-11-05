<#
.SYNOPSIS
    Install or update the metacubexd dashboard that mihomo serves at /ui/.

.DESCRIPTION
    mihomo can serve a static dashboard itself, from the directory named by
    `external-ui` in its config (here: `ui`, relative to `-d`, so runtime\ui) and
    reachable at the controller's /ui/ path:

        http://127.0.0.1:9097/ui/

    This fetches the published `compressed-dist.tgz` release asset and unpacks it,
    so the UI is a reproducible download instead of 158 vendored files in the
    repository (`runtime/ui/` is gitignored on purpose - see .gitignore).

    Two things learned the hard way, both encoded here:

      * mihomo mounts the static route AT STARTUP. A config reload picks up
        `external-ui` in the file but /ui/ keeps returning 404 until the process
        is restarted (measured on v1.19.32).
      * metacubexd reads its backend from `config.js`
        (`window.__METACUBEXD_CONFIG__.defaultBackendURL`). Left empty the UI
        asks for a backend by hand, so this writes the controller URL in.

    The unpack goes to a staging directory and only replaces the live one after
    index.html is present, so an interrupted download cannot leave a half-UI
    being served.

.PARAMETER Version
    Release tag to install, e.g. v1.273.1. Default: whatever the latest release is.

.PARAMETER ControllerUrl
    Backend URL written into the UI's config.js. Default http://127.0.0.1:9097.

.PARAMETER Proxy
    Proxy used for the download. Defaults to the local mihomo mixed port, because
    GitHub is unreliable on this uplink; pass '' to go direct.

.PARAMETER NoProxy
    Download directly, without a proxy.

.EXAMPLE
    .\tools\Install-Metacubexd.ps1
    .\tools\Install-Metacubexd.ps1 -Version v1.273.1
#>
[CmdletBinding()]
param(
    [string] $Version,
    [string] $ControllerUrl = 'http://127.0.0.1:9097',
    [string] $Proxy = 'http://127.0.0.1:7897',
    [switch] $NoProxy
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$uiDir = Join-Path $root 'runtime\ui'
$stage = Join-Path $root 'runtime\ui.staging'

function Get-CurlArgs {
    $a = @('--fail', '--location', '--silent', '--show-error', '--max-time', '300')
    if (-not $NoProxy -and $Proxy) { $a += @('--proxy', $Proxy) }
    return $a
}

# --- which release? --------------------------------------------------------
if (-not $Version) {
    $api = 'https://api.github.com/repos/MetaCubeX/metacubexd/releases/latest'
    $json = & curl.exe @(Get-CurlArgs) $api
    if ($LASTEXITCODE -ne 0) { throw "could not query the latest release (curl exit $LASTEXITCODE)" }
    $Version = ($json | ConvertFrom-Json).tag_name
}
if (-not $Version) { throw 'could not determine a release tag; pass -Version vX.Y.Z' }

$asset = 'compressed-dist.tgz'
$url = "https://github.com/MetaCubeX/metacubexd/releases/download/$Version/$asset"
Write-Host ''
Write-Host "  release  : $Version"
Write-Host "  asset    : $asset"
Write-Host "  target   : $uiDir"
Write-Host "  backend  : $ControllerUrl"

# --- download --------------------------------------------------------------
$tgz = Join-Path $env:TEMP "metacubexd-$Version-$asset"
& curl.exe @(Get-CurlArgs) -o $tgz $url
if ($LASTEXITCODE -ne 0) { throw "download failed (curl exit $LASTEXITCODE): $url" }
$size = (Get-Item $tgz).Length
if ($size -lt 100KB) { throw "downloaded file is only $size bytes - not a UI bundle" }

# --- stage + unpack --------------------------------------------------------
if (Test-Path -LiteralPath $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
& tar.exe -xzf $tgz -C $stage
if ($LASTEXITCODE -ne 0) { throw "tar failed to unpack $tgz (exit $LASTEXITCODE)" }

$index = Join-Path $stage 'index.html'
if (-not (Test-Path -LiteralPath $index)) { throw "staged UI has no index.html - refusing to replace the live one" }

# Point the UI at the controller instead of making the user type it in.
$jsPath = Join-Path $stage 'config.js'
if (Test-Path -LiteralPath $jsPath) {
    $js = [IO.File]::ReadAllText($jsPath, [Text.Encoding]::UTF8)
    $js = $js -replace "defaultBackendURL:\s*'[^']*'", "defaultBackendURL: '$ControllerUrl'"
    [IO.File]::WriteAllText($jsPath, $js, (New-Object System.Text.UTF8Encoding($false)))
}

# --- swap in ---------------------------------------------------------------
if (Test-Path -LiteralPath $uiDir) { Remove-Item $uiDir -Recurse -Force }
Move-Item -LiteralPath $stage -Destination $uiDir

$files = (Get-ChildItem $uiDir -Recurse -File | Measure-Object).Count
# read the version from the INSTALLED copy: $index pointed into the staging dir,
# which no longer exists once it has been moved into place
$installedIndex = Join-Path $uiDir 'index.html'
$ver = ([regex]::Match([IO.File]::ReadAllText($installedIndex, [Text.Encoding]::UTF8), 'appVersion:"([^"]+)"')).Groups[1].Value
Write-Host ''
Write-Host ("  installed: {0} files, UI version {1}" -f $files, $(if ($ver) { $ver } else { 'unknown' }))
Write-Host ''
Write-Host '  mihomo must be RESTARTED for /ui/ to appear - a config reload does not mount it:'
Write-Host '    Stop-Process -Name mihomo      # the MihomoSplitter supervisor relaunches it'
Write-Host ''
