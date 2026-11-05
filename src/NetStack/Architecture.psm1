# Only the native Windows + Mihomo architecture is supported.
function Get-NetworkArchitecture {
 param([Parameter(Mandatory)][string]$RepositoryRoot)
 $p=Join-Path $RepositoryRoot 'config\network-architecture.json'
 if(-not(Test-Path $p)){throw "Missing network architecture: $p"}
 $c=Get-Content $p -Raw|ConvertFrom-Json
 if($c.mode -ne 'mihomo'){throw 'Invalid network architecture: only mihomo is supported'}
 return 'mihomo'
}
function Get-OrdinaryTransport {
 param([Parameter(Mandatory)][string]$RepositoryRoot)
 $null=Get-NetworkArchitecture $RepositoryRoot
 return 'windows-direct'
}
Export-ModuleMember -Function Get-NetworkArchitecture,Get-OrdinaryTransport
