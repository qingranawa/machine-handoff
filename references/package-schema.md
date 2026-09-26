# Handoff Package schema v1

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
│   ├── source.previous.json       # only after UPDATE; one version
│   ├── destination.snapshot.json  # created by RESTORE/VALIDATE
│   ├── decisions.json
│   ├── diff.json
│   └── validation.json
├── evidence/collection-status.json
└── configs/                       # only for user-selected reviewed copies
```

Create no empty placeholder files. `PREPARE` creates the source snapshot, decisions, collection status, and seven reports. `UPDATE` atomically replaces generated files, retains decisions/configs, and keeps at most one prior source snapshot. Reports are generated views; record human path mappings, exclusions, and approvals in `decisions.json`.

## Snapshot

The machine-readable source of truth is JSON. Missing fields mean “not collected”; component `state` is `PRESENT|ABSENT|UNKNOWN`. A collector-level `status` is separate. Each item uses a stable `id`, `domain`, `state`, safe `evidence`, `confidence` (`CONFIRMED|INFERRED|UNKNOWN`), and `restorePolicy` (`RESTORE|REVIEW|SKIP`). Never rewrite old paths by string substitution.

Required root keys:

```json
{
  "schemaVersion": 1,
  "snapshotId": "uuid",
  "sourceId": "uuid-created-on-prepare",
  "role": "SOURCE",
  "collectedAt": "ISO-8601-with-offset",
  "platform": "windows",
  "collection": { "roots": [], "excludes": [], "maxDepth": 3, "domainStatus": {} },
  "system": {},
  "env": {},
  "software": [],
  "dev": [],
  "shell": {},
  "editors": [],
  "agents": [],
  "wsl": [],
  "dataLocations": [],
  "unbackedDataCandidates": [],
  "manualItems": []
}
```

Each `agents` item carries its own `configFiles` list; each list entry records only category/name, path, presence, and enablement (`UNKNOWN` unless safely inspected). Each `dataLocations` item has `id/type/state/sourcePath/targetPathCandidate/ownership/backupEvidence/transferAction/verification/readability`. Target path candidates are suggestions such as `%USERPROFILE%\Documents` or `%USERPROFILE%\Projects\<repo>`; data locations remain `REVIEW` until the user selects a destination. Each unbacked candidate has `path/reason/evidence/status`; initial status is `CANDIDATE`. `decisions.json` maps source IDs to explicit target paths, exclusions, restore policy changes, and approvals. It contains no secrets.

`decisions.json` uses `exclusions` as exact component keys (`domain|id`) and `policyOverrides` as `{ "component": "domain|id", "restorePolicy": "RESTORE|REVIEW|SKIP" }` entries. Overrides apply to the whole component; an exclusion takes precedence and means `SKIP`. Unless the snapshot or decisions file explicitly sets `RESTORE` or `SKIP`, the effective policy is `REVIEW`. An item with `REVIEW` is reported for human selection and cannot produce a missing-destination `FAIL`; only an explicitly selected `RESTORE` item is treated as required during validation. `UPDATE` preserves this file.

## Diff and status

Each diff item has `component`, `sourceState`, `destinationState`, `desiredState`, `restorePolicy`, `action`, `risk`, `safety`, `reason`, `preconditions`, `verification`, and `status`. `action` is `INSTALL|COPY|RECREATE|SYNC|REAUTHENTICATE|REVIEW|SKIP`; `risk` is `LOW|MEDIUM|HIGH`; `safety` is `AUTO|CONFIRM|MANUAL`. Keep risk and execution gate separate.

Validation status is `PASS|WARN|FAIL|UNKNOWN`. Attach the check time, evidence summary, and next step. A `PASS` requires current destination evidence. Save generated JSON through same-directory temporary files and atomic replacement; never leave a partially written manifest.

## Markdown mapping

- `HANDOFF.md`: old machine purpose, headline software/toolchain, highest-priority data paths, recovery order, blockers, and manual items.
- `SYSTEM.md`: OS/build, profile, volume letters, relevant settings, environment names, safe path values, and PATH by scope.
- `SOFTWARE.md`: package inventory and keep/review/skip decision.
- `DEVELOPMENT.md`: detected toolchain, shell, editors/extensions, and WSL.
- `AI_AGENTS.md`: detected agent/config categories, Skills/MCP/hooks/plugins/rules/permissions locations, and re-authentication checklist.
- `DATA.md`: data locations and unbacked candidates with uncertainty clearly stated.
- `MIGRATION_PLAN.md`: current plan, action gates, validation status, and blockers.

Escape Markdown table cells and line breaks. Recheck generated text for secret patterns before writing.
