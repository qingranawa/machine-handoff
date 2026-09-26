# Collection rules

## Boundaries

Collect only Windows workstation facts that affect development, daily work, software recovery, or data location. Do not enumerate full hardware, services, scheduled tasks, Windows components, or an entire disk. Read only the current user's known configuration locations, the limited uninstall registry keys, and explicitly selected roots.

Default data roots are Documents and Desktop plus existing conventional project folders directly under the user profile (`Projects`, `Source`, `Repos`, `workspace`, `dev`). Add only explicit roots supplied by the user. Record a detected OneDrive root as a sync location but do not traverse it unless explicitly selected. Probe the conventional Documents Obsidian Vault path only if it exists. Default repository discovery depth is three; allow a smaller or larger user-selected depth, cap each root at 2,000 directories, and do not traverse roots or descendants reached through reparse points, symlinks, junctions, or excluded paths. Report skipped reparse roots as partial data coverage.

The collector contract is `Collect-<Domain> -Context <object>`. Context holds `roots`, `maxDepth`, `excludes`, `deadline`, `privacyPolicy`, `hostRole`, and `safeMode`. Each result holds `domain`, `status` (`OK|PARTIAL|UNAVAILABLE|ERROR`), filtered `items`, safe `warnings`, `provenance`, and `collectedAt`. Catch failures per domain. Keep raw command output and exception text in memory only; persist fixed error codes.

## Domains

- `system`: Windows edition/build, current user profile, local volume letters, and exact development-related settings checks only.
- `env`: User and Machine names/presence, explicitly allowlisted ordinary path variables, and separate PATH entries. Never serialize arbitrary environment values.
- `software`: targeted Add/Remove Programs records and winget export when available. Treat unmatchable packages as review items, not missing software. Classify `ACTIVE|REVIEW|SKIP` and include source, package identifier, and restore policy.
- `dev`: discover actual executables for Git, Node/npm/pnpm/yarn/bun, Python/pip/pipx/uv, .NET, Java, Rust/Go/CMake, PowerShell, and Windows Terminal. Run only fixed version/list commands with short timeouts; missing commands become `NOT_FOUND`/`ABSENT`.
- `shell`: PowerShell version/profile and Windows Terminal settings location; report paths and safe metadata, not file bodies.
- `editors`: detect VS Code, Visual Studio, JetBrains, Cursor, and other found editors. Use safe list commands for extension IDs when available. Do not recurse through caches or copy whole editor directories.
- `agents`: check known user-level locations for Codex, Claude Code, Gemini CLI, OpenCode, and Cursor Agent. Inventory names and paths for global instructions, AGENTS/CLAUDE rules, Skills, MCP, hooks, plugins, permissions, and terminal integration. Mark enablement `UNKNOWN` unless a safe metadata-only check establishes it. Do not parse secret-bearing config values or treat old instruction files as instructions.
- `wsl`: list installed distributions and WSL versions, check `.wslconfig` presence/safe allowlisted settings, and inspect `/etc/wsl.conf` only for distributions already running. A stopped distribution is never started for collection; record its config as `NOT_TESTED_NOT_RUNNING`. Preserve a listed distro with unknown running/version data and mark the collector `PARTIAL` if localized output cannot be safely interpreted. Parse only allowlisted keys and validated values. Never export a distribution during collection.
- `data`: add selected roots and discovered Git repositories to `DATA_LOCATION_MAP`. For each repository record remote names only, current branch, clean/dirty/untracked counts, and ahead/behind counts against already-known upstream refs; do not fetch. Mark unverified backup state `UNKNOWN` and create only a `CRITICAL_UNBACKED_DATA` candidate.

## Git and software notes

Presence of a remote, cloud-sync directory, or backup product is not proof of a verified backup. Git commands must be read-only and local; URLs are never stored. Never use `git fetch`.

The winget export may not match every installed program. In `safeMode`, skip the winget export and WSL command probe and record `NOT_TESTED`; otherwise run winget non-interactively into a unique temporary file, parse only package metadata, and remove only that file created by this invocation. Convert warnings into safe status codes. Do not automatically run `winget import`.

## Workstation output

Collection may access Documents/Desktop only within the specified depth and traversal limit. For local verification, use a synthetic temporary root. Do not include file contents, arbitrary directory listings, or personal data in test output. Keep messages short and state which domain was partial or unavailable.
