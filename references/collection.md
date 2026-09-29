# Collection rules

## Profiles and budgets

Select `-Profile Standard` or `-Profile Deep`; default is `Standard`. `-SafeMode` is independent and skips winget export and WSL command probing.

| Budget | Standard | Deep |
| --- | ---: | ---: |
| Global collection deadline | 120 s | 600 s |
| Per-domain deadline | 20 s | 60 s |
| Per-process timeout | 5 s | 10 s |
| Captured stdout/stderr | 64 KiB each | 256 KiB each |
| Explicit roots | 16 | 32 |
| Max depth | 3 | 8 |
| Directories per scan | 2,000 | 10,000 |
| Total queued directories | 2,000 | 10,000 |
| Files inspected in bounded discovery | 5,000 | 20,000 |
| Config file size | 256 KiB | 1 MiB |
| Config artifact count | 64 | 256 |
| Sanitized artifact bytes | 2 MiB | 20 MiB |
| Changed Package output bytes | 10 MiB | 40 MiB |

The first limit reached produces a partial result and a fixed warning. Domains run independently; failure in one does not erase other results. Process output is capped as it is read, timeout/cancellation kills the child, and only allowlisted parsed values leave the collector.

Package JSON input is independently capped at 40 MiB; nesting depth, per-container entries, token count, and string size also have hard limits. Generation manifests are capped at 1 MiB/4096 entries, and generation verification reads at most 40 MiB total. These input limits apply when opening existing packages, separately from collection/output budgets.

## Boundaries

Collect only Windows workstation facts that affect development, daily work, software recovery, or data location. The workstation summary includes architecture, CPU, RAM, GPU and logical-disk summaries, four fixed Optional Features (WSL, VirtualMachinePlatform, Hyper-V, Windows Sandbox), Developer Mode, Long Paths, user/WinHTTP proxy endpoints without credentials, PowerToys, and Windows Terminal. It does not enumerate all hardware, devices, drivers, services, scheduled tasks, or an entire disk. Read the current user's known configuration locations, limited uninstall registry keys, and explicitly selected roots.

Default roots are Documents, Desktop, and existing conventional project folders directly under the user profile (`Projects`, `Source`, `Repos`, `workspace`, `dev`). Add only user-supplied roots. A detected OneDrive root is recorded as a sync location but is traversed only when explicitly selected. Probe the conventional Documents Obsidian Vault path if present. Deep additionally detects bounded project markers, Compose roots, Obsidian `.obsidian` directories, local database filenames, and local workspace paths from VS Code/Cursor `workspace.json` metadata. Workspace hints are recorded but not recursively traversed. Shell history and SQLite workspace-state databases are not read.

Repository discovery depth is profile-bounded. Each confirmed Git repository is checked using a read-only local `git rev-parse --is-inside-work-tree`; a `.git` marker alone is only a candidate. Git status includes branch, clean/dirty/untracked counts, remote names only, and ahead/behind against already-known tracking refs. Never fetch. Reparse points, symlinks, junctions, excluded paths, cloud-sync roots not explicitly selected, and heavy generated directories are not traversed.

The collector contract is `New-MHDomainResult -Domain <name> -Status <status> -Items <items> -Warnings <fixed-codes> -ConfigArtifacts <artifacts>`. Context carries `profile`, roots/excludes, depth, deadlines, cancellation, artifact counters, and budgets. Domain status is one of `OK|PARTIAL|UNAVAILABLE|ERROR`; component state is `PRESENT|ABSENT|UNKNOWN`. Persist provenance and collection time, never raw stderr or exception text.

## Domain coverage

- `system` / `workstation`: Windows product/build, current user profile, fixed volume letters and a bounded development-workstation hardware/feature/proxy/app summary.
- `env`: user/machine environment variable names and presence, allowlisted path-valued variables, and filtered PATH entries.
- `software`: targeted Add/Remove Programs data, optional winget package IDs, and selected portable-app candidates. Treat unmatched packages as review items.
- `dev` / `toolchains`: Standard records fixed versions for common tools. Deep adds Node managers/global packages, Python launchers/managers/environments/tools, .NET SDK/runtime/workload/global tools, Rust toolchains/targets/components/Cargo tools, Java/JDKs/Maven/Gradle, Go environment/tools, C/C++ tooling, Windows SDK, and Visual Studio instances/workloads/components via `vswhere`.
- `git` / `shell`: Deep collects allowlisted Git settings, config scopes/origins, include/includeIf metadata, credential-helper type, signing metadata, PowerShell versions/modules/repositories/execution policies/Profile locations, and prompt-tool metadata. It never follows include files or runs Profiles.
- `editors` / `agents`: Standard records known locations and shallow metadata. Deep adds VS Code/Cursor extensions and profiles, JetBrains products/plugins/keymaps/code styles/JVM option metadata; safe settings, keybindings, snippets, rules, prompts, and MCP definitions use the config artifact pipeline. Executable hooks/tasks/rules stay metadata-only and review-gated.
- `wsl` / `wslDeep`: installed distro list/version/running state, default distro/version, and selected `.wslconfig` values; `/etc/wsl.conf` and toolchain clues are read only in a distro still reported as running by a second `wsl --list --running --quiet` check. Probes use `sh -c`, never a login shell. Stopped distros are `NOT_TESTED_NOT_RUNNING`; SafeMode skips all WSL process probes.
- `platformTools`: Docker/Podman versions, local context metadata, bounded Compose paths and static Docker Desktop WSL settings; daemon images/containers/volumes remain `NOT_TESTED`. SSH records allowlisted host directives, public-key fingerprints and agent status. GPG records public fingerprints/signing mapping. Private keys remain `MANUAL_TRANSFER_REQUIRED` and are never opened.
- `data`: data roots, Git status, non-Git projects, Compose roots, Obsidian Vaults, local database candidates, editor workspace path hints, and unbacked-data candidates. File bodies and database contents are not read.

## Secret-safe configuration

Configuration files use one of `METADATA_ONLY`, `SAFE_COPY`, `REDACTED_COPY`, `MANUAL_TRANSFER`, or `NEVER_COLLECT`. Only JSON, JSONC, bounded text, and INI are currently eligible for body capture. JSON/JSONC secrets are replaced structurally; supported text patterns redact auth tokens, password fields, URL userinfo, and bearer values, then a final output scan runs. `.npmrc` and pip INI may be captured as `REDACTED_COPY`; unsupported Yarn YAML/TOML/NuGet XML remain metadata-only. Malformed, oversized, unsafe-path, unsupported, or still-sensitive content fails closed with a fixed code.

## Workstation output

No collector reads arbitrary file contents unless a supported Deep config artifact was selected by policy. No test prints private paths or config bodies. Local verification uses synthetic roots and fake command results. `SafeMode` keeps winget export and WSL probing unrun while preserving `NOT_TESTED` status.
