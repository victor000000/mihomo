function Get-RepositoryFile {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [string] $Root, [switch] $WithoutGit)

    $Root = (Resolve-Path -LiteralPath $Root).Path
    $git = if (-not $WithoutGit) { Get-Command git -ErrorAction SilentlyContinue }
    if ($git) {
        $code = 1
        try {
            $paths = @(& $git.Source -C $Root -c core.quotePath=false ls-files --cached --others --exclude-standard 2>$null)
            $code = $LASTEXITCODE
        } catch { $paths = @() }
        if ($code -eq 0) {
            return @($paths | ForEach-Object { $_ -replace '/', '\' } | Where-Object {
                $_ -and (Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf)
            } | Sort-Object -Unique)
        }
    }

    # A source export may not have Git. Never recursively walk the deployment:
    # runtime/ and independently versioned repositories contain live credentials.
    $roots = @('src', 'tests', 'tools', 'docs', 'web', 'archive', '.github')
    $skip = @('.git', '.tools', 'artifacts', 'node_modules', 'bin', 'obj', '.vs', '__pycache__')
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File)) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($file.Name -match '(?i)(credential|password|secret|\.bak|\.tmp|\.log)') { continue }
        if ($file.Name -in @('.gitignore', '.gitattributes') -or $file.Extension -in @('.ps1', '.psm1', '.psd1', '.bat', '.cmd', '.md', '.mobileconfig')) {
            $files.Add($file.Name)
        }
    }
    foreach ($relative in @('config\mihomo-config.template.yaml', 'config\clashmi-recommended-rules.yaml', 'config\domestic-suffixes.txt', 'config\paid-mix.json', 'config\mihomo-adapters.json', 'config\network-architecture.json', 'runtime\mihomo-supervisor.ps1')) {
        if (Test-Path -LiteralPath (Join-Path $Root $relative) -PathType Leaf) { $files.Add($relative) }
    }
    $pending = New-Object System.Collections.Queue
    foreach ($dir in $roots) {
        $path = Join-Path $Root $dir
        if (Test-Path -LiteralPath $path -PathType Container) {
            $item = Get-Item -LiteralPath $path
            if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $pending.Enqueue($path) }
        }
    }
    while ($pending.Count) {
        $dir = [string]$pending.Dequeue()
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($item.PSIsContainer) {
                if ($item.Name -notin $skip -and -not (Test-Path -LiteralPath (Join-Path $item.FullName '.git'))) {
                    $pending.Enqueue($item.FullName)
                }
            } elseif ($item.Name -notmatch '(?i)(credential|password|secret|\.bak|\.tmp|\.log)' -and $item.Extension -notin @('.exe', '.dll', '.zip', '.nupkg', '.pem', '.key')) {
                $files.Add($item.FullName.Substring($Root.Length).TrimStart('\', '/'))
            }
        }
    }
    return @($files | Sort-Object -Unique)
}

function Test-GeneratedRepositoryPath {
    [CmdletBinding()]
    param([string] $Path)
    $relative = ($Path -replace '\\', '/') -replace '^\./', ''
    return ($relative -match '^(state/|artifacts/|\.tools/|runtime/(config[^/]*\.ya?ml(?:\..*)?$|rules/|providers/|ui(?:\.staging)?/|sing-box/|[^/]+\.(exe|dll|dat|db|log|err)(?:\..*)?$))')
}

Export-ModuleMember -Function Get-RepositoryFile, Test-GeneratedRepositoryPath
