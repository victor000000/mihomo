# Hidden logon launchers. Existing proxy sessions are not restarted.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module "$root\src\NetStack\Architecture.psm1" -Force
$null=Get-NetworkArchitecture $root
$startup=[Environment]::GetFolderPath('Startup')
foreach($entry in @(@('Mihomo-Startup.vbs','Mihomo-Startup.ps1'),@('Mihomo-PacServer.vbs','Serve-Pac.ps1'))){
 $body='CreateObject("WScript.Shell").Run """C:\Windows\System32\conhost.exe"" --headless ""C:\Program Files\PowerShell\7\pwsh.exe"" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""'+$root+'\tools\'+$entry[1]+'""", 0, False'
 $body|Set-Content (Join-Path $startup $entry[0]) -Encoding ASCII
}
foreach($name in 'OMR-Gateway-Mihomo.vbs','OMR-PacServer.vbs','OMR-VM-Autostart.vbs','OMR-AliyunTunnel.vbs','OMR-Bridge.vbs','OMR-Bridge-Watchdog.vbs'){
 $path=Join-Path $startup $name
 if(Test-Path $path){Remove-Item -LiteralPath $path}
}
Write-Output 'Hidden Mihomo and PAC logon launchers installed'
