# Native Mihomo supervisor; no VM or tunnel startup dependency.
# Also keeps the two non-critical sidecars alive (PAC server, diagnostics observer) so a
# post-reboot failure is recorded instead of silently missing. Helper failures never stop
# the proxy itself.
$ErrorActionPreference = 'Continue'

$Dir     = 'C:\Users\victo\mihomo\runtime'
$Exe     = "$Dir\mihomo.exe"
$Cfg     = "$Dir\config.yaml"
$LogFile = "$Dir\mihomo-supervisor.log"
$Root    = Split-Path $PSScriptRoot -Parent
Import-Module "$PSScriptRoot\..\src\NetStack\RebootTrace.psm1" -Force
$trace=New-RebootTrace $Root 'proxy-supervisor'


function Write-SupLog([string]$msg) {
    try {
        Write-RebootTrace $trace 'supervisor-event' @{Message=$msg}
        Add-Content -LiteralPath $LogFile -Encoding UTF8 `
            -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
    } catch { }
}

# Stops the log from growing without bound across reboots; keeps one previous file.
function Rotate-Log([string]$path,[int]$maxBytes) {
    try {
        if ((Test-Path $path) -and (Get-Item $path).Length -gt $maxBytes) { Move-Item $path "$path.old" -Force }
    } catch { }
}

function Get-PowerShellProcesses {
    try {
        @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction Stop)
    } catch { @() }
}

function Get-HelperProcesses([string]$pattern) {
    @(Get-PowerShellProcesses | Where-Object { $_.CommandLine -and $_.CommandLine -like "*$pattern*" })
}

function Start-HiddenPowerShell([string]$scriptPath,[string]$label) {
    $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
    try {
        Start-Process "$env:WINDIR\System32\conhost.exe" -WindowStyle Hidden -ArgumentList `
            "--headless `"$pwsh`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`"" | Out-Null
        Write-SupLog "started $label ($scriptPath)"
        return $true
    } catch {
        Write-SupLog "ERROR: could not start $label : $($_.Exception.Message)"
        return $false
    }
}

$script:lastHelperState = ''
$script:lastPacAttempt  = [datetime]::MinValue
$script:lastDiagAttempt = [datetime]::MinValue

# Sidecars are recreatable and independent: the PAC server serves phone/hotspot clients, the
# observer writes per-boot JSONL evidence. Neither is required for local proxying to work.
function Ensure-Helpers {
    try {
        $pacListening = @(Get-NetTCPConnection -State Listen -LocalPort 8080 -ErrorAction SilentlyContinue).Count -gt 0
        $pacCount     = @(Get-HelperProcesses 'Serve-Pac.ps1').Count
        $diagCount    = @(Get-HelperProcesses 'Watch-NetworkDiagnostics.ps1').Count

        if (-not $pacListening) {
            if ((Get-Date) - $script:lastPacAttempt -ge [TimeSpan]::FromSeconds(120)) {
                $script:lastPacAttempt = Get-Date
                if (Start-HiddenPowerShell (Join-Path $Root 'tools\Serve-Pac.ps1') 'PAC server') { $pacCount++ }
            }
        }
        if ($diagCount -eq 0) {
            if ((Get-Date) - $script:lastDiagAttempt -ge [TimeSpan]::FromSeconds(120)) {
                $script:lastDiagAttempt = Get-Date
                [void](Start-HiddenPowerShell (Join-Path $Root 'tools\Watch-NetworkDiagnostics.ps1') 'network diagnostics observer')
            }
        }

        $state = 'pac={0}(listener={1}) diagnostics={2}' -f $pacCount,$pacListening,$diagCount
        if ($state -ne $script:lastHelperState) {
            Write-SupLog "helper state: $state"
            $script:lastHelperState = $state
        }
    } catch {
        Write-SupLog "helper check failed: $($_.Exception.Message)"
    }
}

# A foreign listener on 7897 is a documented failure mode: mihomo cannot bind and the
# supervisor loop would otherwise stay silent forever. Report it once per owner.
function Get-ProxyListener {
    @(Get-NetTCPConnection -State Listen -LocalPort 7897 -ErrorAction SilentlyContinue)
}

Write-SupLog "supervisor start (pid $PID)"
try { Write-SupLog "Windows boot=$((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')); configSHA256=$((Get-FileHash $Cfg).Hash)" } catch { Write-SupLog "Startup metadata unavailable: $($_.Exception.Message)" }

if (-not (Test-Path $Exe)) { Write-SupLog "ERROR: mihomo.exe not found at $Exe"; exit 1 }
if (-not (Test-Path $Cfg)) { Write-SupLog "ERROR: config.yaml not found at $Cfg"; exit 1 }

try {
    $exeVersion = (& $Exe -v 2>&1 | Select-Object -First 1)
    Write-SupLog "mihomo binary: $ExeVersion"
} catch { Write-SupLog "mihomo -v unavailable: $($_.Exception.Message)" }

# The saved native policy can start immediately; health checks select available paths.

$attempt = 0
$lastOwner = ''
$lastDispatchCheck = [datetime]::MinValue
$lastControlCheck = [datetime]::MinValue
Ensure-Helpers
while ($true) {
    $inUse = Get-ProxyListener
    if ($inUse) {
        $owner = (@($inUse.OwningProcess | Sort-Object -Unique) -join ',')
        if ($owner -ne $lastOwner) {
            $ownerName = ''
            try { $ownerName = (@($inUse.OwningProcess | Sort-Object -Unique | ForEach-Object { (Get-Process -Id $_ -ErrorAction Stop).ProcessName }) -join ',') } catch { }
            Write-SupLog "Proxy listener already present; owner PID=$owner process=$ownerName"
            if ($ownerName -and $ownerName -notmatch 'mihomo') { Write-SupLog "WARNING: port 7897 is held by '$ownerName', not mihomo; proxy traffic is not handled by this project" }
            $lastOwner = $owner
        }
        if (((Get-Date) - $lastControlCheck).TotalSeconds -ge 60) {
            try { $version = (Invoke-RestMethod 'http://127.0.0.1:9097/version' -TimeoutSec 4).version } catch { $version = "unreachable: $($_.Exception.Message)" }
            Write-SupLog "controller check: $version"
            $lastControlCheck = Get-Date
        }
        if (((Get-Date) - $lastDispatchCheck).TotalSeconds -ge 60) {
            try { & "$PSScriptRoot\..\tools\Start-AdaptiveDispatch.ps1" } catch { Write-SupLog "Adaptive dispatch startup unavailable: $($_.Exception.GetType().Name)" }
            $lastDispatchCheck = Get-Date
        }
        Ensure-Helpers
        Start-Sleep -Seconds 15; continue
    }
    if ($lastOwner) { Write-SupLog "Proxy listener disappeared; previous owner PID=$lastOwner"; $lastOwner = '' }

    $attempt++
    Write-SupLog "starting mihomo (attempt $attempt)"

    Rotate-Log "$Dir\mihomo.log" 20MB
    Rotate-Log "$Dir\mihomo.err" 4MB

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lineCount = 0
    & $Exe -d $Dir -f $Cfg 2>&1 | ForEach-Object {
        $lineCount++
        try { Add-Content -LiteralPath "$Dir\mihomo.log" -Encoding UTF8 -Value $_ } catch { }
    }
    $sw.Stop()
    Write-SupLog ("mihomo exited code={0} after {1:N0}s; output lines={2}" -f $LASTEXITCODE, $sw.Elapsed.TotalSeconds, $lineCount)

    $wait = [Math]::Min(60, 5 * $attempt)
    Write-SupLog "  retry in ${wait}s"
    Start-Sleep -Seconds $wait
    Ensure-Helpers
}
