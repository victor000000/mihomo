# Documentation index

The maintained source documentation describes the published implementation. Commands use the repository root in a Windows shell unless explicitly labeled otherwise. Runtime state, saved selections and device identity must be checked independently before live changes.

| Guide | Owns |
|---|---|
| [Overview](../README.md) | Project scope and onboarding |
| [Architecture](current/ARCHITECTURE.md) | Traffic paths, rationale, lifecycle and ownership |
| [Configuration](current/CONFIGURATION.md) | Policy fields, ports, exposure and application method |
| [Operations](current/OPERATIONS.md) | Provisioning, command effects, guarded activation, rollback and troubleshooting |
| [Dispatch](current/DISPATCH.md) | Allocation, health recovery, controller state and limitations |
| [Contracts and provenance](current/CONTRACTS.md) | Dashboard API, file contracts, passive telemetry and evidence interpretation |
| [Development](current/DEVELOPMENT.md) | Dependencies, offline checks, tests, source export and CI |
| [Contributing](../CONTRIBUTING.md) | Ownership, privacy and review expectations |
| [0.0.3 review](current/RELEASE-0.0.3.md) | Release design and implementation scope |
| [Release verification](verification/2026-11-07-toolkit-0.0.3-publication.md) | Dated source validation, not current machine health |
| [Documentation audit](verification/2026-11-07-documentation-audit.md) | Coverage, source/private disposition, validation and unresolved gaps |

## Historical evidence

Dated release records retain their original facts and dates. Current guides supersede the mixed design/measurement prose from [the previous published guides](https://github.com/victor000000/mihomo/tree/7f62fff/docs/current). That snapshot also retains the earlier [HTML design page](https://github.com/victor000000/mihomo/blob/7f62fff/web/design.html), whose retired HypoMux topology must not be used as a current deployment recipe.

Private task notes and incident receipts referenced by earlier indexes were not included in the sanitized publication. They are not missing installation dependencies. The audit inventory records their disposition without exporting private configuration or measurements. There is no published HANDOFF.md; the operations guide owns deployment and recovery.

## Maintaining the docs

Keep one canonical owner per topic as above. Link to the owner rather than copying procedures. Verify claims against source, distinguish template defaults from deployed values, and label every operational command that changes processes, tasks, routes, proxy settings or files. Keep historical outcomes dated and qualify what was actually measured.

Run `python tools/Check-Docs.py` for root/`docs/` Markdown inline local links and anchors, then repository audits. The checker does not fetch external links, execute examples, parse embedded HTML or validate reference-style Markdown. Review those separately. New public docs must contain no private endpoints, credentials, hardware secrets or raw provider payloads.
