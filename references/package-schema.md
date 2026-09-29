# Handoff Package schema v2

## Package layout

```text
machine-handoff/
├── HANDOFF.md
├── SYSTEM.md
├── SOFTWARE.md
├── DEVELOPMENT.md
├── AI_AGENTS.md
├── DATA.md
├── MIGRATION_PLAN.md
├── manifests/
│   ├── source.snapshot.json
│   ├── source.previous.json       # UPDATE keeps one prior source snapshot
│   ├── destination.snapshot.json  # RESTORE / VALIDATE
│   ├── decisions.json
│   ├── configs.json
│   ├── diff.json
│   ├── validation.json
│   ├── restore-plan.json
│   ├── restore-result.json
│   └── generation.json            # committed file list and hashes
├── evidence/collection-status.json
└── configs/                       # content-addressed, sanitized artifacts only
```

`PREPARE` starts with an empty Package. `UPDATE` retains decisions and prior configuration artifacts, writes a new source snapshot and report generation, and keeps at most one prior source snapshot. `RESTORE` writes destination evidence, diff, validation, a restore plan, and an execution result. With no approval flags it stops after planning. v2.0 can execute approved config artifact copies only; installs and all other unsupported actions remain review/manual. `DIFF` remains read-only unless a Package output path is explicitly supplied. Reports are human-readable views; JSON manifests are the machine-readable state.

Every write generation is staged in the Package directory, checked for safe serialization, then promoted file by file with a rollback journal. `manifests/generation.json` is the commit marker and records SHA-256 for generated files. Before a later operation reads or updates a Package, the tool recovers an interrupted promotion or refuses an inconsistent generation. Config artifact filenames include a prefix of the sanitized-content hash so changed versions do not overwrite earlier reviewed copies.

`manifests/decisions.json` is intentionally user-editable and is not included in generation hashes. It is still size-bounded, secret-scanned, and schema-validated when read. Decision changes select desired state but never approve restore execution.

## Snapshot v2

The source of truth is JSON. Missing fields mean “not collected”; component `state` is `PRESENT|ABSENT|UNKNOWN`, separate from collector `status` (`OK|PARTIAL|UNAVAILABLE|ERROR`). Standard and Deep use the same schema. Deep records its profile and bounded budgets; it does not mean unrestricted collection.

Required v2 root keys include:

```json
{
  "schemaVersion": 2,
  "snapshotId": "uuid",
  "sourceId": "uuid-created-on-prepare",
  "role": "SOURCE",
  "collectedAt": "ISO-8601-with-offset",
  "platform": "windows",
  "profile": "Standard",
  "collection": {
    "roots": [],
    "excludes": [],
    "maxDepth": 3,
    "profile": "Standard",
    "budgets": {},
    "domainStatus": {}
  },
  "system": {},
  "env": {},
  "software": [],
  "dev": [],
  "shell": {},
  "editors": [],
  "agents": [],
  "git": [],
  "wsl": [],
  "dataLocations": [],
  "unbackedDataCandidates": [],
  "configArtifacts": [],
  "manualItems": []
}
```

Domain items have stable `id` values. The top-level schema remains compatible: workstation details are nested under `system`; runtime/compiler and static container/SSH/GPG tool summaries are represented in `dev`; IDEs (including JetBrains) remain under `editors`; WSL Deep appears as a WSL summary item. `domainStatus` records additional `workstation`, `wslDeep`, `toolchains`, `platformTools`, `containers`, `ssh`, and `gpg` coverage where available, with safe warnings, provenance, time, and coverage metadata.

### v1 compatibility

Readers accept schema v1 as metadata-only facts. A v1 path record is never upgraded into a captured config artifact. Writers create v2 snapshots. V1 decisions remain usable, but do not imply approval for future restore actions.

## Config artifacts

`configArtifacts` contains metadata only; artifact bodies are stored separately under `configs/`. Every record uses:

```json
{
  "id": "editors:vscode:user-settings",
  "domain": "editors",
  "sourceLocator": "%APPDATA%\\Code\\User\\settings.json",
  "targetPathCandidate": "%APPDATA%\\Code\\User\\settings.json",
  "contentPolicy": "REDACTED_COPY",
  "sensitivity": "PRIVATE",
  "captureState": "CAPTURED",
  "redactionStatus": "REDACTED",
  "artifactPath": "configs/editors/settings.<content-hash>.json",
  "artifactSha256": "sha256-of-sanitized-content",
  "restorePolicy": "REVIEW",
  "dependsOn": ["runtime:vscode"],
  "validationStrategy": "NORMALIZED_CONFIG"
}
```

`contentPolicy` is one of:

- `METADATA_ONLY`: safe metadata only; no body.
- `SAFE_COPY`: full body only for a specifically supported and checked source/format.
- `REDACTED_COPY`: structure is retained after supported redaction and re-parse.
- `MANUAL_TRANSFER`: body is not captured; user-controlled migration is required.
- `NEVER_COLLECT`: body is never read into the collection pipeline.

`captureState` is `CAPTURED|METADATA_ONLY|REVIEW_REQUIRED|BLOCKED|NOT_FOUND|ERROR|NOT_TESTED`. `redactionStatus` is `NOT_REQUIRED|REDACTED|BLOCKED|NOT_APPLICABLE|NOT_TESTED`. A `CAPTURED` record must include a relative `configs/...` path and SHA-256 over the sanitized output; other capture states have no artifact path or hash. Supported config paths reject reparse ancestors and traversal outside the Package.

Unsupported, malformed, oversized, or unredactable formats fail closed: the snapshot keeps a fixed status/error code and no body. JSON and JSONC are structured-redacted. Supported text formats use bounded secret patterns; this is a filter, not a claim that every arbitrary secret is recognizable. Executable profiles/hooks/rules remain `REVIEW` and are never run by validation.

`manifests/configs.json` indexes metadata for saved artifacts. Files are content-addressed; existing reviewed artifacts are preserved across updates. Keep the Package private because paths and toolchain facts can identify the user or workstation.

The v1.6 toolchain collector currently keeps Cargo configuration and Rustup settings metadata-only, and marks Cargo credentials, Maven settings, Gradle properties/init scripts, and NuGet configuration `NEVER_COLLECT`. JetBrains keymap/code-style/JVM option files are recorded as metadata-only. Docker auth configuration is detected by path presence only; its content is never read.

## Restore plan v1

`manifests/restore-plan.json` records a deterministic `planSha256`, the source snapshot identity/hash, normalized destination fingerprint, and ordered action candidates. Action IDs are derived from the component, action type, source artifact hash, and exact target. Current action types are `COPY_CONFIG_ARTIFACT` and non-executable `REVIEW_ONLY`. A copy action records its target path, current target state/hash, and a same-directory backup path when replacement is needed. Duplicate targets, missing dependencies, dependency cycles, unsupported action types, and unsafe target paths block the plan.

Users approve by rerunning `Restore` with both `-ApprovePlanSha256 <sha256>` and `-ApproveActionIds <id>`. The plan hash binds the source snapshot, normalized destination state, action IDs, source artifacts, targets, conflicts, and backup paths. Any changed destination or target makes an earlier approval stale. `manifests/restore-result.json` stores an approval receipt with those bindings and action execution/rollback/re-collection validation results. Software installation, Git config changes, profile/hook execution, key import, WSL import, and Docker volume operations remain manual or review-only.

## Decisions, diff, and validation

`decisions.json` remains schema v1. It uses exact component keys (`domain|id`) in `exclusions` and `policyOverrides`; supported values are `RESTORE|REVIEW|SKIP|MANUAL_TRANSFER`, with exclusion taking precedence. Unspecified components default to `REVIEW`. Decisions select desired state; they are not by themselves execution authorization. v2.0 approval is a separate plan-hash/action-ID binding stored in `restore-result.json`.

Diff v2 compares stable IDs and normalized fingerprints, including Git allowlisted settings and config artifact hashes. A missing/failed collector cannot turn an unobserved absence into an install or copy action. Actions include `INSTALL|COPY|RECREATE|SYNC|REAUTHENTICATE|MANUAL_TRANSFER|REVIEW|SKIP`. `risk` (`LOW|MEDIUM|HIGH`) and `safety` (`AUTO|CONFIRM|MANUAL`) are separate fields. Only explicitly approved `COPY_CONFIG_ARTIFACT` actions execute in v2.0; other suggestions remain non-executable.

Validation v2 statuses are `PASS|WARN|FAIL|UNKNOWN|NOT_TESTED`. A `PASS` needs fresh destination evidence. A selected item may `FAIL` when current evidence confirms it is absent; a blocked, partial, or unrun check cannot be reported as passing. Authentication, GUI launch, MCP connectivity, remote backup parity, and metadata-only configs are not inferred from path existence.

## Markdown mapping

- `HANDOFF.md`: source-machine purpose, headline tools, data paths, recovery order, and blockers.
- `SYSTEM.md`: OS/build, relevant workstation settings, safe environment facts, and PATH by scope.
- `SOFTWARE.md`: package inventory and review state.
- `DEVELOPMENT.md`: toolchains, shell, editors/extensions, and WSL status.
- `AI_AGENTS.md`: safe agent/config categories, rules/Skills/MCP/hooks/plugins metadata, and reauthentication needs.
- `DATA.md`: data locations and unbacked candidates, with uncertainty explicit.
- `MIGRATION_PLAN.md`: current diff, action gates, validation, and unresolved items.

Escape Markdown table cells and line breaks. Scan every generated JSON/Markdown/config string before commit-marker publication. Never persist raw process output or exception text.
