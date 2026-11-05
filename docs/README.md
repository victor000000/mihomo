# Documentation index

Start with the [project overview](../README.md). Commands in these guides run from the repository root in a Windows shell unless stated otherwise.

| Document | Purpose |
|---|---|
| [Deployment and recovery](current/OPERATIONS.md) | First-session checklist, evidence map, known gaps, backup and migration boundaries |
| [Configuration reference](current/CONFIGURATION.md) | Policy fields, adapter identities and metrics, reload semantics, cloud-only tunnel |
| [Dispatch](current/DISPATCH.md) | Weighted scheduling, health hysteresis, controller lifecycle and observation limits |
| [Operations](current/OPERATIONS.md) | Provisioning requirements, daily commands, routing changes, rollback, troubleshooting, and logs |
| [Architecture](current/ARCHITECTURE.md) | Traffic paths, configuration ownership, adapter recovery, startup, and limitations |
| [Development](current/DEVELOPMENT.md) | Source map, pinned dependencies, checks, tests, and packaging |
| [Contributing](../CONTRIBUTING.md) | Change ownership, deployment-data handling, and review expectations |
| [SQX download follow-up](tasks/SQX-DOWNLOAD.md) | Deferred investigation; observations from 2026-10-20 require rechecking |
| [WeChat hotspot speedup](tasks/WECHAT-HOTSPOT-SPEEDUP.md) | Hotspot client path, the ICS/proxy adapter coupling, and the opt-in uplink policy |
| [2026-10-21 verification](verification/2026-10-21.md) | Recorded migration and Lingoda results, evidence locations, and unverified items |
| [2026-10-25 verification](verification/2026-10-25.md) | StrategyQuant course player (Vimeo) routing and the `VIMEO` group; pre-class Lingoda path measurements and fix |
| [2026-10-27 verification](verification/2026-10-27.md) | Pre-class Lingoda fix: Zoom China hosts were pinned to the slow tether by `DOMAIN-SUFFIX,cn`; classroom Zoom now uses `ZOOM`/`WAN-jd_5G` |
| [2026-10-28 verification](verification/2026-10-28.md) | Phone throughput retest and ICS repair restoring adapter-bound IPv4 |

| [Bilibili speedup](tasks/BILIBILI-SPEEDUP.md) | Application-specific routing investigation |
| [iCloud speedup](tasks/ICLOUD-SPEEDUP.md) | iCloud path investigation and observations |
| [Amazon speedup](tasks/AMAZON-SPEEDUP.md) | Product-page routing, CDN edge choice, the `AMAZON` group, and the `AMAZON-JP` Tokyo-first route for the Japanese store |
| [Goodreads speedup](tasks/GOODREADS-SPEEDUP.md) | Book-page routing past a TLS reset, AWS WAF challenge-IP alignment and the `GOODREADS` group |
| [2026-11-02 Goodreads verification](verification/2026-11-02-goodreads.md) | Before/after browser numbers and the WAF split-routing test |
| [2026-11-04 XVIDEOS verification](verification/2026-11-04-xvideos.md) | Failover repair and before/after 1080p HLS throughput |
| [2026-11-04 YouTube verification](verification/2026-11-04-youtube.md) | Channel and watch page routing; `hy2-upstream` before/after |
| [October 29 phone verification](verification/2026-10-29-phone.md) | Phone-specific verification record |
| [October 29 design verification](verification/2026-10-29-design.md) | Design review record |
| [October 30 incidents](verification/2026-10-30.md) | Codex outages, ICS collisions, repairs and unresolved rebuild exclusions |

## Reading order

For future maintenance, read the overview, handoff and configuration reference first. Use operations for live actions, architecture for traffic paths, dispatch for allocation behavior, and development for offline checks. Dated verification records are historical evidence; they do not override current source policy or establish current machine health.

## Maintaining the docs

- Keep one owner for each procedure: operations for running the deployment, architecture for how it works, development for source validation.
- Check behavior against scripts and sanitized configuration before documenting it. The live configuration and controller selections determine the deployed route; the template describes intended policy.
- Separate current instructions from dated observations. Record the date, command or method, evidence location, and limits of any verification claim. Avoid permanent test-count or speed promises.
- Use relative links, verify local targets and section anchors, and keep examples explicit about shell and side effects. The repository audit covers secrets and text integrity; it does not currently validate Markdown links.

Historical OMR/HypoMux material was moved to `C:\Users\victo\mihomo-retired-20261021`. It is outside the maintained project and is not a deployment recipe; the OMR VM disks were deleted.
