# Documentation audit — 2026-11-07

## Baseline and scope

Reviewed the sanitized publication source at remote commit `7f62fff` (toolkit 0.0.3), with a clean docs branch based on that actual published commit. The native working tree contains pre-existing implementation/documentation edits and private deployment evidence; it is not substituted for the public source baseline. No runtime/controller/terminal requests, deployment, trade, cleanup or restart was used for this audit.

## Findings and disposition

The published index linked absent private task and verification files and a nonexistent HANDOFF. Listener tables mixed private LAN exposure with a loopback template. The distinction between legacy template generation and adaptive overlay was missing: base template nodes use DISPATCH, while overlay generation introduces PROXY-UPLINK. Current guides mixed historical calibration/incident results with operating instructions. The HTML design surface still claimed an active retired HypoMux topology and universal measured acceptance.

Revised the overview, index, architecture, configuration, dispatch, operations and development guides. Added the missing interface/provenance contract guide, updated contributor/release navigation, and replaced the HTML design surface with the native topology. Removed duplicate historical speed narratives from canonical procedures; their original facts/dates remain in the prior published revision linked by the documentation index. Existing dated source verification is unchanged. No private task notes or raw deployment receipts were copied into public docs.

The source review covered wrapper actions, startup/recovery ownership, adapter guards, generation/overlay stages, activation/rollback, controller/observer state, dashboard/PAC interfaces, cache migration, dependency pins, runner options, source packaging and CI. CLI effect tables separate local-only work from controller reads, external probes and mutations. Provider request admission and data quality remain outside toolkit authority; no economic or production readiness claim is inferred from unit tests.

## Owned-document inventory

Published documentation includes all root Markdown and docs Markdown, plus web/design.html. Existing release verification is retained unchanged; AGENTS is reviewed and preserved as operator instruction. All canonical guides and documentation surfaces are reviewed; the new audit itself and checker source/tests are included in validation. Native-only historical/task records receive structural/date/ownership review rather than a fresh measurement audit. Their raw data, endpoints and machine-specific claims remain private and unverified by this task.

| Native owned Markdown | Review disposition |
|---|---|
| `AGENTS.md` | Reviewed and preserved unchanged in both trees; operator preferences remain intact. |
| `CONTRIBUTING.md` | Canonical native and published counterparts revised, with explicit native/source scope; unrelated implementation remains separate. |
| `README.md` | Canonical native and published counterparts revised, with explicit native/source scope; unrelated implementation remains separate. |
| `docs/README.md` | Canonical native and published counterparts revised, with explicit native/source scope; unrelated implementation remains separate. |
| `docs/current/ARCHITECTURE.md` | Canonical native and published counterparts revised, with explicit native/source scope; unrelated implementation remains separate. |
| `docs/current/CONFIGURATION.md` | Canonical native and published counterparts revised, with explicit native/source scope; unrelated implementation remains separate. |
| `docs/current/DEVELOPMENT.md` | Canonical native and published counterparts revised, with explicit native/source scope; unrelated implementation remains separate. |
| `docs/current/DISPATCH.md` | Canonical native and published counterparts revised, with explicit native/source scope; unrelated implementation remains separate. |
| `docs/current/HANDOFF.md` | Native-only handoff/operational context; retained privately, not a public dependency. |
| `docs/current/OPERATIONS.md` | Canonical native and published counterparts revised, with explicit native/source scope; unrelated implementation remains separate. |
| `docs/current/RELEASE-0.0.3.md` | Native design record reviewed/preserved; published counterpart adds navigation to this audit while retaining original release facts. |
| `docs/tasks/AMAZON-SPEEDUP.md` | Native historical/task evidence; dates retained, no receipt revalidation or publication copy. |
| `docs/tasks/BILIBILI-SPEEDUP.md` | Native historical/task evidence; dates retained, no receipt revalidation or publication copy. |
| `docs/tasks/GOODREADS-SPEEDUP.md` | Native historical/task evidence; dates retained, no receipt revalidation or publication copy. |
| `docs/tasks/ICLOUD-SPEEDUP.md` | Native historical/task evidence; dates retained, no receipt revalidation or publication copy. |
| `docs/tasks/SQX-DOWNLOAD.md` | Native historical/task evidence; dates retained, no receipt revalidation or publication copy. |
| `docs/tasks/WECHAT-HOTSPOT-SPEEDUP.md` | Native historical/task evidence; dates retained, no receipt revalidation or publication copy. |
| `docs/verification/2026-10-21.md` | Native historical/task evidence; dates retained, no receipt revalidation or publication copy. |
| `docs/verification/2026-10-25.md` | Native historical/task evidence; dates retained, no receipt revalidation or publication copy. |
| `docs/verification/2026-10-27.md` | Native historical/task evidence; dates retained, no receipt revalidation or publication copy. |
| `docs/verification/2026-10-28.md` | Native historical/task evidence; dates retained, no receipt revalidation or publication copy. |
| `docs/verification/2026-10-29-design.md` | Native historical/task evidence; dates retained, no receipt revalidation or publication copy. |
| `docs/verification/2026-10-29-phone.md` | Native historical/task evidence; dates retained, no receipt revalidation or publication copy. |
| `docs/verification/2026-10-30.md` | Native historical/task evidence; dates retained, no receipt revalidation or publication copy. |
| `docs/verification/2026-10-31-scholar.md` | Native historical/task evidence; dates retained, no receipt revalidation or publication copy. |
| `docs/verification/2026-11-01.md` | Native historical/task evidence; dates retained, no receipt revalidation or publication copy. |
| `docs/verification/2026-11-02-goodreads.md` | Native historical/task evidence; dates retained, no receipt revalidation or publication copy. |
| `docs/verification/2026-11-04-xvideos.md` | Native historical/task evidence; dates retained, no receipt revalidation or publication copy. |
| `docs/verification/2026-11-04-youtube.md` | Native historical/task evidence; dates retained, no receipt revalidation or publication copy. |
| `docs/verification/2026-11-07-toolkit-0.0.3.md` | Native historical/task evidence; dates retained, no receipt revalidation or publication copy. |

Both native and publication web/design.html documentation surfaces are revised to the native topology; the prior published version remains linked as historical evidence. Native dated task/verification files remain untouched. Native root/index/current canonical counterparts and the native HTML design page are substantively revised too, with explicit native scope and missing-helper notes; private HANDOFF is reviewed and retained unchanged, with its local references resolving. This native docs work is a separate local commit and is not copied wholesale into publication. Publication guide claims apply to the published source and do not silently certify a divergent private checkout.

## Documentation checks and limits

`tools/Check-Docs.py` checks root Markdown and docs/**/*.md inline relative links and heading anchors, excluding fenced examples. It does not fetch external URLs, parse embedded HTML/reference-style Markdown, validate live API readiness, or execute examples. Tests cover missing targets/anchors, duplicate and Unicode headings, escaped paths, code examples, external URLs, repository escapes and empty inventory. CI runs the checker on both Python platforms; extracted-source Python discovery also runs its regression.

HTML design links were reviewed against repository paths; external history links refer to the known source revision. Command names/defaults were checked against actual parameters and source, and safe help/comparison examples were executed offline. Dependencies were already installed for validation; no bootstrap, operational repair, health probes, lifecycle actions or private cache migrations were run to test prose.

Validation results and actual commit/tree/hosted acceptance are reported to the portfolio coordinator; dated release counts are not overwritten. Remaining limitations: no physical Windows/hotspot acceptance, no live endpoint entitlement/data review, no automatic shared-ICS exclusion model, and no general proof of provider or broker readiness. Native historical reports cannot be independently reproduced from the public checkout.

## Executed offline validation

The completed published inventory has 13 Markdown documents and 77 inline local references; the all-document checker reports zero errors. Native canonical review covers 12 Markdown documents and 85 references; the separate native all-record scan also reports zero errors. The native audit retains all original historical/task dates and content. Six checker regressions and the full 68-test Python suite pass; seven dashboard tests pass. Both Windows PowerShell 5.1 and PowerShell 7 repository audits pass all four checks. Python CLI help (attestation, documentation checker, full builder, dispatch) and same-template attestation were executed safely; comparison reports equal semantics. The cache sanitizer help was executed with module networking disabled and no database input. No operational examples were executed.

The workflow check is part of the source CI policy jobs, and the archive test runs Python discovery including the documentation regressions. The exact documentation commit/tree and final-SHA hosted outcome are handed to the portfolio coordinator rather than written into the file being committed. Successful source validation does not certify native deployment state.
