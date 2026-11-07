# Operations

[Documentation index](../README.md) · [Configuration](CONFIGURATION.md) · [Contracts](CONTRACTS.md)

These are operator procedures for an already reviewed deployment. Examples below are instructions, not actions executed by the documentation audit. Run from the repository root; keep Windows commands headless and capture output. Status can write private snapshots. Health checks and activation contact external services; neither is an offline check.

## Deployment prerequisites

A clone or source archive needs separate provisioning: a compatible `runtime/mihomo.exe`, private `runtime/config.yaml`, its rule/provider/data assets, useful upstream credentials, reviewed hardware identities and addressing, and suitable Windows hotspot/ICS hardware. The public template and dummy credentials do not provide those assets.

Use Windows PowerShell 5.1 for WinRT hotspot code and install PowerShell 7 for supervisor/PAC launchers. Review paths before installation: the supervisor contains a machine-specific runtime path; dispatch startup expects a bundled Windows Python under the user cache; optional WSL telemetry has its own distribution and project paths. Reusing this machine's configuration is not hardware provisioning. See [configuration](CONFIGURATION.md).

Only after that review, register startup as the intended interactive user through `autostart-on.bat`; it requests elevation and registers/starts recovery, hotspot and enabled cloud-tunnel tasks. `start-network.bat` ensures the supervisor, requests the registered hotspot task and enables the user proxy. Capture before/after state and application acceptance in an agreed maintenance window.

## Command effects

| Entry point | Effect |
|---|---|
| `start-network.bat --check` | Capture local status; no external HTTPS acceptance probe |
| `start-network.bat` | Start/ensure core helpers, request hotspot task, enable user proxy |
| `repair-network.bat --dry` | Inspect managed adapter/repair state without applying repairs |
| `repair-network.bat` | Targeted names/address reconciliation, supervisor and proxy setup; requests elevation |
| `system-proxy-mode.bat` | Enable user proxy after controller response |
| `autostart-on.bat` / `autostart-off.bat` | Register/start versus disable future launches; see boundaries below |
| `stop-network.bat` | Stop matching toolkit engines/supervisor and disable user proxy |

`start-all.bat` and `stop-all.bat` are aliases. `fixall.bat`, `fix-deepseek.bat` and `reset-network.bat` delegate to targeted repair rather than a global Winsock reset. Standard wrappers accept `--check`, `--dry` and compatibility `--noPause`; the system-proxy wrapper is separate. [Network.ps1](../../tools/Network.ps1) exposes `Start`, `Status`, `Repair`, `Stop`, `AutostartOn`, `AutostartOff` and `-DryRun`; logs go to `state/network-<Action>.log`.

Local snapshot examples (write diagnostic files; no repair):

```powershell
powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -File .\tools\Get-MihomoStatus.ps1
powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -File .\src\hotspot\Hotspot.ps1 -Action status
```

`Hotspot.ps1` also accepts `start`, `stop`, `restart`, `ensure`, `diag`, `watch`; `watch` supports `-IntervalSeconds` (default 15) and `-Minutes` (default 0, indefinite). Do not substitute a lifecycle action for observation on an active session.

## Stop and autostart boundaries

Autostart-off disables future task starts and backs up logon launchers; it does not stop already running processes. Stop matches this project's runtime engine path, including the auxiliary core, but does not necessarily stop its watcher. An enabled watcher may recreate its child. Plan coordinated auxiliary shutdown through its policy/task lifecycle before stopping cores when needed. A hostname/IP host-route tunnel is separate from the Windows user proxy.

Do not stop adapters, clear caches, reload all rules or restart trading/data terminals just because an application is slow. Inspect active owners and actual sockets first. Provider applications retain sole control over request allocation, protected keys and terminal recovery; this toolkit's diagnostics are not request permission.

## Health checks

This command contacts external endpoints and writes evidence:

```powershell
powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -File .\tools\Test-NetworkHealth.ps1 -Quick -Json
```

`-Quick` still sends probes; it skips an extra hotspot-address check. Other options include `-TimeoutSec` (15), `-WarnWindowMin` (15); `-FunctionsOnly` is used by offline tests. Exit codes are 0 healthy, 1 degraded, 2 unhealthy. Read individual checks and timestamps. A 401/403 can establish transport response without authenticated app usability. The curl helper uses `--ssl-no-revoke`, so this is not full certificate-revocation verification.

Recovery markers are accepted only for the same configuration hash, nonfuture time and recorded successful egress/application/sharing evidence. Historical log warnings remain; they are not erased to obtain a healthy verdict. Browser rendering, WebRTC, broker sessions and fresh provider data require their own acceptance.

## Routing changes

First preserve the current private YAML, relevant provider assets, selector state and source policy. Inspect actual ICS ownership and avoid generated provider members that conflict with a reserved shared link. `initialEligible` affects weights, not exclusion. Neither builder validates live throughput or preserves every manual exclusion.

Candidate preparation writes local files only; use an explicit private input and unique output directory:

```powershell
$review = Join-Path .\state ('policy-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $review | Out-Null
$candidate = Join-Path (Resolve-Path $review).Path 'candidate.yaml'
python .\tools\Build-MultiWanConfig.py --input .\runtime\config.yaml --output $candidate
python .\tools\Attest-Config.py .\runtime\config.yaml $candidate
powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -File .\tools\Compare-ConfigPolicy.ps1 -TemplatePath .\runtime\config.yaml -DeployedPath $candidate
```

Review ordered rules, complete group membership, DNS, interface binding, exposure, retained credentials and egress dependency. Offline attestation is value-redacted review metadata; equality of explicit Theta rules is not effective-route proof. The full builder applies the legacy transform then the dispatch overlay. `AdaptiveDispatch.py --input ... --output ...` is the narrower overlay operation. Both require PyYAML; see [development](DEVELOPMENT.md).

Only after authorizing a live change, activation validates with the engine, creates backup/selector sidecar files under `state/jd-handoff/`, starts a 90-second guard and reloads the core:

```powershell
powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\tools\Activate-Mihomo.ps1 -Candidate $candidate
```

The helper sets `LOCAL` to `DISPATCH` and checks Google, Lingoda and model-API transport before marking success. `-PreferWindowsDirect` changes multiple additional groups; it is not a narrow domain edit. Saved selections can outlive member reordering. Reload is intended to retain existing connections but is not a guarantee of session continuity.

## Rollback

Activation error handling restores the prior file and attempts selector restoration. The detached guard restores after timeout only if the current file still has that candidate's expected hash; it refuses to overwrite a later configuration. Marker existence disarms it. Inspect the specific backup, sidecar and guard log rather than assuming every selector restore succeeded.

For later rollback, review the backup against subsequent changes, then pass that specific absolute backup path to `Activate-Mihomo.ps1 -Candidate` without broad preference flags. It creates another backup and runs acceptance again. Restoring old whole-config snapshots can erase newer application rules. A source/Git bundle excludes private deployment state and cannot serve as a runtime rollback.

## Troubleshooting

| Symptom | Evidence and interpretation |
|---|---|
| Core absent or port occupied | Supervisor log, process executable identity and port 7897 owner. A foreign listener suppresses another core launch. |
| Controller responds, app fails | User proxy settings, app proxy behavior, matched rule and actual connection chain; a listener is insufficient. |
| Provider connection disappears | Java-owned source port joined to controller flow, request receipt and both timestamps. Idle, CLOSE-WAIT or no joined flow alone does not prove a stuck terminal. |
| HTTP 472, 503 or other response | Preserve exact receipt/body hash; distinguish application empty/error from transport failure. Data/date/entitlement semantics belong to provider code. |
| One adapter slow | Completed, comparable transfers with errors and times; link speed and a small health response do not measure sustained capacity. |
| Adapter repair deferred | Guard reason, active TCP/UDP, shared hotspot, identity ambiguity and freshness. Deferral may be intentional. |
| Hotspot has no Internet | 5.1 hotspot status, actual shared uplink, DHCP/private address and logs; prefer evidence before requesting restart. |
| PAC unreachable | Port 8080, client-reachable host address, firewall and main proxy exposure. Advertised target is fixed and may not match your topology. |
| Nothing starts before logon | Boot adapter task differs from user logon supervisor/PAC/hotspot tasks. |
| Dispatcher or telemetry stale | Inspect its timestamp/PID/lock; a running main core does not prove a current observer. |

No guaranteed idle retry or passive operation can force a new upstream connection. Failover, reboot and unplug events may interrupt sessions. Scope live recovery to a known owner and maintenance window.

## Evidence locations

| Private path | Producer / interpretation |
|---|---|
| `state/gateway-status.json`, `state/last-boot-report.json` | Status/boot helpers; check capture time and hash |
| `state/status.json` | Dashboard collector snapshot; valid JSON does not imply freshness |
| `state/reboot-tests/`, `state/gateway-logon-runs/`, `state/gateway-hotspot-runs/` | Per-boot traces and startup/task transcripts, not guaranteed current state |
| `state/pac-server.log` | PAC requests and listener/bind errors |
| `runtime/mihomo.log`, `runtime/mihomo-supervisor.log` | Core routing/errors and lifecycle; may contain private destinations |
| `state/network-diagnostics/` | Passive captures and separate periodic external probe results |
| `state/hotspot.log`, `hotspot-state.json`, `hotspot-status.json` | Hotspot lifecycle/sharing snapshots |
| `state/adapter-recovery/` | Guard, stall and recovery decisions |
| `state/adaptive-dispatch/`, `state/native-theta/` | Allocation and passive telemetry; see [contracts](CONTRACTS.md) |
| `state/codex-cloud-tunnel/` | Auxiliary engine routes/config/status; may be stale |
| `state/jd-handoff/` | Private activation backups, selections and guard results |

Do not paste complete private configs, process arguments, provider URLs or raw logs into public documentation.

## Offline cache migration

`etag-support: false` prevents new ETag writes; historical keys can remain in a cache database. [cache-sanitize](../../tools/cache-sanitize/main.go) operates only on an offline snapshot, backs up credential-bearing keys to a new explicit private JSON file, copies other buckets/sequences into a new output, and refuses a held writer lock. It does not replace its input or stop services.

Example, run from `tools/cache-sanitize` with Go installed; all paths must differ and outputs must be new:

```powershell
go run . -input C:\Private\cache-offline.db -output C:\Private\cache-clean.db -credential-backup C:\Private\subscription-credentials.json
```

The backup is sensitive. Verify privacy and restorability before a separately planned cache replacement. Do not operate against an active cache or delete candidate data as documentation validation. The tool does not rotate credentials or upload files.
