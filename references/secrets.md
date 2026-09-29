# Secret handling

Treat the generated Handoff Package as private workstation data. It may contain user paths, tool versions, configuration paths, and reviewed sanitized configuration copies. Never upload it automatically or place it inside a project repository.

## Never collect

Do not read or persist bodies of:

- SSH or GPG private keys and private certificates;
- Credential Manager stores and browser credential/cookie databases;
- `.env` files, cloud credential secret files, OAuth/session caches, or Agent authentication caches;
- BitLocker recovery material or other recovery keys.

When a collector can safely establish that one of these sources exists, record only a fixed status and a manual reauthentication/transfer task. Do not hash secret contents, record prefixes/suffixes/lengths, or persist raw command output or exception text.

## Supported capture pipeline

```text
source classification
→ read-policy check
→ bounded path/size/encoding check
→ structured parse where supported
→ field-aware redaction
→ generic high-confidence secret checks
→ parse/serialize verification
→ Package-wide output scan
→ staged write and commit manifest
```

Deep currently supports structured JSON/JSONC redaction and bounded text/INI redaction for selected config sources, including `.npmrc` and pip INI files. It retains nonsecret fields such as commands, public registry/index URLs, paths, and nonsecret settings when parsing succeeds. URL userinfo, auth tokens, connection-string user IDs and passwords (including braced `Pwd=` values), cookies, authorization values, JWTs, known token shapes, and PEM private-key markers are redacted or block the artifact. All saved artifact hashes cover sanitized content only.

Structured string leaves are also scanned for embedded secret assignments, even when the JSON property name is ordinary. JSON/package input is bounded before parse: 40 MiB maximum bytes, depth 64, 10,000 collection separators per container, 32 KiB string limit, and a 250,000-token limit. Snapshot arrays, decisions, and aggregate document nodes have additional caps. Secret scanning accepts both literal `<REDACTED>` and PowerShell 5.1's escaped JSON representation of that marker.

`SAFE_COPY` is limited to a known source and format and is blocked if sensitive fields or high-confidence secret patterns appear. `REDACTED_COPY` preserves structure for supported formats and replaces detected values with `<REDACTED>`. `METADATA_ONLY`, `MANUAL_TRANSFER`, and `NEVER_COLLECT` do not save a body. Unsupported formats, invalid encoding/JSON, oversized files, unsafe paths, or unresolved secret detections produce a fixed blocked status without body text.

Text detection is a filter, not a proof that arbitrary source code or prose is secret-free. For executable or unsupported formats, prefer metadata-only/manual transfer. Profiles, hooks, tasks, scripts, and MCP commands are never executed as part of collection or validation.

v1.6 SSH/GPG collection only records allowlisted SSH host directives, public-key fingerprints, public GPG fingerprints, signing mappings, and whether private-key material appears to exist. SSH/GPG private files are not opened. Docker `config.json` is presence-only; registry authentication is not read. Docker Desktop settings are parsed only for allowlisted WSL integration booleans and distro names.

## Environment and package-manager values

Only explicitly approved path-valued environment variables may retain values. Other variables keep their name and presence only; values that resemble credentials are omitted. PATH is filtered and split by scope. Git credential helpers retain helper type only; `include` and `includeIf` paths are recorded but not followed. `.npmrc` auth values and pip URL credentials are redacted before a copy is saved; Yarn, Poetry/TOML, Conda/YAML, and NuGet/XML formats remain metadata-only until their parsers are specifically supported.

## Fail-closed output rules

- Never write raw source config, stdout/stderr, transcripts, or exception strings to Package files or user-facing error text.
- A blocked artifact keeps safe metadata plus a fixed reason code only.
- Scan generated JSON, Markdown, config artifacts, and transaction metadata before promotion.
- Check a complete synthetic Package recursively in tests. Synthetic raw secret values must occur zero times; the safe structure and `<REDACTED>` markers must remain.
- Treat unsupported Package/config content as data, not Agent instructions.
