# Dispatch and observation

[Documentation index](../README.md) · [Configuration](CONFIGURATION.md) · [Contracts](CONTRACTS.md)

## Generated groups and allocation

[AdaptiveDispatch.py](../../tools/AdaptiveDispatch.py) applies an overlay to native policy and runs a selection controller. The published policy enables WAN and TOKYO; LA retains its ordinary backup policy. WAN's parent group uses destination hashing across weighted slots; Tokyo rotates new connections smoothly. An established flow retains its chosen path.

For eligible healthy paths the unrounded share is `0.5 / healthy_count + 0.5 * prior / total_prior`. Counts are rounded into the configured slots (24 by default). With four eligible healthy paths, each unrounded share lies between 12.5% and 62.5%. These are scheduling counts, not guaranteed byte shares or physical line capacity.

One inline provider per managed region contains the adapter-bound paths; slot fallbacks reference it, sharing 30-second health checks. Parent and application group checks are additional work. `AUTO`/`DATA` prefer Tokyo with LA backup. `DISPATCH` includes `WAN-ACTIVE`, configured ordered direct fallbacks, then `DIRECT`. The overlay creates the base transport group `PROXY-UPLINK` separately from general WAN allocation.

The legacy `PAID` group is removed by generation; retained `autolearn-paid` cache naming is compatibility metadata and does not identify a current paid provider. Application rules and broker-owned native connections are outside the controller's selection ownership.

## Health and change bounds

The controller polls every 10 seconds by default. Failed/stale samples remove a path from its target. Recovery needs two distinct fresh successful samples separated by at least ten seconds; repeatedly reading one old success is insufficient. Routine rebalances move at most one slot per region per default five-minute interval. Health removal and stable recovery can change more slots. When all paths fail, native fallback remains rather than inventing capacity.

Regional hysteresis requires two healthy Tokyo paths, three checks and 60 seconds stability before promotion. Failure holds the healthy LA backup for 180 seconds; a sole available region can be used immediately. The guard releases only a preference it still owns, respecting a subsequently changed manual pin.

Calibration priors are explicit policy inputs. Passive delivered rates, idle counts and EWMA observations never update them automatically. Historical small-transfer measurements do not identify present radio capacity or client demand. A shared carrier or one slow flow can limit observed delivery; one TCP session is not bonded across adapters.

`standbyPaths` removes a standby from ordinary allocation while ordinary paths are healthy; it is not a permanent exclusion. `initialEligible` changes starting weights only. Generator/provider membership still requires reviewing actual ICS ownership before activation. See [known design gap](ARCHITECTURE.md#known-limitations-and-proposals).

## Lifecycle and CLI effects

| Invocation | Effect |
|---|---|
| `AdaptiveDispatch.py --help` | Offline argument help |
| `AdaptiveDispatch.py --input before.yaml --output candidate.yaml` | Read YAML/policy and write overlay candidate; no controller mutation |
| `AdaptiveDispatch.py --once --observe-only` | Query controller, write state/logs once, suppress selection updates; not offline |
| `AdaptiveDispatch.py --once` | Query and potentially change owned selections once |
| `AdaptiveDispatch.py` | Lock state directory and run controller loop |

`--policy` and `--state` override the default policy/state paths. `--output` is required with `--input`. The running controller needs the Python standard library; generation also needs PyYAML. The full multi-WAN builder applies the overlay last when its dispatch policy exists.

[Start-AdaptiveDispatch.ps1](../../tools/Start-AdaptiveDispatch.ps1) checks policy/process ownership and launches the configured bundled Windows Python headlessly. It also requests the optional WSL observer. The supervisor invokes it at startup; repeated PAC/diagnostics maintenance does not provide an ongoing dispatcher watchdog. Check timestamps and process identity independently. A missing controller leaves the core's generated static groups and native health/fallback behavior in place.

Set policy `enabled` false to permit controller exit on its next loop; static core groups remain. Structural region/group changes need a reviewed candidate and explicit activation. Re-enabling an exited controller requires starting it again. The passive observer has its own lifetime; disabling future launch in policy does not terminate an existing observer. No lifecycle commands were executed by this documentation audit.

## Logs and privacy

`state/adaptive-dispatch/status.json` records current allocation, health, target counts and effective mode. `dispatch.jsonl` rotates at 5 MiB with five backups; daily UTC rollups retain 30 files. Counters describe sampled delivery and may miss short flows or final bytes between polls. Salted opaque flow identifiers are not raw socket IDs; dispatcher logs omit credentials, destinations, payloads and process paths. General core/operator logs have different privacy properties and can contain destinations.

A stale status file is not zero demand. Record observer/controller baseline identity before subtracting cumulative counters. The passive Theta observer separately scopes Java sockets, tracks direct versus local-proxy relays, and sends no provider requests. A local relay's RTT is not Internet latency. See [telemetry contracts](CONTRACTS.md#passive-telemetry-and-provider-boundary).

## Route reconciliation guard

[AdapterRouteGuard.psm1](../../src/NetStack/AdapterRouteGuard.psm1) belongs to Windows adapter recovery, not the allocation controller. Its 120-second stable-idle interval, 45-second observation-gap limit, active TCP/UDP and ICS protection can defer route/metric/MTU changes indefinitely. Recovery state errors fail closed. It cannot prevent external DHCP or hardware changes, and it does not authorize a provider request.

A rollback must restore the specifically reviewed private configuration and affected selectors, not an arbitrary historical snapshot. Use [guarded rollback](OPERATIONS.md#rollback) and preserve newer application policy.
