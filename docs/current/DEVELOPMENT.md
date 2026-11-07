# Development and CI

[Documentation index](../README.md) · [Contributing](../../CONTRIBUTING.md)

## Source map and platform requirements

Root wrappers preserve operator entry points. `src/NetStack/` owns shared policy/state/recovery helpers; `src/hotspot/` owns WinRT/ICS operations; `src/dashboard/` and `web/` own the local collector/server/UI. `tools/` contains generation, activation, diagnostics and scheduling helpers. `runtime/mihomo-supervisor.ps1` is source; other runtime assets are private deployment inputs.

CI uses Windows PowerShell 5.1 and PowerShell 7, Python 3.12 on Windows/Linux, Node 22, and Go selected from `tools/cache-sanitize/go.mod` (minimum 1.23). PyYAML is pinned in [requirements.txt](../../tests/requirements.txt); Pester is pinned to 5.5.0 in [Dependencies.psd1](../../tests/Dependencies.psd1). Native Windows is required for Pester/WinRT behavior; Linux alone cannot certify it. Passive observer tests depend on Linux `fcntl` and are explicitly skipped on native Windows.

## Dependency bootstrap

Use installed interpreters in a development environment. These commands acquire dependencies; they are distinct from offline test execution:

```powershell
powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\tools\Initialize-TestEnvironment.ps1
python -m venv .tools/python
.\.tools\python\Scripts\python.exe -m pip install -r tests/requirements.txt
```

Activate that virtual environment or use its explicit interpreter for Python commands below. Bootstrap puts exact Pester under `.tools/Modules`; the runner does not silently download it. Do not install dependencies globally or run extracted untrusted source as an installer. Match caller engines and preserve UTF-8/BOM where Windows PowerShell 5.1 requires it.

## Checks and tests

All commands below are offline with dependencies present; tests use fixtures/mocks and temporary files. Run from the root:

```powershell
python tools/Check-Docs.py
powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\tools\Invoke-RepoChecks.ps1 -Quiet
pwsh -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\tools\Invoke-RepoChecks.ps1 -Quiet
powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -CI
pwsh -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -CI
python -m unittest discover -s tests/gateway -p "test_*.py"
node --test tests/web/dashboard.test.cjs
```

Run the Go component from `tools/cache-sanitize`: `go test ./...`. Its first module download requires network; cached dependency execution uses synthetic databases. The sanitizer's CLI help is `go run . -h`; do not substitute a live database to validate it.

Pester excludes `Machine` by default. `-IncludeMachine` explicitly opts into machine-dependent operations and is not part of source CI. Use `-Path` for focused files/directories, `-Verbosity Detailed` for diagnosis and `-ResultsPath` for unique artifacts. The runner rejects missing dependencies, empty discovery, container/setup errors and missing XML. Per-engine results go under `artifacts/test-results/`; do not race two runs targeting the same result path.

Repository audits cover PowerShell syntax, secrets, HTML structure and control characters. Inspect skipped checks and exit status; no gate should be waived just to turn CI green. The [Markdown checker](../../tools/Check-Docs.py) validates inline local links/anchors in root Markdown and `docs/`, excluding fenced examples. It neither fetches external URLs nor checks reference-style links or HTML; review those manually. Its fixture tests are included by Python discovery. `--current-only` explicitly narrows review to root/index/current guides when assessing a native workspace with historical records; it does not replace the all-document default in publication CI.

## Safe configuration examples

The comparison command reads supplied files only:

```powershell
python tools/Attest-Config.py config/mihomo-config.template.yaml config/mihomo-config.template.yaml
python tools/Attest-Config.py --help
python tools/Build-MultiWanConfig.py --help
python tools/AdaptiveDispatch.py --help
```

Do not run `AdaptiveDispatch.py --once` as an offline smoke test: it queries the local controller and can change selectors. Candidate generation writes output files; activation, health checks, startup and repairs belong to [operations](OPERATIONS.md), not documentation checks.

## Packaging and CI

```powershell
pwsh -NoProfile -NonInteractive -WindowStyle Hidden -File .\tools\Build-SourceBundle.ps1
pwsh -NoProfile -NonInteractive -WindowStyle Hidden -File .\tools\Test-SourceBundle.ps1
```

The builder writes `artifacts/mihomo-toolkit.zip`; choose `-OutputPath` for another destination and use `-Force` only to replace an existing artifact intentionally. It includes VERSION and a source SHA-256 manifest. The validator checks version/hashes and required policies, then runs repository audits, Pester, Python and dashboard tests on a unique extracted source tree with no deployment. Python and Node must be discoverable in that Windows shell; Pester is copied from the pinned development install.

[CI](../../.github/workflows/ci.yml) runs both PowerShell engines, Python and Go on Windows/Linux, and dashboard tests; the PowerShell 7 job validates the source archive. It explicitly bootstraps dependencies, uploads result XML and publishes a sanitized source artifact. Repository permissions are read-only. There is no automated deployment/CD target and no live application acceptance test.

`Backup-Repo.ps1` makes a Git bundle of committed refs/history with retention; it does not back up private deployment state or uncommitted edits. Version 0.0.3 is the toolkit version in [VERSION](../../VERSION), independent of the engine. Migration/review scope is in [the release note](RELEASE-0.0.3.md); runtime backup/rollback is in [operations](OPERATIONS.md#rollback).
