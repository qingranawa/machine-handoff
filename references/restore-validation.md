# Restore, diff, and validation

## Command inputs

- Prepare: `-Mode Prepare -PackagePath <new-package>`, with optional `-Roots <path...>`, `-Excludes <path...>`, and `-MaxDepth <0..12>`.
- Update: `-Mode Update -PackagePath <existing-package>`.
- Restore/validate: `-Mode Restore|Validate -PackagePath <package>`, with optional confirmed target `-Roots`.
- Diff: `-Mode Diff -SourceSnapshotPath <source.json> -DestinationSnapshotPath <destination.json>`; optional `-PackagePath` writes `manifests/diff.json`, otherwise the script emits the filtered diff JSON.
- `-SafeMode` skips the winget export and WSL command probe. Use it for local collector checks; the corresponding status is `NOT_TESTED`.

Pass PowerShell arguments as an argument list so Unicode and whitespace in paths stay intact. The script never joins a user path into a shell command.

## RESTORE

Always collect the destination first, then validate both snapshots and write `destination.snapshot.json`, `diff.json`, and `MIGRATION_PLAN.md`. Present the plan and wait for the user's approval of the named operations before acting. Re-check each precondition immediately before a change. If a target exists, compare it and switch that item to `REVIEW`; never overwrite it.

The v1 scripts write Package output only. They do not install applications, copy user configs, change environment variables, start WSL distros, export/import WSL, or synchronize projects. The Agent may create a named empty destination directory only after the user approves that specific action. For other work, provide a concrete command or manual step in the plan and execute only after the user approves that operation. Require manual re-authentication for accounts, tokens, SSH/GPG keys, Credential Manager, and MCP connections.

Suggested order: confirm target volumes and data destinations; install explicitly retained base tools; restore reviewed editor/agent settings; map or synchronize repositories and data; handle WSL only when its export/import plan is explicitly approved; re-authenticate; validate.

## DIFF

Diff is read-only. Compare stable IDs and normalized fields; show source, destination, desired state, evidence, and a conservative suggested action. A version difference or changed drive letter is a review item, not proof of failure. Do not infer package install success from source presence.

## Action gates

| Action | Default safety | Rule |
| --- | --- | --- |
| `INSTALL` | `CONFIRM` | Name exact package and source; install only after approval. |
| `COPY` | `CONFIRM` or `MANUAL` | Only user-selected reviewed files; target must be absent or separately approved. |
| `RECREATE` | `CONFIRM` | Show exact setting/path and destination. |
| `SYNC` | `CONFIRM` | Identify source and destination and explain existing-content conflict. |
| `REAUTHENTICATE` | `MANUAL` | User completes sign-in/secret setup; never transport credentials. |
| `REVIEW` | `MANUAL` | Resolve uncertainty or conflict before changes. |
| `SKIP` | `AUTO` | State why it is excluded. |

`AUTO` is limited to package reports and approved empty directories. Safety gate is independent from risk. Never run destructive restore, unregister a WSL distribution, delete or replace user data, or elevate privileges automatically.

## VALIDATE

Re-collect the destination read-only and check selected items only. Return `PASS|WARN|FAIL|UNKNOWN` with time, evidence, and next action. Check:

Select items in `manifests/decisions.json` using exact `domain|id` keys in `policyOverrides`, with `restorePolicy` set to `RESTORE`, `REVIEW`, or `SKIP`. An exclusion forces `SKIP`; unspecified items remain `REVIEW`. Only selected `RESTORE` items can fail because they are absent at the destination.

- retained software and PATH/environment entries;
- Git, Node/npm/pnpm, Python, .NET, and other selected toolchains;
- selected WSL distro/version/config and explicit project paths;
- IDE launch and selected extension IDs;
- agent instructions/rules/Skills/MCP/hooks/plugins/permissions files and enabled state;
- repository branch, dirty/untracked and local upstream ahead/behind counts;
- each priority data destination exists and is readable.

GUI launches, login, live MCP connectivity, and remote backup parity are `UNKNOWN` until separately observed. A missing tool is `FAIL` only when selected for restore; otherwise `WARN` or `SKIP`. Do not use a generic test framework.

For WSL, `/etc/wsl.conf` is inspected only in distributions already running at collection time. Stopped distributions and `-SafeMode` probes remain `UNKNOWN`/`NOT_TESTED`; collection must never start a stopped distro.
