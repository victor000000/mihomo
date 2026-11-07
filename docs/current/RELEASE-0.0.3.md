# Toolkit 0.0.3 review

The checkout had no toolkit release version. `VERSION` establishes 0.0.3; this does not change the separately versioned Mihomo engine. Existing native networking and recovery work remains in progress in this working tree. This release is source preparation, with no deployment or live network acceptance.

## Design and critical review

Recent provider investigations repeatedly needed private, handwritten comparisons of runtime configuration and backups. Add a local comparison command that records byte hashes, semantic equality and affected sections while withholding configuration values. Keep it independent of the controller, terminal, credentials, market requests and deployment helpers. It reads exactly the two supplied files and prints JSON.

The main design risk is treating equal Theta rules as admission or effective route proof. The report explicitly excludes those conclusions: earlier rules, group membership, upstream definitions, loaded state and existing sessions can still matter. It is a review aid, not an authorization or attestation of who edited a file. Schema version 1 permits future report evolution.

Reject duplicate mappings, YAML merges, recursive structures, invalid section shapes and non-JSON scalar types instead of silently accepting ambiguous inputs. Suppress YAML parser error details because they may include secret source lines. Field names from arbitrary YAML mappings are withheld alongside values. Preserve ordering of rules and group members when comparing semantics. Self-review caught Python's boolean/integer equality ambiguity; canonical JSON comparison and a regression now distinguish these changes.

Shared ICS adapter exclusions during rebuild remain deferred. Automatically inferring ownership from stale deployment state would be unsafe; a separate policy and activation review is needed. This release does not claim to fix the broader live networking design.

## Changes

- `tools/Attest-Config.py`: offline comparison with redacted section summaries and SHA-256 byte fingerprints.
- `tests/gateway/test_config_attestation.py`: formatting, rule precedence, proxy changes, redaction, malformed inputs, CLI failures and boolean/number distinctions.
- `VERSION`: initial toolkit version, included by the source bundle builder.
- The verified sanitized publication baseline already contains the compatible observer syntax and typed JSON timestamp fix. Those prerequisites were retained. Added offset-timestamp coverage and unique per-fixture route-guard mutexes for parallel engine isolation.
- CI now verifies packaged source hashes and VERSION, then runs Pester, Python and Node suites on the extracted source with explicitly installed dependencies.

## Usage

```powershell
python .\tools\Attest-Config.py .\state\review\before.yaml .\state\review\candidate.yaml
```

PyYAML is already pinned in `tests/requirements.txt`. Output may be redirected to a private review artifact. Exit 0 means both files were compared, including when they differ; exit 2 means no comparison could be made. Duplicate keys and YAML merge syntax require explicit mappings before comparison. The command does not validate configurations with Mihomo, load them, identify an author or establish application readiness.

## Validation

Validation results and publication provenance are recorded in [the dated verification note](../verification/2026-11-07-toolkit-0.0.3-publication.md). No deployment, repair, terminal-status requests, market requests, adapter manipulation or session interruption is part of this release review.
