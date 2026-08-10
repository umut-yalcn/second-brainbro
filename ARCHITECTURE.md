# Architecture

This document describes the Phase 6 Windows architecture. It is an implementation map, not a claim
that the current public source preview is a signed release. Security assumptions and residual risks
remain authoritative in [THREAT_MODEL.md](THREAT_MODEL.md).

## Components

| Component | Responsibility | Does not do |
|---|---|---|
| `setup.ps1` | Validate the Windows target and version-pinned prerequisites, protect staging with a private ACL, install mode-specific local permissions, verify the staged vault, and commit it with one directory rename | Update, merge into, or repair an existing vault |
| `personalize.mjs` | Validate user-supplied text and replace placeholders in a fixed seven-file allowlist | Walk arbitrary user paths or enable hooks |
| `template/` | Provide the reviewed Obsidian vault, launcher, permission-only and hook-enabled examples, hook implementation, and integrity manifest | Store user secrets or automatically execute project code |
| `Open-SecondBrain.ps1` | Validate the installed vault and local executables, open the Dashboard in Obsidian, and optionally start Claude after explicit consent | Install software, change Obsidian settings, or enable hooks |
| `hooks.mjs` | Validate Claude hook input and manifest integrity, inject bounded memory, and maintain session-isolated operational state | Provide an encryption boundary or protect against the same Windows user |
| `tests/Invoke-Tests.ps1` | Exercise installer, personalization, launcher, hook, navigation, encoding, documentation, and CI invariants on temporary copies | Launch Obsidian or Claude, or write to an existing vault |
| `tests/Invoke-Acceptance.ps1` | Read and verify a reviewed checkout, supported host, dry-run, or installed synthetic vault during Phase 7 | Install packages, create a vault, launch applications, or claim that a reused host is clean |
| `tests/Invoke-Phase7.ps1` | Drive the mechanical acceptance gates in order and write redacted evidence outside the checkout | Type an installation authorization, answer a manual observation, or decide that Phase 7 passed |

## Installation transaction

```text
arguments
   |
   v
validate target + prerequisites -- DryRun --> stop with no changes
   |
   v
explicit CREATE confirmation
   |
   v
exclusive target lock --> same-volume owned staging
   |
   v
copy template --> personalize fixed files --> optional hook activation
   |
   v
verify markers, launcher bytes, settings, optional navigation, and hook integrity
   |
   v
single directory rename --> installed vault
```

Prerequisite installation is outside this filesystem transaction. WinGet is invoked only with
`-InstallPrerequisites`, reviewed exact package versions, and a separate `INSTALL` confirmation.

## Runtime flows

The launcher derives the vault root from its own installed location. It validates required marker
files, rejects reparse-point ancestors and unsupported storage, verifies that the registered
`obsidian://` handler resolves to an allowlisted Obsidian 1.x `1.12.7+` executable with a valid Dynalist
Inc Authenticode signature, and percent-encodes the absolute Dashboard path. The default path starts
Obsidian only. `-Claude` additionally validates the Claude command and requires exact `CLAUDE` consent
before probing its version. Claude Code must be `2.1.211+`; only after that check passes may either
application start.

When hooks are enabled, Claude Code invokes Node directly from the gitignored local settings file.
Each hook call follows this order:

1. verify the packaged hook hash (user-owned local settings are intentionally not pinned);
2. read at most 1 MiB of JSON from stdin;
3. validate `hook_event_name` and `session_id`;
4. derive a fixed SHA-256 session key;
5. read or mutate only bounded state for the validated event;
6. return bounded context or a user-visible drift warning.

Invalid input, manifest drift, and operational hook errors are non-blocking for Claude Code but
suppress memory injection and continuity-state mutation for that call.

## Installed data layout

| Path | Purpose | Persistence |
|---|---|---|
| Markdown folders | User notes, indexes, templates, and companion memory | User-managed |
| `.claude/settings.local.json` | Always-on restrictive permissions; optionally includes explicit hook activation | Gitignored; user-managed |
| `.claude/hooks/.state/sessions/` | Hashed session directories and prompt markers | Disposable and bounded |
| `.claude/hooks/.state/pending-reflections/` | Bounded reflection notices containing timestamp and prompt count | Disposable and bounded |
| `.claude/hooks/.state/hooks.log` | Operational status without note contents or raw session IDs | Disposable; rotates after 256 KiB with at most two best-effort archives |

## External trust dependencies

Windows, NTFS, PowerShell, Node.js, Obsidian, Claude Code, the configured Claude service, GitHub, and
GitHub-hosted runners remain outside this repository's security boundary. The project does not add
telemetry, a credential store, a network service, a database, Mem0, or an Obsidian community plugin.

See [PRIVACY.md](PRIVACY.md) for data handling, [SETUP.md](SETUP.md) for the operator runbook, and
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) for fail-closed recovery steps.
