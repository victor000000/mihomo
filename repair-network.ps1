[CmdletBinding()]param([switch]$DryRun,[switch]$Deep)
$ErrorActionPreference='Stop'
if($Deep){throw 'Global network resets are not part of the managed Mihomo design'}
& "$PSScriptRoot\tools\Repair-MihomoAdapters.ps1" -CheckOnly:$DryRun
if(-not $DryRun){& "$PSScriptRoot\tools\Mihomo-Startup.ps1"; & "$PSScriptRoot\tools\Set-MihomoSystemProxy.ps1"}
& "$PSScriptRoot\tools\Get-MihomoStatus.ps1"
