# Interfaces contracts and provenance

[Documentation index](../README.md) · [Operations](OPERATIONS.md) · [Development](DEVELOPMENT.md)

## Configuration comparison

`python tools/Attest-Config.py before.yaml after.yaml` reads exactly the supplied local files and prints JSON. It sends no requests and changes no controller state. Exit 0 means comparison completed, including when files differ. Exit 2 returns a generic error for unreadable/unsupported input; parser source lines are suppressed because they may contain credentials.

Schema version 1 reports `before_sha256`, `after_sha256`, `bytes_equal`, `semantics_equal`, `changed_sections`, `theta_explicit_rules_equal` and `limits`. Hashes fingerprint bytes; semantic fingerprints ignore formatting/key order but retain array/rule order and boolean/number distinctions. Section labels are fixed; arbitrary YAML keys and values are withheld. Duplicate keys, YAML merges, recursive structures, timestamps/nonfinite numbers and invalid section shapes are rejected rather than accepted ambiguously.

This is a review aid, not engine validation or cryptographic attribution to an author. Equal explicit Theta rules can coexist with changed earlier rules, proxy chains or loaded state. No readiness/activation permission follows from a hash match. The separate `Compare-ConfigPolicy.ps1` accepts `-TemplatePath`, `-DeployedPath`, `-Strict`; its policy summary is not a lossless diff. Protect private inputs and receipts even when a report is value-redacted.

## Dashboard HTTP surface

[Server.ps1](../../src/dashboard/Server.ps1) accepts `-Root` and `-Prefix` (default `http://127.0.0.1:8899/`). It rejects credentials, non-loopback/wildcard hosts and unexpected path prefixes. It serves fixed paths, not arbitrary filesystem traversal:

| Path | Source / behavior |
|---|---|
| `/`, `/index.html` | `web/index.html` |
| `/design` | `web/design.html` documentation page |
| `/balance`, `/balance.html` | `web/balance.html` |
| `/api/status` | Existing `state/status.json` snapshot |
| Other paths | HTTP 404 |

The collector is the sole snapshot writer; the server does not invoke it per request. Status must be valid UTF-8, a JSON object, nonempty and at most 256 KiB. Missing, oversized, malformed or scalar snapshots return HTTP 503 with an error object. HTTP 200 means a valid stored object, not necessarily a fresh observation. The collector publishes through an atomic file replace; consumers must still inspect timestamps and partial/error fields. Snapshot internals follow collector/UI tests and are not a separately versioned public broker API.

The optional core `/ui/` dashboard on port 9097 is distinct from this toolkit's server. Retained compatibility panels/file names do not imply an active HypoMux engine or VM. The server offers no repair/trading route.

## PAC and controller surfaces

[Serve-Pac.ps1](../../tools/Serve-Pac.ps1) serves generated PAC on port 8080 and writes the inspectable `tools/proxy.pac`. Private/loopback and selected direct/local domains resolve to DIRECT; other requests advertise `PROXY 192.168.137.1:7897; DIRECT`. The helper derives current rules from the local core and merges its base domain list. This is application opt-in and can bypass the proxy; LAN address changes require review.

Mihomo controller reads include `/version`, `/configs`, `/proxies`, `/connections` and DNS queries used by helpers. Selector PUTs and configuration reload PUTs are mutations; the toolkit uses them for owned allocation and guarded activation. This project wraps the installed engine's API; it does not define the engine's entire API contract. Keep the controller private and do not expose diagnostic data as a public service.

## Passive telemetry and provider boundary

`ObserveThetaNetwork.py` reads process/socket counters and completed receipt summaries under the configured data root. It identifies the terminal Java installation and children; command arguments, raw peer addresses, credentials and packet payloads are not emitted as telemetry. `observer_pid`, `observer_started_utc`, sample time and actual window duration identify the baseline.

Direct TLS counts/RTT are separate from `local_proxy_relay_connections` and relay RTT. `requests_sent=0` and `observer_requests_sent=0` describe only the observer, not provider acquisition. Closed-between-poll flows/bytes may be missed. A one-second zero delta, idle state, CLOSE-WAIT or absence of a joined controller flow cannot independently establish upstream failure or capacity.

When a request owner needs actual route evidence, join the Java-owned local source port to the existing controller connection and retain its chain and times. A group's current selector can differ from an established flow's retained node. A browser's LA connection is not proof of Java's route. No new request should be generated merely to make passive evidence look ready.

Provider applications own request admission, global concurrency, receipt/body hashes, failed/consumed key protection, data quality, storage lineage and market-data publication. Empty/error HTTP responses and stale market dates require endpoint-specific evidence, not a network-only verdict. This toolkit is not an acquisition engine, execution UI, risk model, order router or research acceptance layer. Optional market-data helpers are outside the offline test/documentation workflow.

## Evidence durability

Configuration/selection backups and diagnostics live in private `state/` and runtime paths. Source bundles contain a SHA-256 manifest, toolkit VERSION and sanitized source; they exclude private state, binaries and deployment credentials. A Git bundle captures committed history/refs, not private runtime or uncommitted work. Each has a different recovery purpose.

Dated release validation records establish only the source/check commands recorded at that commit. Never infer production uptime, broker authentication, synchronized quotes, economic correctness or physical-adapter throughput from a unit-test count or successful source CI.

## Optional accounting and application helpers

Spend/traffic helpers attribute sampled byte counters to configured chains; polling is not an authoritative billing ledger, and a proxy chain alone does not prove physical TUN dispatch. Market-data and application-start helpers have separate external side effects and are not exercised by source/documentation validation. Their presence does not make this repository an order-execution or research-validation system.
