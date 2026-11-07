# Contributing

Start with [architecture](docs/current/ARCHITECTURE.md) for the supported design and [development](docs/current/DEVELOPMENT.md) for dependencies, tests, and source packaging. Live deployment procedures belong in [operations](docs/current/OPERATIONS.md).

## Scope and ownership

- Inspect the working-tree changes before editing. Preserve work from the owner and other workers; do not stage, revert, clean, or commit unrelated files.
- Agree on file ownership when work is parallel. Untracked and ignored files may already belong to someone; use unique temporary directories for test controls.
- Keep root `.bat` entry points stable. Routing, recovery, task registration, and fallback changes need focused review and behavior-based regression coverage.
- Maintain the native Windows/Mihomo design. Retired VM and HypoMux startup configurations are historical material.

## Protect deployment data

Never commit live credentials, subscription URLs or tokens, runtime configuration, generated logs, captures, binaries, downloaded dependencies, or test results. Use sanitized templates and synthetic fixtures. Review the complete diff and run the repository secret check before sharing.

`state/`, `.tools/`, `artifacts/`, and deployed contents of `runtime/` are local data. The versioned exception is `runtime/mihomo-supervisor.ps1`. Ignored files may contain learned rules, accounting, exports, and recovery backups; do not delete them as routine cleanup. The ignored `mihomo-src/` clone has separate ownership and history.

Keep dependency acquisition in its own directory. Do not run tools from an untrusted extracted directory or install test dependencies globally.

## Validation and documentation

Default tests must use fixtures, mocks, and temporary files. They must not contact public services, spend a proxy subscription, invoke live repair tools, or require deployed secrets. Live probes and activation belong to explicitly requested operator work; document their effects and recovery steps.

Use the [development commands](docs/current/DEVELOPMENT.md#checks-and-tests) appropriate to the change. Report actual outcomes, engines, failures, and skips. A source test pass does not establish current network health.

Update the guide that owns the changed behavior rather than repeating instructions across files. Keep current procedures under `docs/current/`, deferred work under `docs/tasks/`, and dated measurements under `docs/verification/`. Follow the [documentation maintenance rules](docs/README.md#maintaining-the-docs).

## Documentation review

Inventory root Markdown, docs guides/release records and the web/design.html documentation surface. Compare canonical procedures against the exact source baseline; distinguish sanitized publication defaults from private runtime values. Keep dated verification records immutable and link corrections from current guides. Run `python tools/Check-Docs.py` and the repository audits. The checker covers inline local Markdown links/anchors; embedded HTML, external links and command effects require separate review. Never execute a live procedure solely to validate prose.
