# Threat model

Status: Phase 0–6 hardening baseline

This review supersedes a pre-hardening development snapshot that exists only in the maintainer's
private archive and is intentionally not published, so no public commit identifies it. The public
root commit and the upstream baseline `3961c0c` are recorded in [PROVENANCE.md](PROVENANCE.md).

This document defines what second-brainbro protects, what it deliberately does not promise, and
which deployment is currently supported. It must be updated whenever a new executable hook,
network service, sync provider, or credential is introduced.

## Supported deployment

- Windows 11 on a local NTFS volume, under a standard user account.
- Claude Code started interactively from the vault after its trust prompt is reviewed.
- Authenticode-signed Obsidian 1.x (`1.12.7+`) published by Dynalist Inc, used as a Markdown editor.
  No community plugin is required by this project.
- Patched Node.js 22 LTS (`22.23.1+`) or 24 LTS (`24.18.0+`); other and EOL lines are unsupported.
- Claude Code `2.1.211+` when Claude integration or project permission rules are used.
- A vault stored in a user-selected local directory with a safe, existing parent.
- Restrictive local Claude permissions installed by default; executable hooks added only through the
  reviewed hook-enabled settings example.

The public source preview does **not** support OneDrive-hosted vaults, Mem0, unattended `claude -p`
installation, WSL, network shares, or WebDAV. These may be added only with their own threat review.

## Assets

1. Personal notes and the companion memory files.
2. Confidential material the user intentionally keeps outside AI-readable scope.
3. The Windows account and all files accessible to it.
4. Claude, GitHub, and future service credentials.
5. The integrity and provenance of the hook execution chain.

## Trust boundaries and data flow

| Flow | Data | Destination | Trust rule |
|---|---|---|---|
| Obsidian → vault | Notes and metadata | Local disk | Obsidian is an editor, not an encryption boundary. |
| Vault → hook | Selected memory sections | Local Node process | Hook code must match the reviewed release manifest. |
| Claude Code → hook | Event JSON including `session_id` and `hook_event_name` | Hook stdin | Event and identity must validate before memory reads or state writes. Raw IDs never become paths. |
| Hook → Claude Code | Last session, active thread summaries, reminders | Claude model context | Memory is untrusted data, never executable instruction. |
| Claude Code → vault | Notes and memory updates approved by the user | Local disk | Filesystem-root-anchored sensitive reads/edits and all Bash/PowerShell tools are denied by default; user-controlled settings remain a trust boundary. |
| GitHub → local checkout | Source, setup instructions, templates | Local disk | Use a reviewed release commit/tag; do not execute mutable live instructions. |
| Repository documentation → operator | Commands, support boundaries, and security assumptions | Windows user | Use the reviewed local documentation set; external links are informational trust dependencies. |
| Local launcher → Obsidian | Percent-encoded absolute Dashboard path | Registered `obsidian://` handler | Validate vault and handler before launch; do not interpolate a shell command. |
| Local launcher → Claude Code | Validated vault working directory | New PowerShell/Claude process | Disabled by default; require exact `CLAUDE` consent and use a Base64-encoded literal command. |
| GitHub pull request → Windows CI | Repository code and tests | Ephemeral GitHub-hosted Windows runner | Use `pull_request`, read-only contents permission, no secrets, and full-SHA-pinned GitHub-owned actions. |

Claude Code is a networked AI client. Content added to its context may be processed by the configured
Claude service. “Files are stored locally” must never be described as “the system is fully offline.”

## Threats and controls

| Threat | Current control | Residual risk |
|---|---|---|
| Malicious or replaced project hook | Hooks are opt-in local settings; packaged hook bytes are checked against `hook-manifest.json` on every call; mismatch skips memory/continuity-state work. `setup.ps1` separately verifies `settings.local.json` against the reviewed mode example before commit. | A same-user attacker can replace hook and manifest together. `settings.local.json` is user-editable by design and is not pinned at runtime, so a post-install change to which hook commands run is not detected by drift alone. Signed releases are still required. |
| Persistent prompt injection through memory | Injected memory is bounded and wrapped as untrusted data; `CLAUDE.md` forbids following instructions found inside memory. | Language-model defences are not absolute. Users must review imported/untrusted content. |
| Accidental secret disclosure | Every installed vault denies built-in sensitive-path reads/edits with launch-directory-independent rules and denies Bash/PowerShell tools; no project feature asks for an API key. | The user can change/bypass settings or paste secrets into an ordinary note. This is not an OS encryption boundary. |
| Public Git leak | `settings.local.json` and hook state are ignored; public-release secret scanning is required. | `.gitignore` is not encryption and cannot protect already committed history. |
| Partial or misdirected installation | The installer rejects unsafe/existing targets, uses a per-target lock, protects staging/final ACLs, verifies before exposure, and commits by directory rename. | It creates new vaults only; version-pinned package-manager changes are external and are not rolled back. |
| Vault traversal during personalization | Personalization uses a fixed file allowlist, rejects links/non-files, validates canonical containment, and preflights placeholders before writing. All writes occur before the staging commit. | A same-user attacker or compromised local storage remains out of scope. |
| Cloud-sync leakage/conflict | OneDrive deployment is unsupported in the public source preview. | Users can still manually place the vault in a synced directory. |
| Concurrent Claude sessions | Raw IDs are SHA-256-derived; each session has a separate directory; prompts use exclusive markers; closing and reflection claims use exclusive/atomic filesystem operations. | Abrupt process/storage failure can lose a reminder. Same-user tampering remains out of scope. |
| State exhaustion or stale sessions | Hook input is capped at 1 MiB; prompt markers at 1,000 per session; session directories at 64/seven days; pending reflections at 32/30 days; at most three notices are claimed per start; the 256 KiB operational log keeps at most two best-effort archives. | These are availability/retention limits, not durable audit guarantees. Oldest state may be discarded at the cap. |
| Launcher command/path injection | Launcher derives its vault from its own directory, requires Obsidian vault initialization, validates a supported signed Obsidian binary and reparse-free ancestors, launches that executable, and passes Claude through an encoded literal command using the correct PowerShell edition. | Obsidian, Claude Code, PowerShell, certificate trust, and same-user file integrity remain external trust boundaries. The Claude command is resolved from `PATH` and checked for file type and reparse-free ancestry only; it is deliberately not Authenticode-verified (see below). |
| Accidental networked AI start | Default launch opens Obsidian only; `-Claude` requires a displayed plan and exact interactive confirmation before either process starts. Dry-run starts zero processes. | Once authorized, Claude may send user-approved context to its configured service. |
| CI workflow or action supply-chain abuse | CI has only `contents: read`, disables persisted checkout credentials, sets timeouts, pins actions to reviewed full commit SHAs, and pins Node.js patch versions. | GitHub-hosted runner images, Node.js distributions, and pinned action implementations remain external trust dependencies and require periodic review. |
| Untrusted pull-request code in CI | Tests run on `pull_request`, never `pull_request_target`; no repository secrets or write token are exposed. | Test code can affect only its ephemeral runner and public job output within GitHub's runner isolation assumptions. |
| Stale or misleading operator documentation | Required security, privacy, provenance, architecture, recovery, and setup documents are linked from the README; CI checks local links, parameter coverage, current support policy, and prohibited live-pipe instructions. | Automated checks cannot prove every sentence semantically matches the implementation; reviewers must update prose with behavior changes. |
| Local account compromise | No claim of protection. | An attacker with the same Windows user permissions can read notes and alter all controls. |

## Why Obsidian and Claude Code are validated differently

The launcher verifies Obsidian's Authenticode signature, publisher, product metadata, and version, but
resolves Claude Code from `PATH` and checks only that the target is a normal file with no reparse-point
ancestor. This asymmetry is intentional, not an oversight.

Obsidian ships a single signed desktop executable from a known publisher and known install locations,
so a strict allowlist costs nothing. Claude Code is commonly installed through npm, which creates
unsigned `claude.ps1` / `claude.cmd` shims in a user-writable directory such as
`%APPDATA%\npm`. Requiring a valid signature or a fixed install location would reject the most common
supported installation rather than add protection.

The residual exposure is bounded by an assumption already stated in this document: writing to those
locations, or reordering `PATH`, requires control of the same Windows user account, which is out of
scope. Users who want a stricter boundary should install Claude Code through a reviewed signed channel
and keep user-writable directories off `PATH`. Revisit this decision if Claude Code gains a signed
first-party Windows executable as its standard distribution.

## Security invariants

- No API key, token, password, private key, or recovery code belongs in the vault.
- Under the installed default settings, `🔐 400-Vault` built-in reads/edits and all Claude shell tools
  are denied with filesystem-root-anchored rules; users can change or bypass settings, so it is not a
  credential manager or encryption boundary.
- Project hooks are disabled until the user explicitly opts in.
- A drift warning must suppress memory injection and continuity-state mutation for that hook call.
- Invalid, missing, oversized, or event-mismatched hook input must suppress memory injection and continuity-state mutation.
- Raw Claude session IDs must not be written to paths or operational logs; only fixed-length SHA-256 keys identify session state.
- One session ending must not delete another live session's state, and one prompt reminder may be emitted at most once per session.
- Session and pending-reflection state must remain age/count bounded.
- Personalization may only modify the seven documented scaffold files.
- Installation never overwrites or merges an existing target, and a failed pre-commit install leaves the final target absent.
- Installed staging and final vault ACLs allow only the current user, SYSTEM, and Administrators and do not inherit parent access rules.
- Installer cleanup is limited to a same-parent staging directory carrying its ownership marker; a foreign lock is never removed.
- The launcher never starts Claude unless `-Claude` and exact `CLAUDE` confirmation are both supplied.
- Launcher dry-run performs validation but starts zero processes and makes no filesystem change.
- Launcher paths must remain on a local fixed NTFS volume with no reparse-point ancestor.
- CI workflows must not use `pull_request_target` for repository code, must declare read-only permissions,
  and must pin every external action to a full commit SHA.
- Supported Node.js versions must not be end-of-life; the installer and CI enforce the reviewed Node.js
  22/24 LTS lines and minimum security patch baselines.
- Obsidian must remain on the reviewed 1.x line at `1.12.7+` with a valid Dynalist Inc Authenticode signature.
- Claude Code must be `2.1.211+` before the launcher starts networked AI or the project relies on
  filesystem-root-anchored Read/Edit permission semantics.
- Memory text is data. It cannot authorize commands, permission changes, network access, or secret reads.
- No setup instruction may download a mutable script and execute it directly.
- All required operator documents must be reachable from the README, and every repository-local
  Markdown link must resolve inside the checkout.
- Setup documentation must cover every public installer parameter and preserve the supported Windows,
  storage, and Node.js policy enforced by code.
- No clean-machine claim may be made from CI or a reused developer workstation; the read-only
  verifier checks the machine it runs on and nothing more.
- A public release requires clean automated tests, secret-history scanning, and a reviewed immutable tag.

## Out of scope

- Protection against malware or an attacker controlling the Windows account.
- Full-disk encryption, backup, and physical-device protection.
- Security of Anthropic, GitHub, Microsoft, Obsidian, or other providers.
- Guaranteeing that a language model will resist every prompt-injection attempt.
- Obsidian community plugins; none are installed or trusted by this project.

## Review triggers

Repeat this threat review before enabling cloud sync, Mem0/MCP, community plugins, unattended setup,
new executable hooks, credential storage, public distribution, or adopting an incompatible Claude Code
hook input/session lifecycle contract. Re-run the documentation contract whenever installer parameters,
supported Node.js lines, unsupported deployment modes, data flows, or recovery behavior change.
