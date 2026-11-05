# Optional user-logon integration. Does not stop or relaunch an existing Codex app.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$startup=[Environment]::GetFolderPath('Startup')
$shortcut=Join-Path $startup 'Codex Desktop.lnk'
$backup=Join-Path $root ('state\codex-startup\registration-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory $backup -Force | Out-Null
if(Test-Path $shortcut){Copy-Item $shortcut $backup}
$link=(New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
$link.TargetPath="$env:WINDIR\System32\conhost.exe"
$link.Arguments="--headless `"$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$root\tools\Start-CodexAfterNetwork.ps1`""
$link.WorkingDirectory=$root
$link.WindowStyle=7
$link.Save()
Write-Output "Registered headless network-aware Codex startup. Backup: $backup"
