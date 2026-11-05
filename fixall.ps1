[CmdletBinding()]param([switch]$DryRun)
& "$PSScriptRoot\repair-network.ps1" -DryRun:$DryRun
