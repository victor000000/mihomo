# Import-safe recovery decisions. Importing this module never reads live machine state.
Set-StrictMode -Version 2.0

function Test-StackProxyEnvironmentValue {
    param([AllowNull()][string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $uri = $null
    $address = $Value.Trim()
    if ($address -notmatch '^[a-z][a-z0-9+.-]*://') { $address = 'http://' + $address }
    if (-not [Uri]::TryCreate($address, [UriKind]::Absolute, [ref]$uri)) { return $false }
    $hostName = $uri.Host.Trim('[', ']')
    $ip = $null
    $loopback = $hostName -in @('localhost', '127.0.0.1')
    if ([Net.IPAddress]::TryParse($hostName, [ref]$ip) -and $ip.Equals([Net.IPAddress]::IPv6Loopback)) { $loopback = $true }
    if (-not $loopback) { return $false }
    return ($uri.Port -in @(7897, 1080, 20171) -or
        ($uri.Port -ge 10800 -and $uri.Port -le 10899) -or
        ($uri.Port -ge 17890 -and $uri.Port -le 17909))
}

function Get-StackProxyEnvironmentPlan {
    param([object[]] $Entries)
    # Include Process: clearing persisted values does not change this process or its children.
    @($Entries | Where-Object {
        $_.Scope -in @('Process', 'User', 'Machine') -and
        $_.Name -match '^(?i:HTTP_PROXY|HTTPS_PROXY|ALL_PROXY)$' -and
        (Test-StackProxyEnvironmentValue -Value $_.Value)
    })
}

function Test-DirectConnectivity {
    param([int] $TimeoutSec = 8,
          [scriptblock] $CreateRequest = { param($Uri) [System.Net.HttpWebRequest]::Create($Uri) })
    foreach ($target in @('http://www.baidu.com/', 'http://www.msftconnecttest.com/connecttest.txt')) {
        $response = $null
        try {
            $request = & $CreateRequest $target
            $request.Proxy = $null  # Explicit direct path on both PS 5.1 and 7; ignore env/WinINET.
            $request.Timeout = $TimeoutSec * 1000
            $request.ReadWriteTimeout = $TimeoutSec * 1000
            $response = $request.GetResponse()
            if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400) { return $true }
        } catch { } finally { if ($response) { $response.Dispose() } }
    }
    return $false
}

function Get-RecoveryExitCode {
    param([int] $IssueCount = 0, [bool] $Online = $true, [switch] $DryRun)
    if ($DryRun) { return 0 }
    if ($IssueCount -gt 0 -or -not $Online) { return 1 }
    return 0
}

function Test-ScheduledTaskBackupXml {
    param([AllowNull()][string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    try {
        # No external entities or DTDs, including in a corrupt saved definition.
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $reader = [System.Xml.XmlReader]::Create((New-Object IO.StringReader($Text)), $settings)
        try {
            $doc = New-Object System.Xml.XmlDocument
            $doc.XmlResolver = $null
            $doc.Load($reader)
            return ($doc.DocumentElement.LocalName -eq 'Task' -and
                $doc.DocumentElement.NamespaceURI -eq 'http://schemas.microsoft.com/windows/2004/02/mit/task' -and
                $null -ne $doc.SelectSingleNode('/*[local-name()="Task"]/*[local-name()="Actions"]/*'))
        } finally { $reader.Dispose() }
    } catch { return $false }
}

function Remove-StackScheduledTask {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $TaskName,
          [string] $TaskPath = '\',
          [Parameter(Mandatory)][string] $BackupPath)
    $xml = Export-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
    if (-not (Test-ScheduledTaskBackupXml -Text $xml)) { throw "Invalid exported XML for $TaskName; task retained" }
    # Export-ScheduledTask declares UTF-16, but Set-Content below writes UTF-8 bytes.
    # Normalize the declaration so the backup is loadable from disk, not just as a string.
    $xml = [regex]::Replace($xml, '(?i)(<\?xml\b[^?]*\bencoding\s*=\s*)(["''])([^"'']+)\2', '$1"utf-8"')
    Set-Content -LiteralPath $BackupPath -Value $xml -Encoding UTF8 -ErrorAction Stop
    $saved = Get-Content -LiteralPath $BackupPath -Raw -Encoding UTF8 -ErrorAction Stop
    if (-not (Test-ScheduledTaskBackupXml -Text $saved) -or $saved.Trim() -cne $xml.Trim()) {
        throw "Saved XML verification failed for $TaskName; task retained"
    }
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction Stop
}

function ConvertTo-WindowsNativeArgument {
    param([AllowEmptyString()][string] $Value)
    # Windows CommandLineToArgvW/CRT quoting; Start-Process joins arrays without quoting.
    '"' + ([regex]::Replace($Value, '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Test-ScriptFileCommandLine {
    param([string] $CommandLine, [string] $ScriptPath)
    $command = $CommandLine.Replace('/', '\')
    $file = [regex]::Escape($ScriptPath.Replace('/', '\'))
    $fileArgument = [regex]::Match($command, ('(?i)(?:^|\s)-File\s+(?:"' + $file + '"|' + $file + '(?=\s|$))'))
    if (-not $fileArgument.Success) { return $false }
    # A -File literal inside -Command/-EncodedCommand text is not an invocation.
    # Inspect only the prefix: script arguments AFTER a real -File cannot change its mode.
    $prefix = $command.Substring(0, $fileArgument.Index)
    foreach ($option in [regex]::Matches($prefix, '(?i)(?:^|\s)-([a-z]+)(?=\s|:|$)')) {
        $name = $option.Groups[1].Value
        if ('Command'.StartsWith($name, [StringComparison]::OrdinalIgnoreCase) -or
            'CommandWithArgs'.StartsWith($name, [StringComparison]::OrdinalIgnoreCase) -or
            'EncodedCommand'.StartsWith($name, [StringComparison]::OrdinalIgnoreCase) -or
            $name -ieq 'ec') { return $false }
    }
    return $true
}

function Get-StackOwnedProcess {
    param([object[]] $Processes, [Parameter(Mandatory)][string] $RepoRoot, [int] $ExcludeId = 0,
          [bool] $IncludeHypoMux = $true)
    $root = $RepoRoot.Replace('/', '\').TrimEnd('\')
    $scripts = @('runtime\mihomo-supervisor.ps1', 'src\proxy\AliyunTunnel.ps1',
        'src\proxy\Watch-Adapters.ps1', 'src\proxy\Update-AutoLearnRules.ps1',
        'src\dashboard\Server.ps1', 'src\dashboard\Collector.ps1',
        'src\monitor\StatusWindow.ps1', 'src\monitor\BootAudit.ps1',
        'src\monitor\Watch-Boot.ps1', 'src\hotspot\Hotspot.ps1',
        'tools\Mihomo-Startup.ps1', 'tools\Watch-MihomoBoot.ps1',
        'tools\Start-MihomoHotspot.ps1')
    $executables = @("$root\runtime\mihomo.exe", "$root\runtime\sing-box.exe",
        'C:\Program Files\HypoMux\hypomux.exe', 'C:\Program Files\HypoMux\bin\hypomux-engine.exe')
    $protected = @{}
    if (-not $IncludeHypoMux) {
        # A repo monitor can launch HypoMux. Preserve its entire subtree even then.
        foreach ($p in $Processes) {
            if ($p.Name -in @('hypomux.exe', 'hypomux-engine.exe')) { $protected[[int]$p.ProcessId] = $true }
        }
        do {
            $added = $false
            foreach ($p in $Processes) {
                if (-not $protected.ContainsKey([int]$p.ProcessId) -and $protected.ContainsKey([int]$p.ParentProcessId)) {
                    $protected[[int]$p.ProcessId] = $true
                    $added = $true
                }
            }
        } while ($added)
    }
    $owned = @{}
    foreach ($p in $Processes) {
        if ($p.ProcessId -eq $ExcludeId -or $protected.ContainsKey([int]$p.ProcessId)) { continue }
        $path = "$($p.ExecutablePath)".Replace('/', '\')
        if ($path -in $executables) { $owned[[int]$p.ProcessId] = $p; continue }
        if ($p.Name -notin @('pwsh.exe', 'powershell.exe', 'conhost.exe')) { continue }
        foreach ($scriptPath in $scripts) {
            if (Test-ScriptFileCommandLine -CommandLine "$($p.CommandLine)" -ScriptPath "$root\$scriptPath") {
                $owned[[int]$p.ProcessId] = $p
                break
            }
        }
    }
    # Include descendants from the SAME snapshot before killing supervisors. In particular,
    # ssh.exe is owned only by ancestry, never by name (unrelated SSH sessions stay alive).
    do {
        $added = $false
        foreach ($p in $Processes) {
            if ($p.ProcessId -eq $ExcludeId -or $protected.ContainsKey([int]$p.ProcessId) -or $owned.ContainsKey([int]$p.ProcessId)) { continue }
            if ($owned.ContainsKey([int]$p.ParentProcessId)) {
                $owned[[int]$p.ProcessId] = $p
                $added = $true
            }
        }
    } while ($added)
    @($Processes | Where-Object { $owned.ContainsKey([int]$_.ProcessId) })
}

function Test-StackScriptRunning {
    param([object[]] $Processes, [Parameter(Mandatory)][string] $ScriptPath, [int] $ExcludeId = 0)
    @($Processes | Where-Object {
        $_.ProcessId -ne $ExcludeId -and $_.Name -in @('pwsh.exe', 'powershell.exe') -and
        (Test-ScriptFileCommandLine -CommandLine "$($_.CommandLine)" -ScriptPath $ScriptPath)
    }).Count -gt 0
}

Export-ModuleMember -Function Test-StackProxyEnvironmentValue, Get-StackProxyEnvironmentPlan,
    Get-RecoveryExitCode, Test-DirectConnectivity, Test-ScheduledTaskBackupXml, Remove-StackScheduledTask,
    ConvertTo-WindowsNativeArgument, Get-StackOwnedProcess, Test-StackScriptRunning
