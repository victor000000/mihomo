function Write-AtomicJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowNull()] $Value,
        [ValidateRange(1, 100)] [int] $Depth = 6
    )
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $directory = [IO.Path]::GetDirectoryName($Path)
    $null = [IO.Directory]::CreateDirectory($directory)
    $tmp = "$Path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = ConvertTo-Json -InputObject $Value -Depth $Depth -Compress
        [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($tmp, $Path) }
    } finally {
        if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
    }
}

function Enter-StateLock {
    [CmdletBinding()]
    [OutputType([IO.FileStream])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [ValidateRange(1, 120000)] [int] $TimeoutMilliseconds = 20000
    )
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        try { return [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] {
            if ($timer.ElapsedMilliseconds -ge $TimeoutMilliseconds) { break }
            Start-Sleep -Milliseconds ([Math]::Min(50, $TimeoutMilliseconds))
        }
    } while ($timer.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    throw [TimeoutException]::new('Another command holds the state lock')
}

function Enter-StateMutex {
    [CmdletBinding()]
    [OutputType([Threading.Mutex])]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [ValidateRange(1, 120000)] [int] $TimeoutMilliseconds = 20000
    )
    $mutex = [Threading.Mutex]::new($false, $Name)
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne($TimeoutMilliseconds) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw [TimeoutException]::new('Another command holds the device lock') }
        return $mutex
    } catch {
        $mutex.Dispose()
        throw
    }
}

Export-ModuleMember -Function Write-AtomicJson, Enter-StateLock, Enter-StateMutex
