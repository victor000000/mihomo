$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module "$root\src\NetStack\Architecture.psm1" -Force
$null=Get-NetworkArchitecture $root
& "$root\tools\Register-MihomoStartup.ps1"
