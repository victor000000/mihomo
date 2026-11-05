# Safe reset entrypoint: repair native adapter state without tearing down sessions.
[CmdletBinding()]param([switch]$DryRun)
& "$PSScriptRoot\repair-network.ps1" -DryRun:$DryRun
