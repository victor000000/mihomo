# Dot-sourcing defines helpers only: no imports, snapshots, process stops or hotspot actions.
[CmdletBinding()]
param(
    [string] $RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [switch] $Hotspot
)

function Stop-StackHotspot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepoRoot)
    $file = Join-Path $RepoRoot 'src\hotspot\Hotspot.ps1'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "missing $file" }
    # WinRT requires Windows PowerShell 5.1, never pwsh.
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $file, 'stop')
    $line = ($arguments | ForEach-Object { ConvertTo-WindowsNativeArgument $_ }) -join ' '
    $child = Start-Process -FilePath 'powershell.exe' -ArgumentList $line -NoNewWindow -Wait -PassThru -ErrorAction Stop
    if ($child.ExitCode -ne 0) { throw "Hotspot stop exited $($child.ExitCode)" }
}

function Invoke-StopStack {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepoRoot, [switch] $Hotspot)
    Import-Module (Join-Path $RepoRoot 'src\NetStack\Operations.psm1') -Force -ErrorAction Stop
    $issues = New-Object System.Collections.Generic.List[string]
    $stoppedIds = New-Object System.Collections.Generic.List[int]
    $before = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    $owned = @(Get-StackOwnedProcess -Processes $before -RepoRoot $RepoRoot -ExcludeId $PID -IncludeHypoMux:$false)
    # Stop all repo-owned wrappers/supervisors before their native children. Child ownership
    # comes from this snapshot, not from a later snapshot after ancestry has disappeared.
    $ordered = @($owned | Sort-Object @{ Expression = {
        if ($_.Name -in @('pwsh.exe', 'powershell.exe', 'conhost.exe')) { 0 } else { 1 }
    } })
    foreach ($process in $ordered) {
        try {
            $current = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.ProcessId)" -ErrorAction Stop
            if (-not $current) { continue }
            if ($current.CreationDate -ne $process.CreationDate) { throw 'PID was reused; refusing to stop replacement process' }
            $stopped = Stop-Process -Id $process.ProcessId -Force -PassThru -ErrorAction Stop
            if ($stopped -and -not $stopped.WaitForExit(5000)) { throw 'process did not exit within 5 seconds' }
            $stoppedIds.Add([int]$process.ProcessId)
            Write-Host "  stopped $($process.Name) (pid $($process.ProcessId))"
        } catch { $issues.Add("pid $($process.ProcessId): $($_.Exception.Message)") }
    }
    if ($Hotspot) {
        try { Stop-StackHotspot -RepoRoot $RepoRoot }
        catch { $issues.Add("hotspot: $($_.Exception.Message)") }
    }
    $remainingIds = @()
    try {
        $after = @(Get-CimInstance Win32_Process -ErrorAction Stop)
        $freshOwned = @(Get-StackOwnedProcess -Processes $after -RepoRoot $RepoRoot -ExcludeId $PID -IncludeHypoMux:$false)
        # An orphan SSH/sing-box child no longer matches a fresh ancestry traversal. Verify
        # original IDs AND creation times too; a reused PID is not the process we stopped.
        $originalStillAlive = @($after | Where-Object {
            $candidate = $_
            @($owned | Where-Object {
                $_.ProcessId -eq $candidate.ProcessId -and $_.CreationDate -eq $candidate.CreationDate
            }).Count -gt 0
        })
        $remainingIds = @(@($freshOwned) + @($originalStillAlive) | ForEach-Object { [int]$_.ProcessId } | Sort-Object -Unique)
        if ($remainingIds.Count) { $issues.Add("owned process IDs still alive: $($remainingIds -join ', ')") }
    } catch { $issues.Add("verification failed: $($_.Exception.Message)") }
    foreach ($issue in $issues) { Write-Host "  ERROR: $issue" -ForegroundColor Red }
    Write-Host '  HypoMux and its engine/children were left alone. No task or startup policy was changed.'
    [pscustomobject]@{
        ExitCode = (Get-RecoveryExitCode -IssueCount $issues.Count)
        StoppedIds = @($stoppedIds.ToArray())
        RemainingIds = @($remainingIds)
        Issues = @($issues.ToArray())
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-StopStack -RepoRoot $RepoRoot -Hotspot:$Hotspot
        exit $result.ExitCode
    } catch { Write-Error $_; exit 1 }
}
