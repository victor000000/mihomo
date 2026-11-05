# Keep the local capacity/health controller running without a visible console.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$policy=Join-Path $root 'config\dispatch-policy.json'
if(-not(Test-Path $policy)){return}
$settings=Get-Content $policy -Raw|ConvertFrom-Json
if(-not $settings.enabled){return}
& (Join-Path $PSScriptRoot 'Start-ThetaNetworkObserver.ps1')
$script=Join-Path $PSScriptRoot 'AdaptiveDispatch.py'
$existing=Get-CimInstance Win32_Process -Filter "name = 'python.exe' OR name = 'pythonw.exe'" |
 Where-Object { $_.CommandLine -like "*$script*" -and $_.CommandLine -notlike '*--once*' }
if($existing){return}
$state=Join-Path $root 'state\adaptive-dispatch'
New-Item -ItemType Directory -Path $state -Force|Out-Null
$python=Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
if(-not(Test-Path $python)){throw 'Bundled Windows Python is missing; install/configure the controller runtime before startup.'}
$args="-B `"$script`" --policy `"$policy`" --state `"$state`""
Start-Process "$env:WINDIR\System32\conhost.exe" -WindowStyle Hidden `
 -ArgumentList "--headless `"$python`" $args"|Out-Null
