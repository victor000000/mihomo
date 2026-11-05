# Set user proxy only after the local controller responds; no adapter/global reset.
[CmdletBinding()]param([switch]$Disable)
$ErrorActionPreference='Stop'
$key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
if(-not $Disable){
 Invoke-RestMethod http://127.0.0.1:9097/version -TimeoutSec 3|Out-Null
 Set-ItemProperty $key -Name ProxyServer -Value '127.0.0.1:7897'
 Set-ItemProperty $key -Name ProxyOverride -Value '<local>'
}
Set-ItemProperty $key -Name ProxyEnable -Value ([int](-not $Disable))
if(-not ('MihomoProxy.WinInet' -as [type])){
 Add-Type -Namespace MihomoProxy -Name WinInet -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("wininet.dll", SetLastError=true)]
public static extern bool InternetSetOption(System.IntPtr h, int option, System.IntPtr buffer, int length);
'@
}
[MihomoProxy.WinInet]::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0)|Out-Null
[MihomoProxy.WinInet]::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0)|Out-Null
