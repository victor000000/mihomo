# Development

[Documentation index](../README.md) · [Contributing](../../CONTRIBUTING.md)

A clean checkout supports source checks and offline tests. It is not a complete network installation; [deployment prerequisites](OPERATIONS.md#deployment-prerequisites) are separate.

## Source map

| Location | Responsibility |
|---|---|
| Root `.bat` and `.ps1` files | Stable operator entry points and compatibility wrappers |
| `tools/Network.ps1`, `tools/*Mihomo*.ps1` | Startup, status, repair, registration, and activation |
| `tools/Build-MultiWanConfig.py` | Native adapter and proxy-policy generation |
| `src/NetStack/` | Shared architecture, policy, recovery, state, and repository helpers |
| `src/hotspot/` | Windows WinRT/ICS adapter and testable hotspot lifecycle policy |
| `src/dashboard/`, `web/` | Local dashboard collector, server, and browser code |
| `tests/` | Pester suites, Python policy tests, and offline dashboard tests |
| `runtime/mihomo-supervisor.ps1` | Versioned supervisor inside the otherwise private deployment directory |

`tests/gateway/` retains its historical directory name; it now tests the native Mihomo design. Optional accounting and market-data helpers are separate from the main proxy. The Codex cloud helper runs a second Mihomo engine with narrow host routes; see the [configuration reference](CONFIGURATION.md#codex-cloud-tunnel).

## Dependencies

CI uses Windows PowerShell 5.1 and PowerShell 7, Python 3.12, and Node.js 22. Pester is pinned to 5.5.0 in [Dependencies.psd1](../../tests/Dependencies.psd1); Python packages are pinned in [requirements.txt](../../tests/requirements.txt).

From the repository root, acquire dependencies explicitly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Initialize-TestEnvironment.ps1
python -m pip install -r .\tests\requirements.txt
```

Bootstrap downloads Pester to repo-local `.tools/`; test execution does not install missing dependencies. Windows PowerShell 5.1 is required for the deployed WinRT hotspot code. The supervisor and PAC launchers use PowerShell 7. Match the actual caller when editing scripts; use explicit file encodings, especially for non-ASCII text consumed by 5.1.

## Checks and tests

Run the relevant checks first, then the complete suite before sharing behavioral changes:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Invoke-RepoChecks.ps1 -Quiet
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Invoke-RepoChecks.ps1 -Quiet
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -CI
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -CI
python -m unittest discover -s tests/gateway -p "test_*.py"
node --test tests/web/dashboard.test.cjs
```

The repository audit checks PowerShell syntax, secrets, HTML structure, and control characters. `-Check list` lists active checks; `-Check secrets` or `-Check control` narrows a run. Missing optional tools may soft-skip a check, so inspect the output as well as the exit code.

For focused Pester work, pass `-Path .\tests\gateway` or an individual `*.Tests.ps1` file. Default runs exclude `Machine`-tagged tests; `-IncludeMachine` is an explicit live-machine opt-in. Report discovery/container errors and skips rather than quoting only a passed-test count. XML results are written to `artifacts/test-results/powershell-<engine>.xml`, or the specified `-ResultsPath`.

Documentation-only edits need link/anchor, example, and secret/text checks; they do not require network diagnostics. Live route changes require separate, bounded transport validation, preferably through an isolated engine with distinct ports. Keep real adapters and active sessions out of fault-injection tests.

## Packaging and CI

[CI](../../.github/workflows/ci.yml) runs the two PowerShell engines, Python policy tests, and Node dashboard tests. The PowerShell 7 job also builds and validates an extracted source bundle without the deployed configuration.

```powershell
pwsh -NoProfile -File .\tools\Build-SourceBundle.ps1
```

This writes `artifacts/mihomo-toolkit.zip` with a SHA-256 source manifest. Use `-OutputPath` for a new destination; `-Force` explicitly replaces an existing bundle. Runtime credentials, provider caches, state, downloaded binaries, and local dependencies are excluded. The bundle is source-only.

`tools/Backup-Repo.ps1` instead creates a Git bundle of committed history and refs. It does not back up uncommitted changes or private deployment files, and its retention policy removes older bundles. Deployment rollback is covered in [operations](OPERATIONS.md#rollback).
