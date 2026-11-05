[CmdletBinding()]
param(
    [string] $TemplatePath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\mihomo-config.template.yaml'),
    [string] $DeployedPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime\config.yaml'),
    [switch] $Strict
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\NetStack\ConfigPolicy.psm1') -Force
foreach ($path in $TemplatePath, $DeployedPath) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Config not found: $path" }
}
$report = Compare-MihomoPolicy -Template ([IO.File]::ReadAllText($TemplatePath)) -Deployed ([IO.File]::ReadAllText($DeployedPath))
$report | ConvertTo-Json -Depth 5
if ($Strict -and ($report.RequiresReview -or $report.ObsoleteDeployedDnsKeys -gt 0)) { exit 1 }
