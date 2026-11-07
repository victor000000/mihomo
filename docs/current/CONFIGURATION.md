# Configuration reference

[Documentation index](../README.md) · [Architecture](ARCHITECTURE.md) · [Operations](OPERATIONS.md)

This reference describes published source defaults, reviewed 2026-11-07. Private deployed YAML, saved selectors, actual adapters and ICS ownership can differ.

## Sources and application method

| Source | Meaning | How changes take effect |
|---|---|---|
| [network-architecture.json](../../config/network-architecture.json) | `mode: mihomo`, native transport metadata, standby and hotspot preference | Consumed by builders and relevant hotspot/recovery helpers |
| [mihomo-adapters.json](../../config/mihomo-adapters.json) | Identity, logical slot, static address, metrics, optional MTU | Recovery code, subject to applicable guards |
| [dispatch-policy.json](../../config/dispatch-policy.json) | Generated structures and runtime allocation policy | Structural edits need generation/activation; running controller rereads policy |
| [codex-cloud-tunnel.json](../../config/codex-cloud-tunnel.json) | Auxiliary destination host-route tunnel | Watcher iterations; some non-address edits need a planned lifecycle change |
| [mihomo-config.template.yaml](../../config/mihomo-config.template.yaml) | Sanitized baseline, placeholders and ordered policy | Provisioning input only; never overwrite live YAML |
| `runtime/config.yaml` and providers | Private effective main-core configuration | Core startup or explicit activation |
| `state/` | Diagnostics, locks, snapshots, selections and recovery receipts | Producer-specific; preserve as private operational evidence |

ETag support is disabled in template/generators to avoid storing complete credential-bearing subscription URLs as database keys. Existing cache entries are not erased by setting this option. See [offline cache migration](OPERATIONS.md#offline-cache-migration).

## Listeners and exposure

| Surface | Published default / deployment requirement |
|---|---|
| Main mixed HTTP/SOCKS proxy | Port 7897, `bind-address: 127.0.0.1`, `allow-lan: false` |
| Main controller | `127.0.0.1:9097`; optional installed `/ui/` |
| Main DNS | Enabled, `127.0.0.1:53`; this alone does not configure Windows DNS |
| PAC server | Separate port 8080 listener; generated target `192.168.137.1:7897` |
| Toolkit dashboard | Separate HTTP loopback server, default `http://127.0.0.1:8899/` |
| Auxiliary tunnel | Loopback mixed port 19990 and controller 19997 |
| Auxiliary egress dependency | Requires main private loopback listener 19989, intended to route to `CHATGPT`; absent from the public template |

A source clone does not provide the private egress listener, engine binary or useful credentials. LAN/PAC service requires reviewing reachability, firewall policy and exposure; the loopback template will not serve remote clients merely because PAC advertises a LAN address. The dashboard rejects wildcard/non-loopback prefixes.

## Adapter identity addressing and metrics

Managed logical slots are `win_turbo_phone`, `pisen_2026_10`, `jd_5G` and `pisen_2026_03`. `interfaceBindings` maps the phone slot to `iPhone 17 pro max`; the adapter map records `proxySlot` for the same correspondence. The public MACs are placeholders; recorded GUID/PnP fields and private subnet values still require review for a new machine. Missing or ambiguous device identity is left unchanged rather than guessed from a friendly name.

Declared interface/default-route metric pairs are JD 10/0, phone 20/5, older Pisen 30/10, newer Pisen 40/30. The expected sums describe preferences, not verified current routes. Static IPv4 is declared only for JD and older Pisen; other addressing is device supplied. Newer Pisen declares IPv4 MTU 1400, an investigated path-specific setting rather than a universal recommendation.

`hotspotUplink.enabled` is true, with preference JD, older Pisen, newer Pisen, phone. Legacy `standbyAdapters` lists JD; the dispatch overlay is applied after that legacy pool policy. Both fallback-order arrays must list every logical slot exactly once, so they cannot express an excluded shared adapter.

## Dispatch settings

| Field | Published value or constraint |
|---|---|
| `enabled`, `enabledRegions` | true; WAN and TOKYO |
| `slots` | 24; validation accepts 20 through 32 |
| `pollSeconds`, `logSeconds`, `rebalanceSeconds` | 10, 30, 300 |
| `staleHealthSeconds` | 100 |
| `capacitiesMbps` | Explicit calibration priors; not learned from passive traffic |
| `initialEligible` | Newer Pisen and phone per listed region; starting weights, not provider exclusion |
| `fallbackOrder` | JD, older Pisen, phone, newer Pisen |
| `proxyUplinkOrder` | JD, newer Pisen, phone, older Pisen |
| `standbyPaths` | Tokyo phone is standby, not permanently removed |
| `adapterProxySources` | Newer-Pisen Tokyo uses `hy2-tokyo`; phone LA uses `hy2-upstream` |
| `regionalStability` | Two healthy paths, three checks, 60 seconds stable; 180-second hold-down |
| `nativeThetaObserver` | Optional WSL observer; configured distribution and repository/data roots are machine-specific |

[Dispatch](DISPATCH.md) owns algorithm and state interpretation. The published policy's evidence paths and prior measurements are historical references to private files, not bundled receipts or guarantees.

## Codex cloud tunnel

This is repository-specific handling of a recorded proxy-bypassing backend destination, not a general product guarantee. The policy enables a `CodexCloud` device for the configured backend hostname, refresh interval 60 seconds, egress 19989, mixed 19990 and controller 19997.

The watcher resolves public A/AAAA destinations through the main controller and generates `/32` and `/128` routes through a separate TUN engine. It does not capture a default route or hijack DNS. Transient lookup/controller failures preserve the existing engine. Reload detection fingerprints destination routes; changing ports or other non-address settings is not guaranteed to reload a running child. Disabling the policy permits normal cleanup/exit; re-enabling after exit requires starting its task.

Inspect process ownership, timestamps and configured ports when operating the tunnel. Its `state/codex-cloud-tunnel/` PID/status files alone do not prove a current process or connection. [Operations](OPERATIONS.md#stop-and-autostart-boundaries) describes why stopping cores and disabling future tasks are different actions.
