# Configuration reference

[Documentation index](../README.md) · [Operations](OPERATIONS.md) · [Handoff](HANDOFF.md)

Reviewed against local source on 2026-10-31. Values below describe source policy, not a live network inspection. The private YAML, saved controller selections, Windows routes, and ICS state determine actual behavior.

## Ownership and change lifecycle

| File | Owner and application method |
|---|---|
| `config/network-architecture.json` | Native architecture and preferred hotspot uplinks; consumed by the builder and hotspot/recovery code |
| `config/mihomo-adapters.json` | Hardware identity, addressing, metrics and MTU; applied by adapter recovery subject to safety guards |
| `config/dispatch-policy.json` | Generated dispatch structure and controller policy; structural changes require a candidate build and activation |
| `config/codex-cloud-tunnel.json` | Separate backend tunnel policy; watcher reads it every iteration |
| `config/mihomo-config.template.yaml` | Sanitized policy reference; never a replacement for private deployment YAML |
| `runtime/config.yaml` | Effective private main-engine configuration loaded at startup or activation |
| `runtime/providers/` | Private provider caches and inputs; preserve with deployment backups |
| `state/` | Diagnostics, controller state, learned data, snapshots and rollback material; not disposable build output |

Use the [routing change procedure](OPERATIONS.md#routing-changes) to build into a unique private directory, compare policy, validate and activate. A JSON edit does not necessarily change the running engine. A saved selection can outlive YAML member reordering. Record both the config hash and controller selections when comparing behavior.

## Adapter identity, addressing and metrics

| Physical adapter | Logical proxy slot | Interface metric | Default-route metric | Expected sum | Declared static IPv4 |
|---|---|---:|---:|---:|---|
| `jd_5G` | `jd_5G` | 10 | 0 | 10 | `192.168.0.250/24`, gateway `192.168.0.1` |
| `iPhone 17 pro max` | `win_turbo_phone` | 20 | 5 | 25 | Device supplied |
| `pisen_2026_03` | `pisen_2026_03` | 30 | 10 | 40 | `192.168.1.100/24`, gateway `192.168.1.1` |
| `pisen_2026_10` | `pisen_2026_10` | 40 | 30 | 70 | Device supplied |

The map uses MAC, interface GUID and PnP identity. Reusing this machine's IDs on another PC is not provisioning. Capture and review the new machine's identities before enabling recovery. Preserve the logical iPhone slot unless every dependent group and selection is deliberately migrated.

Pisen 10 declares `ipv4Mtu: 1400`; this is an investigated device/path setting, not a universal modem recommendation. Other entries do not declare an MTU override. The recovery helper guards route, interface-metric and MTU adjustments with the stable-idle policy. Established/connecting TCP, UDP endpoints, ICS ownership or uncertain inspection can defer reconciliation. See [the guard behavior](DISPATCH.md#default-route-reconciliation-guard-2026-10-30). Desired metrics do not prove that a deferred change has occurred.

## Architecture and hotspot policy

`mode` must remain `mihomo`. `ordinaryTransport: windows-direct` describes native traffic outside the proxy. `connectionBalance` and legacy `standbyAdapters` participate in generated policy; the dispatch overlay is applied afterward.

`hotspotUplink.enabled` enables preferred-uplink selection. `hotspotUplink.prefer` currently lists JD, older Pisen, newer Pisen, then iPhone. This is a preference order, not an assertion about the adapter Windows actually shares. Inspect hotspot status and the `uplink:` log before changing proxy allocations.

The SSID `HypoMux` does not mean the retired HypoMux engine is running. Clients using ICS alone use the shared Windows uplink. PAC or explicit-proxy clients can use Mihomo; PAC does not capture arbitrary applications or all UDP traffic.

## Dispatch fields

The [dispatch guide](DISPATCH.md) owns algorithm details and evidence. These fields are especially relevant when maintaining configuration:

| Field | Meaning and maintenance constraint |
|---|---|
| `enabled` | Running controller exits after observing false; generated static groups remain |
| `enabledRegions` | Currently WAN and TOKYO; changing membership requires rebuilding the engine configuration |
| `slots` | 24 weighted connection slots; byte shares need not match slot shares |
| `capacitiesMbps` | Explicit per-region calibration priors, not measured current line speed; controller rereads policy and applies bounded allocation changes |
| `pollSeconds`, `logSeconds`, `rebalanceSeconds` | Current defaults 10, 30 and 300 seconds |
| `staleHealthSeconds` | Current health freshness limit: 100 seconds |
| `initialEligible` | Starting allocation scores only; all four adapters still appear in generated providers |
| `fallbackOrder` | Ordered direct fallbacks after `WAN-ACTIVE`; must list every managed logical slot exactly once |
| `proxyUplinkOrder` | Builds the transport fallback for base proxy servers; must also list all four slots, so putting an ICS adapter last does not remove it |
| `interfaceBindings` | Maps `win_turbo_phone` to physical `iPhone 17 pro max` |
| `adapterProxySources` | Preserves selected transport sources: `BALANCED-pisen_2026_10` uses `hy2-tokyo`; `LA-win_turbo_phone` uses `hy2-upstream` |
| `standbyPaths` | Tokyo iPhone is standby while ordinary Tokyo paths are healthy; this is not a hard exclusion |
| `regionalStability` | Health hysteresis for region preference; does not certify download speed |
| `nativeThetaObserver` | Optional passive WSL observer with machine-specific distribution and project paths |

Current `proxyUplinkOrder` is JD, newer Pisen, iPhone, older Pisen. Current initial eligibility is newer Pisen and iPhone in all three listed regions. These settings coexist with a hotspot preference for JD and a historical live exclusion of older Pisen. Resolve actual ownership before rebuilding; do not interpret this combination as an automatic ICS reservation mechanism.

`AdaptiveDispatch.py --input <private.yaml> --output <candidate.yaml>` applies the narrow overlay; `Build-MultiWanConfig.py --input <private.yaml> --output <candidate.yaml>` regenerates broader native policy and then applies that overlay. Both create candidates, not activation. Both can reintroduce all four provider members. Keep inputs and outputs private and review the resulting memberships.

## Codex cloud tunnel

This section describes repository implementation, not a general Codex product guarantee. The watcher targets `codex-cloud-backend.chatgpt.com` because the recorded native backend connection bypassed the user proxy.

| Policy field | Current value / role |
|---|---|
| `enabled` | `true`; false exits the watcher and stops its child engine on normal cleanup |
| `hostname` | Backend resolved through the main controller's A/AAAA DNS query API |
| `device` | `CodexCloud` virtual adapter |
| `egressPort` | 19989: required loopback SOCKS listener in the main private deployment, intended for `CHATGPT` |
| `mixedPort` | 19990: loopback-only auxiliary proxy |
| `controllerPort` | 19997: loopback-only auxiliary controller |
| `refreshSeconds` | 60; watcher enforces a minimum sleep of ten seconds |

The separate engine routes resolved public IPv4 `/32` and IPv6 `/128` addresses to a SOCKS relay in the main engine. It enables TUN auto-route for those host routes, with no default-route capture and no DNS hijacking. IP routing is not process-specific: another application using the same destination IP can also take that route.

The watcher preserves an existing engine on transient DNS/controller errors. `status.json` can therefore become stale; compare its time with `watch.log` and actual process/listener state. Changes to ports or other non-address fields are not guaranteed to reload a running child: reload detection fingerprints the host-route list. Use a planned watcher restart for those changes and verify the corresponding main-engine listener.

Registration uses an elevated interactive-user logon task, `MihomoCodexCloudTunnel`, with hidden execution. Standard autostart registration includes it when enabled. Setting `enabled` back to true after exit requires starting its task again. See [operations](OPERATIONS.md#current-state-caution) for stop/autostart distinctions.

Generated configuration and diagnostics live under `state/codex-cloud-tunnel/`: `config.json`, `status.json`, `watch.log`, `engine.log`, `engine.err`, and `engine.pid`. A PID file alone is not proof of process ownership or liveness.
