# Privacy and data handling

second-brainbro stores its Markdown vault locally, but it is **not an offline AI system**. Claude Code
can send prompts, selected file content, and hook-provided context to the Claude service configured by
the user.

## What stays on disk

- Markdown notes and companion memory under the selected vault.
- Session-scoped prompt markers, start timestamps, pending reflection notices, and operational logs
  under `.claude/hooks/.state/`. Raw Claude session IDs are not stored; fixed-length
  SHA-256-derived keys name session directories.
- Gitignored local Claude project settings in `.claude/settings.local.json` for every installed vault;
  permission-only by default and expanded with hook commands only after explicit activation.

The hook log records timestamps, status messages, counts, and error details. It is not designed to
record note contents. The active log rotates after 256 KiB and cleanup retains at most two rotated
logs on a best-effort basis. Obsidian does not encrypt the local vault; use Windows device encryption
or BitLocker where appropriate.

Backups, disk images, search indexes, and manually copied vaults inherit the sensitivity of the source
files. Keep them on storage you control and apply the same access and retention decisions to every
copy.

Session state is operational and disposable, not an audit trail. It is limited to 64 session
directories and seven-day stale retention. Pending reflection notices contain a timestamp and prompt
count only; they are limited to 32 records and 30 days. Prompt marker files are limited to 1,000 per
session. Cleanup at these limits may discard the oldest operational state.

## What can leave the device

Opening Obsidian through `Open-SecondBrain.ps1` does not itself start Claude. When `-Claude` is
requested, the launcher shows the resolved vault, Dashboard, Obsidian, and Claude paths and requires
the exact confirmation `CLAUDE` before starting either process. Claude Code remains a networked client;
after authorization, content it reads or receives through hooks may leave the device as described below.

When hooks are enabled, bounded sections from these files are added to Claude's context:

- `🔮 850-Companion/Last-Session.md`
- `🔮 850-Companion/Threads.md`

`CLAUDE.md` also asks Claude to read `🔮 850-Companion/Core.md`. Treat all three files as information
that may be processed by the configured Claude service. Do not place passwords, tokens, health
records, financial secrets, private keys, recovery codes, or other high-impact secrets in them.

## Features intentionally disabled

- **Mem0:** not installed or configured in the public source preview. It requires a separate cloud-data,
  retention, authentication, and MCP threat review.
- **OneDrive vault placement:** not supported in the public source preview. Git ignore rules do not stop
  OneDrive from uploading files, local settings, or hook state.
- **Automatic AI launch:** the launcher defaults to Obsidian only. Claude requires `-Claude` plus exact
  interactive consent. The launcher stores no state, telemetry, logs, note content, or credentials.

## Sensitive material

The default local Claude settings deny Bash and PowerShell tools entirely and deny built-in reads/edits of
`.env`, `.env.*`, `*.key`, `*.pem`, `*.p12`, `*.pfx`, and `🔐 400-Vault/**` with filesystem-root-anchored
rules that do not depend on the launch directory. Users can edit settings or
select a permission-bypass mode, and an attacker controlling the Windows account can read the files.
This is defence in depth, not encryption. Store credentials in a proper credential manager outside the vault.

## Disabling and deleting

- Disable project hooks by replacing `.claude/settings.local.json` with the reviewed
  `.claude/settings.permissions.example.json`, preserving restrictive permission rules. Alternatively,
  set `disableAllHooks` without weakening the existing denies.
- Remove generated hook state by deleting `.claude/hooks/.state/` while Claude Code is not running.
- Delete the vault using normal Windows file-management and backup practices.
- Data already sent to a provider is governed by that provider's account, retention, and privacy
  settings; deleting the local vault does not delete provider-side records.

See [ARCHITECTURE.md](ARCHITECTURE.md) for data-flow boundaries,
[THREAT_MODEL.md](THREAT_MODEL.md) for security assumptions, [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
for bounded diagnostics, and [SECURITY.md](SECURITY.md) for private reporting guidance.
