BeforeAll { $script:Root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
Describe 'Headless operator entrypoints' {
 BeforeEach {
  $script:fixture=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
  New-Item "$fixture\tools" -ItemType Directory -Force|Out-Null
  Copy-Item "$Root\repair-network.bat" $fixture
  'param($Action,[switch]$DryRun); if($DryRun){exit 9};exit 7'|Set-Content "$fixture\tools\Network.ps1"
 }
 It 'preserves the child exit code' {
  & $env:ComSpec /d /s /c ('""'+$fixture+'\repair-network.bat""')
  $LASTEXITCODE|Should -Be 7
 }
 It 'forwards dry-run and rejects unknown flags before executing' {
  & $env:ComSpec /d /s /c ('""'+$fixture+'\repair-network.bat" --dry"')
  $LASTEXITCODE|Should -Be 9
  & $env:ComSpec /d /s /c ('""'+$fixture+'\repair-network.bat" --not-valid"')
  $LASTEXITCODE|Should -Be 2
 }
}
