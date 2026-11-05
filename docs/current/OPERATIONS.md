# Operations

[Documentation index](../README.md) · [Architecture](ARCHITECTURE.md)

Run commands from the repository root in Windows PowerShell unless another shell is shown. Status commands write local diagnostic files but do not repair networking. Health probes contact external services and consume network traffic.

## Deployment prerequisites

A source clone is not an installer. Before enabling startup, provision:

1. Windows PowerShell 5.1 and PowerShell 7 at `C:\Program Files\PowerShell\7\pwsh.exe`. The current supervisor hardcodes `C:\Users\victo\mihomo\runtime`; review that source path before deploying elsewhere.
2. `runtime/mihomo.exe`, a validated private `runtime/config.yaml`, and its required provider/rule files and data assets. Restore these from the owner's deployment backup or provision them separately. The sanitized template contains placeholders and is not a live replacement.
3. The correct device identities and address policy in [mihomo-adapters.json](../../config/mihomo-adapters.json), and `mode: mihomo` in [network-architecture.json](../../config/network-architecture.json).
4. A Windows user session and hotspot-capable hardware for WinRT/ICS. Run `autostart-on.bat` as the intended interactive user, accepting its elevation request. This installs startup launchers and registers/starts the recovery and hotspot tasks.
5. Run `start-network.bat`, then inspect status and perform a live health check below. Manual start requires the registered `MihomoHotspot` task. The supervisor also maintains the PAC helper headlessly; inspect its log and port 8080 if PAC is unavailable.

Optional: `tools/Install-Metacubexd.ps1` installs the controller UI; `tools/Register-CodexStartup.ps1` registers a network-aware Codex shortcut. Neither is required for routing.

## Daily commands

| Command | Effect |
|---|---|
| `start-network.bat --check` | Capture adapter, listener, task, and route-selection status; no external HTTPS probe |
| `start-network.bat` | Ensure proxy supervisor, request hotspot task, wait for controller, enable user system proxy |
| `repair-network.bat --dry` | Inspect managed adapters and status without applying repairs |
| `repair-network.bat` | Reconcile adapter names/IP settings, ensure supervisor, and enable user proxy; requests elevation |
| `system-proxy-mode.bat` | Enable `127.0.0.1:7897` as user proxy after the controller responds |
| `autostart-on.bat` | Install logon launchers and register/start recovery and hotspot tasks; requests elevation |
| `autostart-off.bat` | Disable future recovery/hotspot/cloud-tunnel task starts and move logon launchers to a backup; running processes continue |
| `stop-network.bat` | Stop this project's supervisor/Mihomo processes and disable user proxy; hotspot and native networking remain |

`start-all.bat` and `stop-all.bat` are compatibility aliases. `fixall.bat`, `fix-deepseek.bat`, and `reset-network.bat` use the targeted repair path. They do not perform a global Winsock reset. Standard action wrappers accept `--check`, `--dry`, and the compatibility `--noPause` flag; `system-proxy-mode.bat` is a separate direct wrapper.

For visible PowerShell output, use `powershell.exe -NoProfile -File .\tools\Network.ps1 -Action Status` (or `Start`, `Repair`, `Stop`, `AutostartOn`, `AutostartOff`). Transcripts go to `state/network-<Action>.log`.

## Current-state caution

Read [handoff and known gaps](HANDOFF.md) before a rebuild or hotspot change. The source hotspot preference and the latest recorded ICS ownership differ. The dated repairs below describe observations at those times, not a fresh health check. `initialEligible` changes starting weights but does not remove provider members; regeneration can undo a manual shared-adapter exclusion.

`autostart-on.bat` also registers and starts the cloud-tunnel task when its policy is enabled. `stop-network.bat` matches all engines at this project's `runtime/mihomo.exe` path, including the auxiliary engine, but does not stop its watcher task; that watcher can restart its child. For an intentional cloud-tunnel shutdown, disable its policy and allow the watcher to exit first. Autostart-off disables future task starts and does not stop running tasks.

## Health checks

### Codex cloud and hotspot repair, 2026-10-30

HypoMux prefers `jd_5G` for client speed. A direct 8 MiB download on that link
measured 39–42 Mbps versus 12.8 Mbps on `pisen_2026_03`; these are upstream
samples, not a client Wi-Fi benchmark. Sharing blocks the public adapter's
interface-bound proxy paths, so Codex and the base proxy servers prefer
`pisen_2026_03`, then the October Pisen and iPhone. `PROXY-UPLINK` supplies stable
transport independently of general direct-traffic dispatch. The dispatch
policy's `proxyUplinkOrder` preserves that choice across configuration rebuilds.
While ICS shares an adapter, keep that adapter out of `initialEligible` and last
in `proxyUplinkOrder`: its interface-bound proxy paths fail, but the group probe
does not apply the binding and still reports it alive, so a fallback or a
capacity controller will otherwise keep selecting it.

Windows DNS uses Mihomo at `127.0.0.1`. Before repair, Windows returned
`173.252.108.3` for `codex-cloud-backend.chatgpt.com`, while Mihomo's resolver
returned its Cloudflare addresses. Correct DNS alone did not fix direct TLS.
The Codex log confirmed its cloud WebSocket connected after the targeted tunnel
started. No app restart or credential changes were needed.

`MihomoCodexCloudTunnel` is a hidden, elevated logon task running
`tools/Watch-CodexCloudTunnel.ps1`. It refreshes only the backend's public IPv4
and IPv6 **host routes** through the `CodexCloud` adapter every 60 seconds and
keeps the current tunnel on transient resolution errors. It uses the main
engine's loopback listener `19989`, pinned to `CHATGPT`; it stores no duplicate
server credentials. The auxiliary controller is loopback-only on `19997`.
Default routes and DNS hijacking are not enabled for this auxiliary tunnel.

Inspect `state/codex-cloud-tunnel/status.json`, `watch.log`, and `engine.log` and
`Get-ScheduledTask -TaskName MihomoCodexCloudTunnel`. To stop this tunnel, set
`enabled` to `false` in `config/codex-cloud-tunnel.json`; the task exits after
its next poll and stops its child engine. To restore it, set `enabled` to
`true` and start the task. Task registration lives in
`tools/Register-CodexCloudTunnel.ps1` and requires elevation.

Receipts and the pre-change configuration/DNS snapshots are under
`state/codex-repair-20261030/`. The initial `hy2-upstream` failures were repaired later the same morning;
see the Pisen/Hysteria repair below. Hysteria remains available in BENCH without
changing the normal VLESS/Codex selections. A shared adapter's
failed bound path is a role constraint, not proof of modem failure.

Adapter recovery records the shared link as `hotspot-uplink`; it does not
require that adapter to pass an interface-bound proxy test or restart it for
that expected limitation. Modern Mobile Hotspot sharing is recognized using
its saved uplink and the live private address/DHCP listener as well as classic
HNetShare state. Other failed proxy paths remain visible.

Health checks can distinguish failures before a verified recovery from new
errors. `state/network-recovery/verified.json` is accepted only for the same
configuration hash, a nonfuture timestamp, and recorded successful external,
Codex, and sharing checks. The report retains the historical warning count;
new errors still affect its verdict. No log is cleared. A full live run after
recovery reported 26 checks passing with no warnings or failures.

```powershell
powershell.exe -NoProfile -File .\tools\Get-MihomoStatus.ps1
powershell.exe -NoProfile -File .\tools\Test-NetworkHealth.ps1 -Quick -Json
powershell.exe -NoProfile -File .\src\hotspot\Hotspot.ps1 status
```

The health script returns **0** for `HEALTHY`, **1** for `DEGRADED`, and **2** for `UNHEALTHY`. Read individual checks: accumulated warnings can fail the report while fresh requests succeed. `-Quick` still runs external probes; it skips an extra hotspot-address check. HTTP 401/403 may establish transport reachability without establishing authenticated application access. The helper also uses curl's `--ssl-no-revoke`, so it is not a complete certificate-revocation check.

For Lingoda, use the [diagnostics page](https://class.lingoda.com/en/diagnostics) to check camera, microphone, and media. The generic health script probes the account page, not a live class. HTTP/script downloads alone do not validate WebRTC quality.

## Routing changes

Use the current private deployment as input. The builder regenerates native nodes, pools, and provider replicas; it is broader than a single domain-rule edit. It reads the legacy `standbyAdapters` policy, then applies `config/dispatch-policy.json` for managed regions. See [dispatch and optimization logs](DISPATCH.md) for weights, feedback limits, and rollback. Inspect the candidate before activation and retain provider caches.

```powershell
$changeDir = Join-Path .\state ('policy-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $changeDir | Out-Null
$candidate = Join-Path (Resolve-Path $changeDir).Path 'candidate.yaml'
python .\tools\Build-MultiWanConfig.py --input .\runtime\config.yaml --output $candidate
powershell.exe -NoProfile -File .\tools\Compare-ConfigPolicy.ps1 -TemplatePath .\runtime\config.yaml -DeployedPath $candidate
```

The comparison summarizes policy differences without dumping credentials; it is not engine validation or a throughput test. Review ordered rules, group membership, DNS, and interface bindings. In particular, compare the currently shared ICS adapter with every generated provider payload and `PROXY-UPLINK` member; `initialEligible` is not an exclusion list. Preserve reviewed live exclusions before activating a regenerated candidate. Measure route candidates with an isolated engine on unused ports when changing transport choices.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Activate-Mihomo.ps1 -Candidate $candidate
```

Activation validates with Mihomo, saves configuration and selections under `state/jd-handoff/`, starts a 90-second rollback guard, and reloads the existing engine. It sets `LOCAL` to `DISPATCH`, then checks Google, Lingoda, and model-API transport before marking success. Reload is intended to retain existing connections; a failed upstream can still require application reconnection.

**`-PreferWindowsDirect` changes multiple application selections.** It selects the phone for `DISPATCH`, Tokyo for several services, pools for general groups, and the first configured `WAN-*` member for Lingoda/Zoom when present. Use it only when those broader changes are intended. A changed group order may retain an older saved selection; inspect the controller's `now` field and explicitly select the intended member when needed.

For example, after reviewing that `WAN-jd_5G` is a valid member:

```powershell
Invoke-RestMethod -Uri 'http://127.0.0.1:9097/proxies/LINGODA' |
    Select-Object name, type, now, all
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:9097/proxies/LINGODA' `
    -ContentType 'application/json' -Body '{"name":"WAN-jd_5G"}'
```

Confirm the effective selections and test the affected application after reload. Keep live configuration, candidate files, and selection backups private.

Alpaca domains use the dedicated `ALPACA` group, preferring direct `jd_5G`, then `pisen_2026_03`, LA, and the phone. Its health check requests the Alpaca homepage every 60 seconds and requires HTTP 200. This policy covers `alpaca.markets` and its subdomains for applications using Mihomo. On 2026-10-24 the live homepage probe improved from 4.29 seconds to 1.18 seconds. Large app JavaScript downloads remained inconsistent: one direct probe completed in 12.05 seconds, but the final live probe timed out after 45 seconds. Authenticated app behavior was not tested.

The browser portal at `www.ibkr.com.cn` has an earlier exact-domain rule for `IBKR-PORTAL`. It prefers `jd_5G`, then `pisen_2026_03`, the phone, and LA, checking the actual portal every 60 seconds. On 2026-10-24 its 556 KB common script downloaded in 1.12 seconds through the live proxy after this change; the prior phone path timed out after 20 seconds with a partial download. Authenticated portal behavior was not tested.

Thinkorswim (`TOS`) compares direct adapter paths automatically. IBKR TWS (`TWS`, including `tws1.exe` and the Java installation under `C:\Jts`) compares all four direct adapters plus Tokyo and LA proxy paths for its proxied web traffic, with a 100 ms switching tolerance. Its native trading connections bypass these proxy groups; measure their actual destination and ports separately before changing Windows routes. The phone passed repeated Schwab and IBKR endpoint probes; `pisen_2026_10` was less consistent on the IBKR website. Their named desktop processes and the `thinkorswim.com`, `schwab.com`, `interactivebrokers.com`, `ibkr.com`, and `ibkr.com.cn` domain families match before general rules. Direct `jd_5G` access timed out on the Schwab gateway and IBKR website during verification. TOS checks the Schwab gateway every 30 seconds across all four managed adapters, with an 80 ms tolerance to reduce switching. Futubull (`FUTU-DIRECT` and `FUTU-API`) also compares the four direct adapters every 30 seconds; its executable-path rule includes the FTNN renderers and helpers. A process-path wildcard also covers its embedded browser and helpers. With TUN disabled, native connections that bypass Mihomo follow Windows routing; verify login and live data in each desktop app after a change.

The US visa portal uses the dedicated `USVISA` selector for `usvisascheduling.com` and `ustraveldocs.com`. On 2026-10-27 Cloudflare returned its "Sorry, you have been blocked" page for the portal through the `pisen_2026_10` address and through the Aliyun Tokyo and Los Angeles exits, while `WAN-jd_5G`, `WAN-win_turbo_phone`, and `WAN-pisen_2026_03` served the managed challenge instead; the selector defaults to `WAN-jd_5G`. HTTP 403 with `Cf-Mitigated: challenge` proves only that the edge answered — the challenge itself is solved in the browser, and an automated Chrome never completed it on any tested path, so only an interactive browser confirms access. If the portal blocks the current member again, switch to another `USVISA` member instead of rebuilding the dispatch policy. `www.ustraveldocs.com` answered 200 through the same route, and the DNS pin to `172.64.146.157` stays in place. The pre-change policy is `state/usvisa-20261027/rollback-before.yaml`.

## Rollback

Activation errors restore the previous configuration and attempt to restore saved selections. The guard restores only if the live file still matches that activation's candidate hash; it refuses to overwrite a later change. Inspect `state/jd-handoff/` validation, commit, and guard logs rather than assuming rollback succeeded.

For a later rollback, select the **specific backup printed by that activation** and pass its absolute path to `Activate-Mihomo.ps1 -Candidate`, without `-PreferWindowsDirect`. Review it for changes made since the backup. This performs validation and creates a new backup of the current state. Reloading the YAML does not guarantee restoration of manual selections: consult the matching `.yaml.selections.json` sidecar and restore the affected groups through the controller, then repeat health/application checks.

A Git/source bundle does not contain the private runtime configuration or provider caches. Keep a separate deployment backup; do not use the sanitized template as rollback material.

## Troubleshooting

| Symptom | Check and next action |
|---|---|
| Proxy does not start | Inspect `runtime/mihomo-supervisor.log`, startup transcript, runtime files, and the owner of port 7897. A foreign listener suppresses supervisor startup. |
| API works but browsing fails | Check user `ProxyEnable`/`ProxyServer`, actual application proxy use, selected group, and health results. A listener alone proves no upstream connectivity. |
| One application is slow | Check its matched rule and selected route; compare complete downloads and errors across direct/proxy paths. A small-page delay test can miss slow sustained transfers. |
| Adapter is `Up` but marked degraded | Inspect `ProxyHealth` and `stall-state.json`. Link state and Internet reachability are separate. Recovery may intentionally preserve active sessions or the hotspot. |
| Device is absent or ambiguous | Check recorded hardware identity in the adapter map. Resolve collisions/identity mismatch before repair; do not infer identity from a reused display name. |
| Hotspot joins but has no Internet | Run the 5.1 hotspot `status` command; inspect ICS address, DHCP/sharing state, and hotspot logs. `Start-ScheduledTask -TaskName MihomoHotspot` requests recovery and may restart an unhealthy hotspot. |
| Hotspot client is slow | Read the `uplink:` line: ICS shares one link, and private-side traffic that ignores the PAC cannot use the other adapters. `Hotspot.ps1 watch -Minutes 10` records `traffic:` rates and `proxy:` chains. Sharing an adapter through ICS also disables mihomo's interface-bound path on it, so moving the hotspot reallocates proxy capacity — see [the WeChat hotspot measurements](../tasks/WECHAT-HOTSPOT-SPEEDUP.md). |
| Hotspot works but PAC does not | Check port 8080 and `/proxy.pac`. Its current proxy target is `192.168.137.1:7897`; verify the client's reachable Windows address. A topology change needs a reviewed PAC change or explicit proxy setting. |
| Nothing starts before login | Only adapter recovery is boot-triggered. Proxy, PAC, and hotspot startup require user logon. |

Existing sessions cannot survive a Windows reboot. Use a planned idle period for physical unplug/replug or reboot validation; see [pending checks](../verification/2026-10-21.md#remaining-validation).

## Logs and evidence

| Path | Contents |
|---|---|
| `state/gateway-status.json` | Latest local status snapshot |
| `runtime/mihomo.log`, `runtime/mihomo-supervisor.log` | Proxy errors, launches, and retry history |
| `state/gateway-logon-runs/` | Proxy startup transcripts and errors |
| `state/gateway-hotspot-runs/`, `state/hotspot.log` | Hotspot task results; lifecycle, uplink, client join/leave, `traffic:`, `proxy:` chain and `wlan:` evidence (rotated at 4 MiB to `hotspot.log.1`) |
| `state/adapter-recovery/status.json`, `events.log`, `stall-state.json` | Reconciliation, per-adapter proxy reachability, and restart decisions |
| `state/pac-server.log` | PAC requests and bind failures |
| `state/reboot-tests/<Windows-boot-time>/` | Rotating per-process JSONL traces plus `boot-report*.json` / `boot-report*.txt` |
| `state/last-boot-report.json` | Most recent boot report, including the runtime config hash and the previous report for comparison |
| `state/network-diagnostics/latest.json`, `latest.txt`, `latest-probes.txt` | Latest passive sample, its one-screen summary, and the last HTTP probe verdict |
| `state/network-diagnostics/observer.log` | Observer lock contention and loop errors (the observer no longer exits silently) |
| `state/gateway-observations/` | Boot observer snapshots, HTTPS checks, and hotspot/PAC results |
| `state/jd-handoff/` | Activation backups, saved selections, validation, and guard results |

The boot observer takes eight samples, with 30-second gaps plus probe time. Log names containing `gateway` are retained paths, not evidence of an OMR dependency. Dated measurements belong in [verification notes](../verification/2026-10-21.md), not this runbook.

### Additional diagnostic evidence (2026-10-26)

Every `tools/Test-NetworkHealth.ps1` run saves its timestamp, verdict, probe HTTP codes/timings, and adapter results under `state/network-health/` (latest 60 reports). HTTP 401/403 proves an HTTP response, not authenticated application access. Phone adapters are matched by MAC, interface GUID, or managed adapter name, so a changed phone MAC does not falsely report a missing link.

Boot snapshots now include per-section collection times, runtime config SHA-256, IPv4 interface metrics, configured versus observed adapter identities, and application proxy selections. Compare `InterfaceMetric` with `DefaultRoutes.RouteMetric` when investigating route preference. Config contents and credentials are not copied.

On its next start, the adapter watcher also records `proxy-health-change` events in its existing rotating per-boot JSONL trace: initial state, per-adapter reachability changes, and controller errors/recovery. These are based on recent engine probe history, not a guarantee that every application works. Snapshot additions take effect on the next snapshot invocation; existing running processes are not restarted for logging changes.

### Continuous incident diagnostics (2026-10-27)

`tools/Watch-NetworkDiagnostics.ps1` runs hidden under PowerShell 7 from the logon launcher. It also supports `-Once` for a bounded capture. A file lock prevents duplicate observers. Every minute it records controller availability, selected proxy chains, node health with probe timestamps, IPv4 default routes and interface metrics, user proxy settings, and the runtime config hash. Every five minutes it requests Google, OpenAI, Gmail, and Baidu through port 7897, recording HTTP status, curl exit/error, and DNS/connect/TLS/first-byte/total timing. Each request has an eight-second limit. HTTP 401/403 indicates transport reachability, not authenticated access; probe timestamps expose stale controller health. Curl DNS/connect timings describe the local proxy connection; they do not isolate upstream DNS or TCP delay. The loop interval follows collection, so slow probes can lengthen the gap.

The latest passive sample is `state/network-diagnostics/latest.json`. Historical `network-sample`, `selection-change`, and `http-probe` events are in `state/reboot-tests/<boot>/network-diagnostics-*.jsonl`, rotated at 4 MiB with one previous file per process. Previous boot directories remain available. Response bodies and configuration credentials are not logged. Load-balanced groups have no single selected member; correlate their member health with the actual connection path in `runtime/mihomo.log`. This observer does not repair networking or change selections.

### Post-reboot report (2026-10-28)

`tools/Write-BootReport.ps1` writes one JSON and one text file per run. It records the boot time and uptime, the user and elevation state, running mihomo/supervisor/PAC/observer processes with PIDs, listeners on 7897/9097/8080, the controller version and `/configs` values, managed and configured adapter identity, IPv4 addresses, interface metrics and default routes, DNS servers with live lookups, the user proxy registry values, PAC response, ICS/hotspot service and task state, logon launchers and task history, runtime file hashes, and — with `-Probe` — proxied and direct HTTP results. Its computed `VERDICT` and `Warnings` list name the broken component instead of leaving that to inference:

```powershell
pwsh -NoProfile -File .\tools\Write-BootReport.ps1 -Probe
pwsh -NoProfile -File .\tools\Write-BootReport.ps1 -Probe -DelaySeconds 45 -Label logon
```

At logon, `tools/Mihomo-Startup.ps1` runs it twice: `boot-report-logon.*` about 45 seconds after logon (with probes) and `boot-report-steady.*` five minutes later. Each run also updates `state/last-boot-report.json`, and the report notes when the runtime config hash changed since the previous report.

`runtime/mihomo-supervisor.ps1` now keeps the two sidecars alive: if port 8080 has no listener it restarts `tools/Serve-Pac.ps1`, and if no `Watch-NetworkDiagnostics.ps1` process exists it restarts the observer (at most once per two minutes). It also logs a once-per-minute controller check, the mihomo binary version, the mihomo output line count on exit, and a warning when port 7897 is held by a process that is not mihomo. A dead observer therefore shows up as a `helper state:` line instead of a silent gap.

`Watch-NetworkDiagnostics.ps1` now records helper PIDs, listeners, PAC status, ICS/hotspot state, managed adapter link state with addresses, and two live DNS lookups in every sample, and catches per-iteration errors (`observer.log`, `loop-error` trace events) instead of terminating. When its first sample runs and the logon boot report is missing, it writes one itself (`boot-report.json`).

## Pisen 10 and Aliyun Hysteria repair — 2026-10-30

Pisen 10's modem path accepts a 1372-byte IPv4 ICMP payload but rejects 1373
bytes with fragmentation required. Its Windows IPv4 MTU is now 1400 (including
28 bytes of IP/ICMP headers), saved in ActiveStore and PersistentStore.
`config/mihomo-adapters.json` also records `ipv4Mtu: 1400`; adapter recovery
reconciles it only behind the existing stable-idle guard. IPv6 MTU is unchanged.
Two complete 8 MiB direct downloads measured 11.4 and 12.8 Mbps after repair;
two 2 MiB uploads measured 1.62 and 1.48 Mbps. Rates are observations, not limits.

Both Aliyun servers use SSH port 65222. Verified Windows SSH aliases are
`aliyun-la` (192.0.2.10, saved aliyun_la identity) and `aliyun-tokyo`
(192.0.2.11, saved id_ed25519 identity). Their host keys were obtained through
the authenticated Cloud Assistant API and pinned in `.ssh/aliyun_known_hosts`.
Do not use the obsolete port 22 in the older server note.

The Los Angeles server had no Hysteria service and its OMR firewall rejected
UDP 443. Hysteria 2 v2.13.0 was installed from the official release with its
SHA-256 digest verified, using the existing client password and SNI. Its
`hysteria-server.service` runs as the dedicated `hysteria` user, is enabled at
boot, and restarts on failure. The configuration and certificate live in
`/etc/hysteria/`; `ignoreClientBandwidth: true` uses adaptive congestion control
instead of the client's old fixed 200 Mbps setting.

`/etc/nftables/custom.d/90-hysteria.nft` contains exactly two UDP 443 rules:
one keeps those packets on the server rather than an OMR DNAT destination;
the other accepts them in the supported custom chain. Both are persistent
across OMR updates. The existing Aliyun cloud UDP 443 rule already allowed
access, so no cloud firewall change was needed. No VLESS service was restarted.
The server-side pre-change firewall snapshot is under
`/root/codex-network-backup-20261030/`.

Local receipts are in `state/pisen-hy2-20261030/`. All 46 connectivity probes
passed after repair: the 17 configured adapter/proxy nodes plus six Hysteria
transport variants, each checked against two endpoints. A SOCKS5 UDP DNS query
through Hysteria also returned two answers. Hysteria's live production delay
probe returned 270 ms. For rollback, restore Pisen's prior IPv4 MTU of 1500;
for Hysteria, disable its service and remove only its named custom firewall
rules/file, leaving OMR and VLESS running.

### After adapter relocation later on 2026-10-30

Receipts in `state/slow-links-20261030/` distinguish remaining cellular/path
slowdown from the earlier fixed MTU fault. Pisen 10 retained its valid 1400
IPv4 MTU; a dormant state after logical refresh required a targeted PnP
restart. Final complete 1 MiB transfers measured 2.95 Mbps direct and 2.67 Mbps
through Tokyo. The iPhone remained slow over IPv4, IPv6 and multiple proxy
protocols. An experimental 1450 IPv4 MTU did not help and was reverted to
1500. Its configured manual metric 20 was restored. Neither finding proves a
particular cellular fault, and the earlier peak speeds were not restored.

Five dispatch body-rate priors were recalibrated from two completed equal
512 KiB samples per path; incomplete paths retained previous priors. The
controller loads the policy automatically and applies its normal gradual
rebalance rules. This reduces the slower iPhone's traffic share without
misrepresenting its link as repaired. The prior policy is saved as
`state/slow-links-20261030/dispatch-policy-before.json`. Recalibrate again after
substantial placement or carrier-condition changes. Recent warning history
was retained; explicit final upstream probes passed despite the historical
warning-volume health failure.

### 2026-10-30 adapter relocation follow-up

All four adapters were rechecked after relocation. Pisen 10 completed domestic
8 MiB downloads at 11.77–12.17 Mbps, versus 1.43 Mbps on the direct overseas
sample. Its Tokyo Hysteria path completed repeated overseas downloads at
8.38–9.56 Mbps; after activation, two further runs completed at 8.49/8.14 Mbps.
The persistent Tokyo Hysteria service uses UDP 443, with targeted nftables
accept/DNAT-bypass rules and the existing cloud firewall allowance.

`dispatch-policy.json` now maps `BALANCED-pisen_2026_10` to `hy2-tokyo` and
`LA-win_turbo_phone` to `hy2-upstream`, preserving each physical interface and
regional identity. Tokyo iPhone is a standby path while ordinary Tokyo paths
are healthy. The controller and rebuild pipeline preserve these choices.

The iPhone is improved only on some paths, not fully restored. A same-server
comparison measured LA TCP at 0.388 Mbps versus Hysteria at 6.14–12.96 Mbps.
Server TCP diagnostics showed substantial retransmitted bytes during the slow
transfer; this does not locate loss to a particular carrier/radio segment.
Final overseas Hysteria retests varied from a completed 3.95 Mbps transfer to
0.94 Mbps with a timeout. IPv4 MTU trials did not improve it and were reverted
to 1500. Pisen 10 retains its verified 1400-byte MTU. Do not describe USB link
speeds or isolated peaks as restored sustained Internet capacity.

Evidence: `state/relocation-20261030-1148/`, including direct, domestic,
controlled, QUIC comparison and final speed receipts. Activation passed Google
204, Lingoda 200 and OpenAI 401 connectivity checks. The 31 adaptive dispatch
tests passed, including transport preservation and standby fallback behavior.

## Credential-free database caches

Keep `etag-support: false` in every Mihomo configuration. Mihomo's ETag cache uses complete provider URLs as database keys, so a subscription token can otherwise persist in `runtime/cache.db`. The main configuration generators and cloud tunnel generator now force ETag caching off, even when input configuration enables it. Credentials belong in ignored private YAML/JSON files or environment variables, backed up only to an owner-private Drive folder.

The toolkit does not use SQLite or another database as a credential fallback. Mihomo's cache may still contain historical URLs from an older deployment. Disabling ETag support prevents future ETag writes; it does **not** erase existing entries.

Use `tools/cache-sanitize` only on an offline cache snapshot. It backs up credential-bearing ETag keys to an explicitly named private JSON file before creating a clean output database. It copies every other bucket and sequence, checks the new database, and never modifies or replaces its input. Its bounded database lock refuses an active writer. The new file has no old free pages carrying deleted URL bytes.

```powershell
# Run from tools/cache-sanitize with Go installed. All three paths must differ.
go run . -input C:\Private\cache-offline.db -output C:\Private\cache-clean.db -credential-backup C:\Private\subscription-credentials.json
```

Verify the credential backup is private and restoreable before removing the original cache. Stop or pause the supervisor and cache-owning core in an agreed maintenance window; verify no process owns the database and the original file still matches the audited snapshot. Only then replace it with the verified clean output. Do not overwrite an active cache or casually restart a proxy carrying downloads. Remove the sensitive offline database snapshot once its extracted credentials are safely backed up. The sanitizer does not stop services, alter live settings, rotate credentials, or upload files.
