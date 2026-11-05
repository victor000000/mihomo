BeforeAll {
    $script:repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:stopScript = Join-Path $script:repo 'src\operations\Stop-Stack.ps1'
    Import-Module (Join-Path $script:repo 'src\NetStack\Operations.psm1') -Force
    . $script:stopScript
    function New-StopProcessFixture($Id, $Parent, $Name, $Command = '', $Path = '') {
        [pscustomobject]@{ ProcessId=$Id; ParentProcessId=$Parent; Name=$Name; CommandLine=$Command; ExecutablePath=$Path; CreationDate=[datetime]'2026-10-20T00:00:00' }
    }
}

Describe 'Scoped stack stop with mocked process snapshots and termination' {
    BeforeEach {
        $script:initial = @(
            (New-StopProcessFixture 10 1 pwsh.exe 'pwsh -File C:\fixture\src\proxy\AliyunTunnel.ps1')
            (New-StopProcessFixture 11 10 ssh.exe 'ssh tunnel child')
            (New-StopProcessFixture 20 1 ssh.exe 'unrelated ssh session')
            (New-StopProcessFixture 30 1 pwsh.exe 'pwsh -File C:\fixture\src\monitor\BootAudit.ps1')
            (New-StopProcessFixture 31 30 hypomux.exe '' 'C:\Program Files\HypoMux\hypomux.exe')
            (New-StopProcessFixture 32 31 hypomux-engine.exe '' 'C:\Program Files\HypoMux\bin\hypomux-engine.exe')
            (New-StopProcessFixture 33 32 sing-box.exe 'HypoMux child')
            (New-StopProcessFixture 40 1 mihomo.exe '' 'C:\fixture\runtime\mihomo.exe')
            (New-StopProcessFixture 50 1 pwsh.exe 'pwsh -File C:\other\src\dashboard\Server.ps1')
            (New-StopProcessFixture 51 1 sing-box.exe '' 'C:\other\sing-box.exe')
        )
        $script:after = @()
        $script:snapshotCalls = 0
        $script:stops = New-Object System.Collections.Generic.List[int]
        $script:live = @{}
        foreach ($process in $script:initial) {
            $process.CommandLine = $process.CommandLine.Replace('C:\fixture', $script:repo)
            $process.ExecutablePath = $process.ExecutablePath.Replace('C:\fixture', $script:repo)
            $script:live[[int]$process.ProcessId] = $process
        }
        Mock Get-CimInstance {
            if ($Filter) { return $script:live[[int]($Filter -replace '^ProcessId=', '')] }
            $script:snapshotCalls++
            if ($script:snapshotCalls -eq 1) { return $script:initial }
            return $script:after
        }
        Mock Stop-Process {
            $script:stops.Add([int]$Id[0])
            $fake = [pscustomobject]@{ Id=$Id[0] }
            $fake | Add-Member ScriptMethod WaitForExit { param($Milliseconds) return $true }
            return $fake
        }
        Mock Stop-StackHotspot { }
    }
    It 'is inert when dot-sourced' {
        Mock Import-Module { }
        . $script:stopScript
        Should -Invoke Import-Module -Times 0 -Exactly
        Should -Invoke Get-CimInstance -Times 0 -Exactly
        Should -Invoke Stop-Process -Times 0 -Exactly
    }
    It 'stops repo supervisors first and their original children, never HypoMux or unrelated images' {
        $result = Invoke-StopStack -RepoRoot $script:repo
        $result.ExitCode | Should -Be 0
        (($script:stops | Sort-Object) -join ',') | Should -Be '10,11,30,40'
        (($script:stops[0..1] | Sort-Object) -join ',') | Should -Be '10,30'
        ($result.StoppedIds -join ',') | Should -Be ($script:stops -join ',')
        Should -Invoke Stop-StackHotspot -Times 0 -Exactly
    }
    It 'detects an original orphaned SSH child after its supervisor is gone' {
        $script:after = @($script:live[11])
        $result = Invoke-StopStack -RepoRoot $script:repo
        $result.ExitCode | Should -Be 1
        ($result.RemainingIds -join ',') | Should -Be '11'
        $result.Issues -join ';' | Should -Match 'still alive'
    }
    It 'propagates termination errors even when the post-snapshot is empty' {
        Mock Stop-Process { throw 'fixture stop denied' } -ParameterFilter { $Id -eq 11 }
        $result = Invoke-StopStack -RepoRoot $script:repo
        $result.ExitCode | Should -Be 1
        $result.Issues -join ';' | Should -Match 'fixture stop denied'
    }
    It 'does not kill a reused PID or falsely count its replacement as an original survivor' {
        $replacement = New-StopProcessFixture 11 1 ssh.exe 'unrelated replacement'
        $replacement.CreationDate = [datetime]'2026-10-20T01:00:00'
        $script:live[11] = $replacement
        $script:after = @($replacement)
        $result = Invoke-StopStack -RepoRoot $script:repo
        $result.ExitCode | Should -Be 1
        $result.RemainingIds.Count | Should -Be 0
        $result.Issues -join ';' | Should -Match 'PID was reused'
        Should -Invoke Stop-Process -Times 0 -Exactly -ParameterFilter { $Id -eq 11 }
    }
    It 'stops the hotspot only when explicitly requested' {
        $result = Invoke-StopStack -RepoRoot $script:repo -Hotspot
        $result.ExitCode | Should -Be 0
        Should -Invoke Stop-StackHotspot -Times 1 -Exactly -ParameterFilter { $RepoRoot -eq $script:repo }
    }
    It 'propagates optional hotspot and final verification failures' {
        Mock Stop-StackHotspot { throw 'fixture hotspot failed' }
        Mock Get-CimInstance { throw 'fixture verification failed' } -ParameterFilter { -not $Filter -and $script:snapshotCalls -ge 1 }
        $result = Invoke-StopStack -RepoRoot $script:repo -Hotspot
        $result.ExitCode | Should -Be 1
        $result.Issues -join ';' | Should -Match 'fixture hotspot failed'
        $result.Issues -join ';' | Should -Match 'fixture verification failed'
    }
    It 'fails closed when the initial inventory cannot be read' {
        Mock Get-CimInstance { throw 'fixture inventory failed' }
        { Invoke-StopStack -RepoRoot $script:repo } | Should -Throw '*fixture inventory failed*'
        Should -Invoke Stop-Process -Times 0 -Exactly
    }
    It 'preserves HypoMux descendants even when a repo monitor originally launched the GUI' {
        $owned = @(Get-StackOwnedProcess $script:initial -RepoRoot $script:repo -IncludeHypoMux:$false)
        ($owned.ProcessId -join ',') | Should -Be '10,11,30,40'
        $withHypo = @(Get-StackOwnedProcess $script:initial -RepoRoot $script:repo)
        ($withHypo.ProcessId -join ',') | Should -Be '10,11,30,31,32,33,40'
    }
}
