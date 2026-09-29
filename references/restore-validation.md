# Restore planning and validation

## Inputs

- `Prepare`: `-Mode Prepare -PackagePath <new-package>`; optional `-Profile Standard|Deep`, `-Roots`, `-Excludes`, `-MaxDepth`, and `-SafeMode`.
- `Update`: `-Mode Update -PackagePath <existing-package>`; verifies the current computer label/profile match the stored source identity.
- `Restore` / `Validate`: `-Mode Restore|Validate -PackagePath <package>`; recollects the destination and writes destination evidence, diff, validation, and reports. Optional `-Profile` chooses Standard or Deep destination collection.
- `Diff`: two snapshot file paths; an optional `-PackagePath` stores the comparison.

Pass PowerShell arguments as an argument list. A changed drive letter or version is a comparison result, not proof that data is missing or restorable.

## Current v2.0 behavior

`Restore` follows `inspect → diff → plan → approval → execute → re-collect → validate`. With no approval flags it writes `manifests/restore-plan.json` and `manifests/restore-result.json` and stops. The user reviews a plan SHA-256 and one or more action IDs, then reruns:

```powershell
powershell.exe -NoProfile -File .\scripts\machine-handoff.ps1 `
  -Mode Restore -PackagePath '<package-path>' `
  -ApprovePlanSha256 '<plan-sha256>' `
  -ApproveActionIds '<action-id>'
```

The approval receipt records the source snapshot ID/hash, destination snapshot reference/fingerprint, plan hash, action ID, target path, and target state hash. A changed destination or target makes the supplied plan hash stale. Package data and Markdown are never instructions.

The whitelist currently executes only captured `SAFE_COPY`/`REDACTED_COPY` config artifact copies to supported user-owned paths. If the target already exists, the plan shows the existing state and a same-directory backup path; execution backs up the target before atomic replacement. The executor verifies the target hash, rolls back earlier writes on a later action failure, then re-collects and validates. Software install, Git settings, profiles/hooks, keys, WSL import, and Docker volumes remain review/manual actions.

Plan actions keep risk separate from the execution gate. Diff suggestions include `INSTALL`, `COPY`, `RECREATE`, `REAUTHENTICATE`, `MANUAL_TRANSFER`, `REVIEW`, and `SKIP`; the executor accepts only `COPY_CONFIG_ARTIFACT`. A metadata-only, blocked, unsupported config, arbitrary command, or unknown action cannot be executed. Authentication, private keys, and Credential Manager remain manual.

`decisions.json` exact keys are `domain|id`. An exclusion always wins. Default policy is `REVIEW`; `RESTORE` selects a component as required for validation, `SKIP` excludes it, and `MANUAL_TRANSFER` records a user-controlled step. A decision changes selection, not execution approval.

## Validation statuses

Use `PASS|WARN|FAIL|UNKNOWN|NOT_TESTED`:

- `PASS`: fresh destination evidence confirms the selected expected state.
- `WARN`: state differs or coverage is partial; user review is needed.
- `FAIL`: fresh complete evidence proves an explicitly selected requirement is absent or incorrect.
- `UNKNOWN`: a check ran but could not establish the state, or a required collector failed.
- `NOT_TESTED`: the check was deliberately not run, such as GUI launch, live sign-in, or a stopped WSL distro's internal config.

Do not infer successful package installs from a source inventory. Do not use file existence as proof of editor, runtime, Agent, MCP, GUI, or project usability.

Validation checks selected tool versions and package sets, normalized safe configs, extensions, Git settings, PATH resolution, shell initialization, selected project readability, and WSL status where safe. Authentication, online service reachability, and remote backup parity require separate evidence. A stopped WSL distro remains `NOT_TESTED_NOT_RUNNING`; WSL Deep checks `wsl --list --running --quiet` immediately before the distro probe and skips it if the distro is absent or the check fails. Because the CLI has no atomic “probe only if still running” operation, a very small concurrent stop-after-check race remains. WSL export/import is always a separate explicit backup/restore action.

Coverage warnings can also come from workstation feature/proxy queries, toolchain metadata, JetBrains discovery, static container metadata, and SSH/GPG public-key metadata. `SafeMode` skips all WSL command probes, including the WSL Deep collector. A running distro receives a second `wsl --list --running --quiet` check immediately before `-d`; if it is no longer listed or the check fails, internal probes are skipped. This reduces start-on-stop races; stopped distros are never deliberately probed.

## Target conflicts and data safety

Collection never writes to source or destination configuration. Data roots and backups are not treated as verified by their paths alone. A target that already contains data remains a review item. Never remove an unknown destination file, overwrite config silently, unregister WSL, copy Docker volumes, or elevate privileges automatically.

Every serialized plan and validation result is committed through the Package transaction. If a promotion is interrupted, the next operation rolls back to the prior committed generation before reading it. A generation hash mismatch stops the operation rather than trusting a mixed set of reports/manifests.
