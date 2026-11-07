# Mihomo native networking toolkit

Toolkit **0.0.3** manages Windows proxy startup, adapter recovery, Mobile Hotspot/ICS, policy generation and local diagnostics. The Mihomo engine is a separate dependency with its own version. The supported architecture is native Windows networking; the hotspot SSID `HypoMux` is a retained name, not a requirement to run the retired HypoMux engine or an OMR VM.

A public clone is sanitized source, not an installed network stack. It contains no engine binary, private runtime configuration, usable proxy credentials or measured guarantee for your hardware. Begin with [development](docs/current/DEVELOPMENT.md) for offline work, or [deployment prerequisites](docs/current/OPERATIONS.md#deployment-prerequisites) for an explicitly planned installation. Never overwrite an existing `runtime/config.yaml` with the template.

## Choose a workflow

| Goal | Canonical guide |
|---|---|
| Understand traffic paths, ownership and failure boundaries | [Architecture](docs/current/ARCHITECTURE.md) |
| Review policy files, defaults and exposure | [Configuration](docs/current/CONFIGURATION.md) |
| Start, inspect, repair or recover a provisioned machine | [Operations](docs/current/OPERATIONS.md) |
| Understand allocation and health hysteresis | [Dispatch](docs/current/DISPATCH.md) |
| Interpret dashboard/API, logs and configuration fingerprints | [Contracts and provenance](docs/current/CONTRACTS.md) |
| Install test dependencies, run CI-equivalent checks or package source | [Development](docs/current/DEVELOPMENT.md) |
| Review release scope and validation limits | [0.0.3 review](docs/current/RELEASE-0.0.3.md) |

On an already provisioned Windows machine, `start-network.bat --check` captures local status. `start-network.bat` starts processes, requests the registered hotspot task and enables the user proxy; it is an operational change. Neither is part of offline documentation validation.

Proxy-aware applications enter the mixed proxy on port 7897. The published template binds it to loopback. Native applications that bypass the proxy continue to follow Windows routing. ICS clients use one shared uplink unless their applications explicitly use a reachable proxy/PAC. A separate optional cloud-only tunnel installs destination host routes. See the architecture guide before treating a healthy browser request as evidence for every application.

Failover helps new connections after detection. It does not preserve a TCP session whose path disappeared, bond one connection across adapters, or establish authenticated application success. Unit tests and CI validate source behavior with fixtures; deployment and hardware acceptance are separate work.

[Documentation inventory](docs/README.md) · [Contributing](CONTRIBUTING.md)
