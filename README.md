# Mihomo native multi-adapter networking

Windows networking toolkit for Mihomo routing, four managed adapters, automatic adapter recovery, and Windows Mobile Hotspot.

Applications using the system or explicit proxy enter Mihomo on port **7897**. General traffic can use adapter-bound Tokyo and LA pools. The intended hotspot split prefers **`jd_5G`** for HypoMux clients and reserves other adapters for proxy traffic. Actual ICS ownership has diverged from that policy; inspect it before choosing proxy paths (see [handoff and known gaps](docs/current/HANDOFF.md)). The main engine's TUN stays disabled. A separate cloud-only tunnel covers Codex's backend WebSocket addresses, because that connection bypasses Windows proxy settings; other native applications follow Windows routing.

## Start here

This checkout also contains a local deployment. A fresh clone or source bundle needs the runtime binary, private configuration, provider files, and machine setup described in [deployment prerequisites](docs/current/OPERATIONS.md#deployment-prerequisites).

On an already provisioned Windows machine, run from the repository root:

```powershell
.\start-network.bat --check
.\start-network.bat
```

The first command captures local status; the second starts the proxy and registered hotspot task and enables the user system proxy. For repair, startup registration, stopping, and live checks, use the [operations guide](docs/current/OPERATIONS.md).

| Need | Read |
|---|---|
| Resume work or deploy on another machine | [Deployment and recovery](docs/current/OPERATIONS.md) |
| Understand configuration fields and reload behavior | [Configuration reference](docs/current/CONFIGURATION.md) |
| Diagnose a connection or change routing | [Operations](docs/current/OPERATIONS.md) |
| Inspect traffic weights or optimization logs | [Dispatch](docs/current/DISPATCH.md) |
| Understand adapters, fallback, and hotspot traffic | [Architecture](docs/current/ARCHITECTURE.md) |
| Develop, test, or package source | [Development](docs/current/DEVELOPMENT.md) and [contributing](CONTRIBUTING.md) |
| Find task notes and dated results | [Documentation index](docs/README.md) |

Live configuration and credentials stay in ignored deployment files. **Never replace `runtime/config.yaml` with the sanitized template.**

The supported design uses native Windows networking. The hotspot retains the SSID **HypoMux**, but the old HypoMux engine and OMR VM are retired. Failover helps new connections; it cannot preserve a TCP session after its path disappears.
