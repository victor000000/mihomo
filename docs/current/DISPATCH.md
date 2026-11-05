# Dispatch policy and optimization logs

The active overlay is [dispatch-policy.json](../../config/dispatch-policy.json).
It changes general Mihomo traffic. Windows/WSL native routing, broker-specific
groups, Theta's native Java connection, and localhost bypass remain separate.

## Current algorithm

The `interfaceBindings` policy maps stable logical slots to physical Windows
adapter names. Since 2026-10-30, `win_turbo_phone` binds to `iPhone 17 pro max`;
existing `WAN-`, `BALANCED-`, `LA-` and adaptive path names stay compatible with
saved application selections. The hardware map records the iPhone's identity
and `proxySlot` for recovery health checks. Apply the narrow dispatch overlay
after changing this mapping; editing the JSON alone does not reload Mihomo.

October 30 iPhone receipts and rollback inputs are under
`state/iphone-20261030/`. An 8 MiB direct download measured 25.2 Mbps and a 2 MiB
upload measured 7.3 Mbps, but another direct download timed out with partial
data. The iPhone's isolated Tokyo download measured 17.5 Mbps versus 29.0 Mbps
on `jd_5G`; these are endpoint samples, not sustained line capacities. Windows
uses explicit interface metrics 10/20/30/40 for `jd_5G`, the iPhone,
`pisen_2026_03`, and `pisen_2026_10`, respectively. Default-route metrics
0/5/10/30 give effective priorities 10/25/40/70 in both IPv4 and IPv6; recovery
reconciles those settings only through its stable-idle guard. The absent
phone's slot now contributes the iPhone to Mihomo;
failed paths retain health checks and fallback eligibility. The older Pisen
failed the Cloudflare and Tokyo/LA probes, though its domestic WAN health can
recover independently. Updated priors use only paths with two complete equal
512 KiB transfers; incomplete probes never become capacity estimates.

The subsequent alternating direct retest (`retest.json`) completed all three
8 MiB downloads and both 2 MiB uploads on `jd_5G`, with medians of 41.7 Mbps
down and 6.5 Mbps up. All five iPhone attempts reached the 20-second timeout;
partial downloads averaged 0.56–0.98 Mbps. Both adapters remained connected.
This supports the current Windows priority, not a hardware ranking or a
diagnosis of signal, carrier, or tethering limits. A live 8 MiB transfer through
the production Mihomo proxy completed at 45.7 Mbps; no matched baseline was
recorded, so it does not establish a percentage improvement.

- `TOKYO-ACTIVE` rotates new proxy connections across 24 weighted slots. A smooth
  slot order avoids assigning each adapter a contiguous burst. Connections keep
  their selected path; the remote Tokyo exit remains the same.
- `WAN-ACTIVE`, reached through `DISPATCH`, uses destination hashing over weighted
  slots so ordinary direct proxy requests to the same destination remain sticky.
- `AUTO` and `DATA` prefer Tokyo, with LA fallback. The October 26 bounded
  comparison did not establish a benefit from expanding LA, so its previous
  two-path rotation is retained.
- The legacy `PAID` group is removed. Its former rule and group references use
  `AUTO`. An existing local rule cache can still be named `autolearn-paid` for
  compatibility; it routes through `AUTO` and is not a subscription provider.
- Each managed region has one inline provider containing four adapter-bound
  paths, with shared 30-second health checks. Fallback slots reference that
  provider; they do not each create four separate probe loops. Parent-group
  checks and existing application-group checks are additional checks.

For eligible paths, the target share is
`0.5 / healthy_path_count + 0.5 * capacity_prior / sum(capacity_priors)`.
The controller rounds this to 24 slots. With four healthy paths, the unrounded
shares are bounded between 12.5% and 62.5%. These are scheduling shares, not
guaranteed byte shares or guaranteed physical line capacity.

The priors came from two bounded 512 KiB public HTTP transfers per path, using
the body transfer interval. Their receipts are in the private deployment at
`state/dispatch-upgrade-20261026/capacity-probes.json`. These small samples are
calibration inputs, not a sustained bandwidth certification.

The local controller polls Mihomo every 10 seconds. Failed or stale health
samples remove a path from the target allocation; recovery requires two distinct
fresh successful samples spanning at least ten seconds. Routine changes move at most one slot, about 4.17%,
per region per five minutes. Removing failed paths can move more slots at once.
Stable recovery also restores a path's bounded share without waiting through
many routine adjustment periods, preventing recovery starvation. If all paths
fail, the controller leaves native fallback behavior in place and
records that state. It never closes connections or restarts adapters.

The capacity priors do **not** change in response to polled throughput or idle
connection counts. Passive traffic depends on application demand and existing
allocation; it cannot identify client backpressure or the final bytes of every
short flow. Those observations are recorded for subsequent analysis.

`regionalStability` adds hysteresis to `AUTO` and `DATA`. Tokyo must have at least
two healthy paths, three fresh observations, and 60 seconds of stability before
promotion. A Tokyo failure holds the healthy LA backup for 180 seconds after the
last failure. If only one region is available, it can be used immediately. The
controller records `regional_selection` reasons and owns only its own pins.
Disabling the guard releases an owned preference only if it has not subsequently
been changed manually. Health stability does not certify throughput.

## What was learned from HypoMux

The inspected local source is under `state/hypomux-learn/HypoMux-main/`:

- `engine/internal/proxy/scheduler.go`: health-constrained candidates and smooth
  weighted rotation.
- `engine/internal/proxy/adaptive_allocation.go`: bounded shares, conservative
  step sizes, sufficient-demand requirements, and a throughput-regression guard.
- `engine/internal/proxy/adaptive.go`: full flow lifecycle accounting and client
  backpressure observations, which the Mihomo controller API does not provide.
- `docs/architecture/adaptive-scheduling-implementation.md`: the rate/load
  heuristic's real regression and the distinction between implementation tests,
  simulated gains, and an actual throughput comparison.

This implementation uses those design lessons with Mihomo's existing groups and
controller API. It does not run HypoMux or claim to reproduce its packet path or
its complete feedback controller. Automatic throughput learning remains off.
Enabling it later requires independently validated demand, fresh flow turnover,
backpressure handling, and a regression/cooldown test; changing a score formula
alone is insufficient.

## Logs and status

| Local deployment file | Contents |
|---|---|
| `state/adaptive-dispatch/status.json` | Current allocation, target weights, health/recovery, observed rates and effective mode |
| `state/adaptive-dispatch/dispatch.jsonl` | 30-second metric samples, controller lifecycle, health-driven changes, errors, and observed flow ends |
| `state/adaptive-dispatch/daily-YYYY-MM-DD.json` | Small UTC daily rollups of observed bytes, flows, and latest allocations; the most recent 30 daily files are retained |
| `state/native-theta/status.json`, `telemetry.jsonl` | Passive WSL Java/TCP counters, CPU, and newly completed Theta receipt summaries; no market-data requests |
| `state/dispatch-upgrade-20261026/comparison.json` | Counterbalanced before/after public download receipts |

The JSONL log rotates at 5 MiB, keeping five backups: about 30 MiB total. It
records path labels, counters, latency, fresh sample timestamps, capacity priors,
and reasons. Flow identifiers are salted opaque tokens. Destinations, source
addresses, process paths, payloads, credentials and raw connection IDs are not
written. `newly_observed_flows` and `ended_observed_flows` describe polling
observations, not a complete ledger. Byte deltas are lower bounds; a short flow
can start and end between polls, and its final counter can be missed.

Use `observed_mbps` to describe observed delivery, not link capacity. For a
future tuning comparison, keep the download source, bytes, concurrency, and
network conditions comparable; counterbalance test order and retain errors and
tail completion times. Record old/new policy hashes. Theta market-data requests
require their separate allocation ledger and must not be replayed as a speed test.

The Theta observer runs in the configured WSL distribution and scopes Java
processes to the data-provider project's terminal installation. It samples TCP
and process counters once per second, logs every five seconds, and mirrors its
latest status to the data-provider project's
`runtime/var/maintenance/theta-network-observer/latest.json`. The dispatcher
includes that status in its samples; a sample older than 30 seconds is marked
stale rather than interpreted as zero throughput. No packet payloads, command
lines, request parameters, credentials, raw socket identifiers, or raw peer
addresses are logged. CPU percentages are relative to one CPU core. TLS byte
counters include protocol overhead and can miss sockets that close between polls;
they are not CSV throughput. Existing receipts are not counted as new downloads.
The observer does not change routes, restart the terminal, acquire the history
lock, or issue data/entitlement requests. Idle samples cannot establish capacity.

## Startup, changes, and rollback

[Start-AdaptiveDispatch.ps1](../../tools/Start-AdaptiveDispatch.ps1) launches the
controller headlessly using the bundled Windows Python runtime. It uses only
the Python standard library at runtime. The proxy supervisor ensures it is
running, and manual network startup also calls the launcher. A process lock
prevents two controllers from owning the same state directory. If the runtime
is absent, static weights and Mihomo's own provider health/fallbacks still exist.

The launcher also starts [the passive Theta observer](../../tools/ObserveThetaNetwork.py)
headlessly through WSL when `nativeThetaObserver.enabled` is true. An independent
file lock prevents duplicate observers. Its log rotates at 5 MiB with three
backups. Disabling the observer option prevents future launches; a running
observer must be stopped separately. It does not change ingestion concurrency.

The legacy multi-WAN builder applies this overlay last when the dispatch policy
file exists. The overlay only changes managed general groups and its own inline
providers; it does not replace application rules or broker selections. Internal
providers are excluded from the legacy builder's subscription alternatives.

To stop the controller, set `enabled` to `false` in the dispatch policy. It exits
after the next poll; this does not remove the deployed static groups. A complete
rollback requires reviewing and activating the specific pre-upgrade configuration
backup and restoring its saved selections. The October 26 initial backup is
`state/jd-handoff/before-handoff-20261026-070334-553-37164.yaml`, with its matching
`.selections.json` sidecar. Do not overwrite later application policy changes
with an old backup without reviewing them.

Once a prior is deliberately revised, the running controller reads it on the
next poll and makes bounded changes. Enabling a previously unconfigured region
also requires building, validating, and activating a new candidate. Disabling a
region should likewise be followed by candidate activation to restore its
ordinary groups. Native Windows routes are not managed by this controller.

### Theta follow-up, 2026-10-26

The passive observer now records local-send retransmitted bytes, socket opens/disappearances, TCP states, queues and time since last receive. These counters do not measure remote-send packet loss, distinguish normal closure from failure, or establish a server stall without a known active request. After WSL restarts, verify the observer status timestamp before interpreting old logs. The 18:09–18:12 Shanghai review found no active provider workers and no comparable ongoing download, so no route change or speedup claim was justified. See `state/theta-followup-20261026/result.json` and the shared provider result for evidence and rollback.

On October 28, Java used the Windows mixed proxy on localhost port7897. The observer now samples that transport as well as direct443, reports `local_proxy_relay_connections` and `transport_mode`, and keeps relay RTT in `relay_rtt_ms_min/max`. The existing `rtt_ms_min/max` and `upstream_tls_connections` describe direct sockets only. Local relay RTT cannot establish Internet latency or physical adapter throughput. Use the Mihomo connection API to inspect the existing flow's chain; a fallback group's current choice can differ from the node retained by an established flow. The observer sends no data requests or proxy health probes.

The October 29 observer adds `receive_window_bytes/seconds/mbps` over approximately30seconds of cumulative progress, with actual covered duration reported. A zero one-second delta alone is not an upstream-stall diagnosis. `requests_sent=0` and `observer_requests_sent=0` describe the observer itself, not provider acquisitions. Use `requests_sent_scope` and receipt timings for that distinction. `observer_pid` and `observer_started_utc` identify counter baselines; do not subtract cumulative totals across an observer reload. A new window starts cold and needs elapsed samples before interpretation.

Theta's [official concurrency contract](https://www.thetadata.net/docs/Articles/Data-And-Requests/Concurrent-Requests.html), checked October29, specifies four account-wide concurrent requests for Standard and no separate request-rate limit. Earlier approximately2requests/second measurements reflected the provider's local0.5second spacing, not a vendor tier limit. Provider-owned explicit four-slot mode now removes that artificial spacing while preserving global request/concurrency guards; legacy modes retain their policy. Mihomo does not manage those limits. The October29 active capture observed2.85completedrequests/second through Tokyo with predominantly pre-header HTTP time; it does not establish a controlled route speedup.

### Default-route reconciliation guard, 2026-10-30

`Repair-MihomoAdapters.ps1` now defers automatic default-route creation and metric changes while managed uplinks carry established or connecting TCP sessions, UDP endpoints, or an ICS public connection. Wildcard UDP bindings are conservatively considered active. Inspection or state errors also defer changes. A continuously observed, unchanged adapter/address/interface-metric/default-route inventory must remain idle for 120 seconds before reconciliation is eligible; a gap over 45 seconds or a backwards clock resets that interval. This can defer automatic repair indefinitely during background traffic or hotspot sharing, intentionally preserving existing sessions.

The watcher reads the helper script on each iteration, so activation needs no restart or proxy reload. Decisions are saved in `state/adapter-recovery/route-guard.json`; this state is not a source-readiness signal. The guard suppresses watcher actions and cannot prevent hardware disconnection, USB re-enumeration, DHCP changes or routes recreated by Windows. It does not change the existing address/name restoration or separate stall-recovery policy. The October30 incident and activation report, exact helper backup, checksums and test output are under `state/shared-outage-20261030/`. Roll back by atomically restoring `guard-backup/Repair-MihomoAdapters.ps1` to the live helper after checking for later edits; deleting the module alone fails closed.
