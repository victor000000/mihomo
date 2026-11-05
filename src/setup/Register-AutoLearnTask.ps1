<#
.SYNOPSIS
    Register the auto-learner as a scheduled task that runs every 5 minutes - without a console window.

.DESCRIPTION
    The learner (src\proxy\Update-AutoLearnRules.ps1) turns observed connection failures into
    mihomo rules. This registers AutoLearnRulesLimited in the USER context with RunLevel Limited,
    so that user can enable, start, stop and replace it without UAC. Before registration, the
    legacy admin-owned AutoLearnRules is disabled and stopped (definition retained). Failure to
    retire that duplicate is fatal; silently continuing would leave two writers. Replacement
    uses Register-ScheduledTask -Force, never a best-effort delete followed by create.

    NO WINDOW, measured rather than assumed (owner, 2026-10-12: "dont using a powershell window
    that borther me, it open/exit instantly"). `pwsh.exe -WindowStyle Hidden` still CREATES a
    console - Hidden only hides it after creation, so a task that runs every 5 minutes flashes one.
    Measured with this script as the control: `-WindowStyle Hidden` took the machine from 20 to 23
    `conhost` processes for one run; the same run wrapped in `conhost.exe --headless` added none
    and exited 0. The task action is therefore `conhost.exe --headless pwsh.exe ...`, the same
    wrapper src\setup\Register-AllTasks.ps1 uses for every interactive task. `-WindowStyle Hidden`
    is kept inside the wrapped command so the inner process does not ask for a window either.

.PARAMETER TaskName
    Name of the task to register. Default: AutoLearnRulesLimited; AutoLearnRules is retired.

.PARAMETER VisibleWindow
    Register the plain `pwsh.exe` invocation instead of the headless wrapper, so a console is
    created. Only for debugging: the whole point of this task is that it is invisible.

.EXAMPLE
    .\Register-AutoLearnTask.ps1
    .\Register-AutoLearnTask.ps1 -TaskName AutoLearnRulesLimited
#>
[CmdletBinding()]
param(
    [string] $TaskName = 'AutoLearnRulesLimited',
    [switch] $VisibleWindow
)

$ErrorActionPreference = 'Stop'
$repo   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # src\setup -> repo root
$script = Join-Path $repo 'src\proxy\Update-AutoLearnRules.ps1'
$conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
if ($TaskName -eq 'AutoLearnRules') { throw 'AutoLearnRules is retired; use AutoLearnRulesLimited instead' }
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw "missing $script" }
# Disable and stop the legacy admin learner BEFORE replacing the limited task.
# Access denied is fatal: continuing would leave two learners writing the same rules.
$legacy = Get-ScheduledTask -TaskName 'AutoLearnRules' -ErrorAction SilentlyContinue
if ($legacy) {
    Disable-ScheduledTask -TaskName 'AutoLearnRules' -ErrorAction Stop | Out-Null
    Stop-ScheduledTask -TaskName 'AutoLearnRules' -ErrorAction Stop
    $legacy = Get-ScheduledTask -TaskName 'AutoLearnRules' -ErrorAction Stop
    if ($legacy.State -ne 'Disabled') { throw 'Legacy AutoLearnRules was not disabled' }
    Write-Output '  AutoLearnRules retired (disabled + stopped; definition retained)'
}

# PowerShell 7 is the default engine (owner, 2026-10-11). The learner is pure
# .NET/HTTP work with no WinRT dependency, so it runs under pwsh.
$body = ('-WindowStyle Hidden -NonInteractive -NoProfile -ExecutionPolicy Bypass -File "{0}" -Quiet' -f $script)
if ($VisibleWindow) {
    $action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument $body -WorkingDirectory $repo
} else {
    $action = New-ScheduledTaskAction -Execute $conhost -Argument ('--headless pwsh.exe ' + $body) -WorkingDirectory $repo
}

$t1 = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$t1.Delay = 'PT2M'
$t2 = New-ScheduledTaskTrigger -Daily -At '00:00'
$rep = (New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 5) `
        -RepetitionDuration (New-TimeSpan -Hours 23 -Minutes 55)).Repetition
$t2.Repetition = $rep
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -MultipleInstances IgnoreNew
# Hidden on the task itself as well: belt and braces with the headless wrapper.
$settings.Hidden = $true
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Force -Action $action -Trigger $t1, $t2 `
    -Settings $settings -Principal $principal `
    -Description 'Learn routing rules from observed connection failures' | Out-Null
$t = Get-ScheduledTask -TaskName $TaskName
Write-Output ("registered {0}  state={1}  runlevel={2}  window={3}  triggers={4}" -f `
    $t.TaskName, $t.State, $t.Principal.RunLevel, $(if ($VisibleWindow) { 'VISIBLE (debug)' } else { 'none (conhost --headless)' }), `
    (($t.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ','))
