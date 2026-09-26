# Secret handling

## Never collect or persist

Passwords; API keys; OAuth/session tokens; cookies; SSH/GPG private-key contents; Credential Manager secrets; `.env` values; BitLocker recovery keys. Do not write hashes, prefixes, suffixes, lengths, raw command output, exception text, transcripts, or verbose logs that could expose them.

For an identified secret, retain only the environment/config name, dependent tool, presence, and action `SET_MANUALLY`, for example:

```text
OPENAI_API_KEY
Present: true
Value: REDACTED
UsedBy: Codex
Migration: SET_MANUALLY
```

## Safe extraction

Use a positive allowlist for ordinary path-valued environment variables; all other variables retain only name and presence. Test an allowlisted value before storing it, and filter suspicious PATH segments. Do not infer that an unknown value is safe because its name looks ordinary.

Configuration files default to metadata only: path, type, existence, and safe summary. Put a config in `configs/` only when the user selected that exact file and filtering is reliable for its format. Never write a generalized sanitizer claim. Unknown formats or a redaction hit mean skip that copy and record `MANUAL` or `REDACTION_BLOCKED`.

Capture process stdout/stderr in memory, enforce a timeout and size limit, and extract only validated version/ID/status values. Persist fixed error codes instead of raw exception or stderr text. Run a second secret-pattern pass over every generated JSON and Markdown string before atomic write. If it blocks, report only `REDACTION_BLOCKED`; do not echo the matching text. Use synthetic fake values only in tests, and ensure they are absent from all test artifacts and output.
