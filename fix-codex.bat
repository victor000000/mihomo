@echo off
rem ===========================================================================
rem  Codex desktop app - repair its connection
rem
rem  Owner, 2026-10-12: "codex desktop still cannot visit deepseekapi" ... "you
rem  can write a script especially for codex, as you do for deepseek".
rem
rem  The counterpart of fix-deepseek.bat, and it exists because that repair could
rem  not fix this: api.deepseek.com was answering the whole time while every Codex
rem  turn died with "Connection failed: error sending request" and the window
rem  showed only "Reconnecting... waiting for network".
rem
rem  The cause it repairs: the Codex desktop app is an MSIX package, so it reads a
rem  PRIVATE, virtualised copy of HKCU\...\Internet Settings out of its own
rem  "Helium" registry store -
rem
rem    %LOCALAPPDATA%\Packages\OpenAI.Codex_*\SystemAppData\Helium\User.dat
rem
rem  - and never reads the real key again. That store held
rem  ProxyServer = 127.0.0.1:7897 while the real HKCU was provably clean, so the
rem  app sat in SynSent to a port with nothing behind it and only ever said
rem  "waiting for network". Turning the system proxy OFF made it worse, not
rem  better: with no real proxy to resolve, the app falls back to the cached one.
rem  The value is UTF-16LE inside a hive whose value names are ASCII, which is why
rem  grepping the store for 7897 and `reg query` on HKCU both find nothing.
rem
rem  What it does:
rem    0. captures the state that decides the outcome (proxy keys + PAC, WinHTTP,
rem       env vars, the package, the store, the ports, who is dialling what);
rem    1. reads the app's OWN evidence - its desktop logs and its live sockets;
rem    2. probes api.deepseek.com on the raw OS route, so an upstream fault is
rem       named as such instead of blamed on this store;
rem    3. repairs by delegating to tools\CodexProxyCache.ps1 (tier 1 `reg load`,
rem       else tier 2 retire the store), closing and reopening Codex so the store
rem       unlocks and is recreated;
rem    4. verifies the store is clean, that the reopened app is no longer dialling
rem       the dead proxy, and that the API answers.
rem
rem  Usage:
rem    fix-codex.bat                diagnose, repair, verify
rem    fix-codex.bat --dry          report only, change nothing
rem    fix-codex.bat --keep-codex   never close Codex (repairs only while it is shut)
rem
rem  No administrator rights needed - the working repair tier lives inside your
rem  own profile. It DOES need Codex closed: Windows holds that store open
rem  exclusively while the app runs, which is why the default closes and reopens
rem  it. Log: state\codex-fix-<stamp>.log, and the store is backed up under
rem  state\codex-helium-<stamp>\ before anything touches it.
rem ===========================================================================
setlocal EnableExtensions
title Codex desktop - repair its connection
cd /d "%~dp0"

set "PS=pwsh"
where pwsh >nul 2>&1 || set "PS=powershell"

rem  Unknown options stop the script: a typo must not silently run the repair.
set "ARGS="
:parse
if "%~1"=="" goto parsed
set "KNOWN="
if /i "%~1"=="--dry"        ( set "ARGS=%ARGS% -DryRun"    & set "KNOWN=1" )
if /i "%~1"=="--keep-codex" ( set "ARGS=%ARGS% -KeepCodex" & set "KNOWN=1" )
if not defined KNOWN (
  echo Unknown option: %~1
  echo Usage: fix-codex.bat [--dry] [--keep-codex]
  echo Nothing was changed.
  exit /b 2
)
shift
goto parse
:parsed

echo.
%PS% -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-codex.ps1" %ARGS%
echo.
timeout /t 12 /nobreak >nul
exit /b 0
