<#
.SYNOPSIS
    Write a single-file, self-contained backup of this repository.

.DESCRIPTION
    A `git bundle` is the entire repository - every commit and every ref - in one
    file that git itself can read back:

        git clone C:\Users\victo\mihomo-backups\mihomo-20261010-2345.bundle mihomo-restored
        # or, into an existing clone:
        git fetch C:\Users\victo\mihomo-backups\mihomo-20261010-2345.bundle 'refs/*:refs/backup/*'

    Why a bundle rather than copying `.git`: it is a single file (safe to drop in
    OneDrive or on a USB stick - no half-written object files), it is checkable
    with `git bundle verify`, and it can never be mistaken for a live repository
    that a tool might start writing to.

    The bundle is written to a temporary name and only renamed into place after
    `git bundle verify` succeeds, so a failed run cannot leave a file that looks
    like a usable backup.

.PARAMETER Destination
    Folder to write bundles into. Defaults to C:\Users\victo\mihomo-backups.

.PARAMETER Keep
    How many bundles to keep, newest first. Default 5.

.EXAMPLE
    .\tools\Backup-Repo.ps1
    .\tools\Backup-Repo.ps1 -Destination E:\backups -Keep 10
#>
[CmdletBinding()]
param(
    [string] $Destination = 'C:\Users\victo\mihomo-backups',
    [ValidateRange(1, 100)] [int] $Keep = 5
)

$ErrorActionPreference = 'Stop'

# git is not on PATH on this machine by default; the project uses PortableGit.
function Get-GitExe {
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
            'C:\Users\victo\tools\PortableGit\cmd\git.exe',
            "$env:ProgramFiles\Git\cmd\git.exe",
            "${env:ProgramFiles(x86)}\Git\cmd\git.exe")) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    throw 'git not found - put PortableGit\cmd on PATH or pass a repository with git available'
}

$git = Get-GitExe
$root = Split-Path $PSScriptRoot -Parent          # the repository root
if (-not (Test-Path (Join-Path $root '.git'))) { throw "not a git repository: $root" }

if (-not (Test-Path -LiteralPath $Destination)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$name = "mihomo-$stamp.bundle"
$final = Join-Path $Destination $name
$temp = "$final.partial"

Write-Host ''
Write-Host "  repository : $root"
Write-Host "  git        : $git"
Write-Host "  bundle     : $final"

# `git bundle` reports progress and its "is okay" confirmation on STDERR, and
# with $ErrorActionPreference = 'Stop' PowerShell turns any native stderr line
# into a terminating NativeCommandError - which aborted this script *after* the
# bundle had been written and before it could be verified. Native calls here run
# with 'Continue' and are judged by exit code instead.
function Invoke-Git {
    param([string[]] $GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $git @GitArgs 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out.Trim() }
    } finally {
        $ErrorActionPreference = $prev
    }
}

# --all captures every branch and tag, including any refs a partial backup would miss
$created = Invoke-Git @('-C', $root, 'bundle', 'create', $temp, '--all')
if ($created.ExitCode -ne 0) {
    Remove-Item $temp -Force -ErrorAction SilentlyContinue
    throw "git bundle create failed (exit $($created.ExitCode)): $($created.Output)"
}

$verify = Invoke-Git @('-C', $root, 'bundle', 'verify', $temp)
if ($verify.ExitCode -ne 0) {
    Remove-Item $temp -Force -ErrorAction SilentlyContinue
    throw "git bundle verify failed (exit $($verify.ExitCode)): $($verify.Output)"
}

Move-Item -LiteralPath $temp -Destination $final -Force

# --- prune: keep the newest $Keep, delete the rest -------------------------
$old = Get-ChildItem -LiteralPath $Destination -Filter 'mihomo-*.bundle' |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep
foreach ($f in $old) {
    Remove-Item -LiteralPath $f.FullName -Force
    Write-Host "  pruned     : $($f.Name)"
}

$head = (& $git -C $root log -1 --format='%h %s')
$size = [math]::Round((Get-Item $final).Length / 1KB, 0)
Write-Host ''
Write-Host ("  wrote {0} KB, {1} commits, HEAD {2}" -f $size, (& $git -C $root rev-list --count HEAD), $head)
Write-Host ("  bundles kept: {0}" -f (Get-ChildItem -LiteralPath $Destination -Filter 'mihomo-*.bundle').Count)
Write-Host ''
