BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:root 'src\NetStack\Operations.psm1') -Force
    function New-ProcessFixture($Id, $Parent, $Name, $Command, $Path = '') {
        [pscustomobject]@{ ProcessId = $Id; ParentProcessId = $Parent; Name = $Name; CommandLine = $Command; ExecutablePath = $Path }
    }
}

Describe 'Recovery endpoint ownership and environment decisions' {
    It 'owns exact loopback project ports, including HypoMux and IPv6 loopback' {
        foreach ($value in @('http://127.0.0.1:7897', 'socks5://localhost:1080', 'localhost:10801', 'http://[::1]:10800', 'http://localhost:20171')) {
            Test-StackProxyEnvironmentValue $value | Should -BeTrue
        }
    }
    It 'leaves unrelated proxies and substring lookalikes alone' {
        foreach ($value in @('http://proxy.example:7897', 'http://localhost:78970', 'http://localhost:7898', 'http://localhost.evil:10800', 'http://127.0.0.1:8080', '', 'invalid : proxy')) {
            Test-StackProxyEnvironmentValue $value | Should -BeFalse
        }
    }
    It 'clears Process residue even when persisted variables are already absent' {
        $entries = @(
            [pscustomobject]@{ Scope='Process'; Name='HTTPS_PROXY'; Value='http://localhost:7897' }
            [pscustomobject]@{ Scope='User'; Name='HTTPS_PROXY'; Value=$null }
            [pscustomobject]@{ Scope='Machine'; Name='HTTPS_PROXY'; Value=$null }
            [pscustomobject]@{ Scope='Process'; Name='ALL_PROXY'; Value='http://proxy.example:8080' }
            [pscustomobject]@{ Scope='Process'; Name='NO_PROXY'; Value='localhost:7897' }
        )
        $plan = @(Get-StackProxyEnvironmentPlan $entries)
        $plan.Count | Should -Be 1
        $plan[0].Scope | Should -Be Process
        $plan[0].Name | Should -Be HTTPS_PROXY
    }
    It 'explicitly disables request proxies without changing the caller environment' {
        $script:requestFixture = [pscustomobject]@{ Proxy='inherited proxy'; Timeout=0; ReadWriteTimeout=0 }
        $script:requestFixture | Add-Member ScriptMethod GetResponse {
            if ($null -ne $this.Proxy) { throw 'request did not bypass proxies' }
            $response = [pscustomobject]@{ StatusCode=200 }
            $response | Add-Member ScriptMethod Dispose { }
            return $response
        }
        Test-DirectConnectivity -TimeoutSec 3 -CreateRequest { param($Uri) $script:requestFixture } | Should -BeTrue
        $script:requestFixture.Proxy | Should -BeNullOrEmpty
        $script:requestFixture.Timeout | Should -Be 3000
    }
    It 'does not hide failed repairs behind online connectivity' {
        Get-RecoveryExitCode -Online $true -IssueCount 1 | Should -Be 1
        Get-RecoveryExitCode -Online $false | Should -Be 1
        Get-RecoveryExitCode -Online $true | Should -Be 0
        Get-RecoveryExitCode -Online $false -IssueCount 8 -DryRun | Should -Be 0
    }
}

Describe 'Owned process decisions (no real process queries or termination)' {
    It 'includes only full-path supervisors, their children, and the installed engine' {
        $processes = @(
            (New-ProcessFixture 10 1 pwsh.exe 'pwsh -File "C:\repo space\src\proxy\AliyunTunnel.ps1"')
            (New-ProcessFixture 11 10 ssh.exe 'ssh -D 1080')
            (New-ProcessFixture 12 11 ssh.exe 'nested child')
            (New-ProcessFixture 20 1 ssh.exe 'unrelated ssh')
            (New-ProcessFixture 21 1 pwsh.exe 'pwsh -File C:\other\Server.ps1')
            (New-ProcessFixture 22 1 pwsh.exe 'pwsh -Command "write-host Server.ps1"')
            (New-ProcessFixture 23 1 hypomux-engine.exe '' 'C:\Program Files\HypoMux\bin\hypomux-engine.exe')
            (New-ProcessFixture 24 23 sing-box.exe 'engine child')
            (New-ProcessFixture 25 1 mihomo.exe '' 'C:\other\mihomo.exe')
        )
        $owned = @(Get-StackOwnedProcess $processes -RepoRoot 'C:\repo space')
        ($owned.ProcessId -join ',') | Should -Be '10,11,12,23,24'
    }
    It 'rejects literal repo -File text in command modes, including CLI abbreviations' {
        foreach ($mode in @('Command', 'c', 'EncodedCommand', 'ec', 'enc', 'enco', 'CommandWithArgs')) {
            $command = 'pwsh -{0} "Write-Output ''-File C:\repo\src\dashboard\Collector.ps1 ignored''"' -f $mode
            $process = New-ProcessFixture 30 1 pwsh.exe $command
            @(Get-StackOwnedProcess @($process) -RepoRoot 'C:\repo').Count | Should -Be 0 -Because $mode
            Test-StackScriptRunning @($process) -ScriptPath 'C:\repo\src\dashboard\Collector.ps1' | Should -BeFalse -Because $mode
        }
    }
    It 'still owns headless wrappers and allows script arguments after a real -File' {
        $processes = @(
            (New-ProcessFixture 40 1 conhost.exe 'conhost --headless pwsh -NoProfile -File "C:\repo\src\dashboard\Collector.ps1"')
            (New-ProcessFixture 41 40 pwsh.exe 'pwsh -NoProfile -File "C:\repo\src\dashboard\Collector.ps1" -Command fixture-argument')
        )
        @(Get-StackOwnedProcess $processes -RepoRoot 'C:\repo').Count | Should -Be 2
        Test-StackScriptRunning $processes -ScriptPath 'C:\repo\src\dashboard\Collector.ps1' | Should -BeTrue
    }
    It 'does not confuse Server with Collector or another clone, and excludes self' {
        $processes = @(
            (New-ProcessFixture 1 0 pwsh.exe 'pwsh -File "C:\repo space\src\dashboard\Server.ps1"')
            (New-ProcessFixture 2 0 pwsh.exe 'pwsh -File "C:\other\src\dashboard\Collector.ps1"')
            (New-ProcessFixture 3 0 pwsh.exe 'pwsh -File "C:\repo space\src\dashboard\Collector.ps1"')
        )
        Test-StackScriptRunning $processes -ScriptPath 'C:\repo space\src\dashboard\Collector.ps1' -ExcludeId 3 | Should -BeFalse
        Test-StackScriptRunning $processes -ScriptPath 'C:\repo space\src\dashboard\Collector.ps1' | Should -BeTrue
    }
}

Describe 'Verified task backup before deletion (all task operations mocked)' {
    BeforeEach {
        $script:backup = Join-Path $TestDrive 'saved-task.xml'
        Mock Export-ScheduledTask -ModuleName Operations {
            '<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Actions><Exec><Command>fixture.exe</Command></Exec></Actions></Task>'
        }
        Mock Unregister-ScheduledTask -ModuleName Operations { }
    }
    It 'deletes only after the saved definition is valid and readable' {
        Remove-StackScheduledTask -TaskName FixtureTask -BackupPath $script:backup
        Test-ScheduledTaskBackupXml (Get-Content -LiteralPath $script:backup -Raw) | Should -BeTrue
        Should -Invoke Unregister-ScheduledTask -ModuleName Operations -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'FixtureTask' -and $TaskPath -eq '\' }
    }
    It 'saves UTF-16-declared exports as correctly declared and file-loadable UTF-8 XML' {
        Mock Export-ScheduledTask -ModuleName Operations {
            '<?xml version="1.0" encoding="UTF-16"?><Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Actions><Exec><Command>fixture.exe</Command></Exec></Actions></Task>'
        }
        Remove-StackScheduledTask -TaskName FixtureTask -BackupPath $script:backup
        $doc = New-Object System.Xml.XmlDocument
        $doc.XmlResolver = $null
        # Loading BY FILE exercises declaration vs. actual bytes; StringReader cannot detect this bug.
        { $doc.Load($script:backup) } | Should -Not -Throw
        $doc.FirstChild.Encoding | Should -Be 'utf-8'
        Should -Invoke Unregister-ScheduledTask -ModuleName Operations -Times 1 -Exactly
    }
    It 'retains the task when export throws' {
        Mock Export-ScheduledTask -ModuleName Operations { throw 'fixture export denied' }
        { Remove-StackScheduledTask -TaskName FixtureTask -BackupPath $script:backup } | Should -Throw '*export denied*'
        Should -Invoke Unregister-ScheduledTask -ModuleName Operations -Times 0 -Exactly
    }
    It 'retains the task on empty or malformed exports' {
        Mock Export-ScheduledTask -ModuleName Operations { '<Task>' }
        { Remove-StackScheduledTask -TaskName FixtureTask -BackupPath $script:backup } | Should -Throw '*Invalid exported XML*'
        Should -Invoke Unregister-ScheduledTask -ModuleName Operations -Times 0 -Exactly
    }
    It 'retains the task when the backup cannot be written' {
        Mock Set-Content -ModuleName Operations { throw 'fixture disk full' }
        { Remove-StackScheduledTask -TaskName FixtureTask -BackupPath $script:backup } | Should -Throw '*disk full*'
        Should -Invoke Unregister-ScheduledTask -ModuleName Operations -Times 0 -Exactly
    }
    It 'retains the task when readback differs, even when both XML documents are valid' {
        Mock Get-Content -ModuleName Operations { '<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Actions><Exec><Command>wrong.exe</Command></Exec></Actions></Task>' }
        { Remove-StackScheduledTask -TaskName FixtureTask -BackupPath $script:backup } | Should -Throw '*verification failed*'
        Should -Invoke Unregister-ScheduledTask -ModuleName Operations -Times 0 -Exactly
    }
    It 'propagates deletion failure after preserving the verified backup' {
        Mock Unregister-ScheduledTask -ModuleName Operations { throw 'fixture deletion denied' }
        { Remove-StackScheduledTask -TaskName FixtureTask -BackupPath $script:backup } | Should -Throw '*deletion denied*'
        Test-ScheduledTaskBackupXml (Get-Content -LiteralPath $script:backup -Raw) | Should -BeTrue
    }
    It 'rejects a non-task XML document and external entity definitions' {
        Test-ScheduledTaskBackupXml '<root />' | Should -BeFalse
        Test-ScheduledTaskBackupXml '<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task" />' | Should -BeFalse
        Test-ScheduledTaskBackupXml '<!DOCTYPE x SYSTEM "file:///not-read"><Task />' | Should -BeFalse
    }
}

Describe 'Native argument boundaries' {
    It 'quotes spaces, empty arguments, quotes and trailing slashes' {
        ConvertTo-WindowsNativeArgument 'Wi-Fi 2' | Should -Be '"Wi-Fi 2"'
        ConvertTo-WindowsNativeArgument '' | Should -Be '""'
        ConvertTo-WindowsNativeArgument 'a"b' | Should -Be '"a\"b"'
        ConvertTo-WindowsNativeArgument 'C:\path with spaces\' | Should -Be '"C:\path with spaces\\"'
    }
}

