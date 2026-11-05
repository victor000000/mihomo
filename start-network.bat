@echo off
setlocal
set "ACTION=Start"
set "DRY="
for %%A in (%*) do (
  if /i not "%%~A"=="--check" if /i not "%%~A"=="--noPause" if /i not "%%~A"=="--dry" goto :invalid_args
  if /i "%%~A"=="--check" set "ACTION=Status"
  if /i "%%~A"=="--dry" set "DRY=-DryRun"
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0tools\Network.ps1" -Action %ACTION% %DRY%
exit /b %errorlevel%

:invalid_args
exit /b 2
