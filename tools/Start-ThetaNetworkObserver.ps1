# The observer only reads WSL socket/process counters and completed receipts.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$settings=(Get-Content (Join-Path $root 'config\dispatch-policy.json') -Raw|ConvertFrom-Json).nativeThetaObserver
if(-not $settings.enabled -or -not $settings.distribution){return}
$existing=Get-CimInstance Win32_Process -Filter "name = 'wsl.exe'" |
 Where-Object CommandLine -like '*ObserveThetaNetwork.py*'
if($existing){return}
$observer=$settings.linuxRepositoryRoot+'/tools/ObserveThetaNetwork.py'
$arguments="--headless `"$env:WINDIR\System32\wsl.exe`" --distribution `"$($settings.distribution)`" --exec /usr/bin/python3 `"$observer`" --repository `"$($settings.linuxRepositoryRoot)`" --data-root `"$($settings.dataRoot)`""
Start-Process "$env:WINDIR\System32\conhost.exe" -WindowStyle Hidden -ArgumentList $arguments|Out-Null
