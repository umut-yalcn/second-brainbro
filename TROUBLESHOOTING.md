# Troubleshooting and safe recovery

This guide is for the supported Windows 11 public-source-preview deployment. Do not bypass a fail-closed
check merely to complete installation. Preserve unknown lock or staging paths until their ownership is
understood.

## Bounded diagnostic snapshot

Run these commands from the reviewed repository checkout. They print versions, paths, repository
state, and protocol registration; they do not read note bodies.

```powershell
$PSVersionTable.PSVersion
node --version
git status --short
git rev-parse HEAD
Get-Command node, obsidian, claude -ErrorAction SilentlyContinue |
  Select-Object Name, CommandType, Source
Get-ItemProperty -LiteralPath 'Registry::HKEY_CLASSES_ROOT\obsidian\shell\open\command' `
  -ErrorAction SilentlyContinue
```

The protocol query reads `HKEY_CLASSES_ROOT`, the same merged view `Open-SecondBrain.ps1` validates.
It resolves both per-user and machine-wide Obsidian registrations, so a per-hive query can report
"not registered" for an installation the launcher accepts.

Redact the Windows username and unrelated absolute paths before sharing output. Do not paste tokens,
settings files, note content, or hook state into an issue.

## Installer messages

| Message fragment | Meaning | Safe action |
|---|---|---|
| `VaultPath must be absolute` | The target was relative | Build the path with `Join-Path` from an existing local parent |
| `Target parent must already exist` | The installer will not create an unreviewed parent chain | Create and inspect the intended parent, then rerun `-DryRun` |
| `Target already exists` | Update and merge are intentionally unsupported | Choose a new empty target name; never point setup at an existing vault |
| `local fixed drive` or `must use NTFS` | The target volume is unsupported | Use a local fixed NTFS volume; do not weaken the check |
| `OneDrive-hosted vaults are unsupported` | A known sync root contains the target | Choose a non-synced local path |
| `Reparse point, junction, or symbolic-link ancestor` | Path resolution crosses an unsupported redirect | Choose a normal directory tree with no reparse ancestor |
| `Patched Node.js 22 LTS` | Node is absent, too old, EOL, or on an unreviewed release line | Install Node 22.23.1+ or 24.18.0+, open a new terminal, and confirm `node --version` |
| `Obsidian is required` or `publisher is not trusted` | Obsidian is absent, below 1.12.7, outside the reviewed 1.x line, or lacks a valid Dynalist Inc Authenticode signature | Repair/reinstall the official desktop application or use the reviewed `-InstallPrerequisites` flow; do not bypass the check |
| `Another installation may own this target lock` | A concurrent or interrupted run owns the exact target lock | Confirm no setup process is running; inspect the exact lock before any manual removal |
| `Filesystem installation was not authorized` | The exact `CREATE` confirmation was not supplied | Review the printed plan and rerun; do not automate the confirmation |

An error before the final rename must leave the final target absent. A package installed by WinGet is
an external completed change even if a later vault step fails.

## Staging and lock recovery

Installer-owned paths sit beside the requested target and use `.second-brainbro-staging-*` and
`.second-brainbro.lock` naming. The installer deletes only staging with the expected parent and
ownership marker. Never recursively delete every matching path. If recovery is necessary:

1. close other setup processes;
2. record the exact target and error;
3. inspect the exact lock and candidate staging directory;
4. verify the staging ownership marker says `second-brainbro transactional installer`;
5. back up anything unexpected and investigate before deleting a single exact path.

The installer is not an updater. To replace a test vault, first back up any wanted notes, remove the
old vault through normal Windows file management, and install to a new absent target.

## Launcher failures

- **Protocol is not registered:** start Obsidian once, close it, and rerun
  `Open-SecondBrain.ps1 -DryRun`. Obsidian documents that one Windows launch normally registers the
  URI handler.
- **Folder is not initialized as a vault:** in Obsidian choose **Open folder as vault**, select the exact
  installed vault directory, close Obsidian, and rerun the launcher dry-run.
- **Handler does not match a supported executable:** repair or reinstall Obsidian. Do not edit the
  registry to point at an arbitrary executable merely to pass validation.
- **Claude command was not found:** ensure the reviewed Claude Code installation is on `PATH`, open a
  new terminal, and use `Get-Command claude`. Obsidian-only launch does not require `-Claude`.
- **Claude Code 2.1.211 is required:** upgrade through the same reviewed installation channel. Older
  versions are not supported because the hardened Read/Edit path-rule contract is not guaranteed.
- **Launch was not authorized:** no process should have started. Rerun only after reviewing the plan
  and type exact `CLAUDE` if networked AI use is intended.

The official URI format and encoding rules are documented in
[Obsidian URI](https://help.obsidian.md/Extending%2BObsidian/Obsidian%2BURI).

## Hook failures and drift

From the installed vault, check packaged integrity without starting Claude:

```powershell
node .\.claude\hooks\hooks.mjs verify-integrity
```

A nonzero result or a user-visible drift warning means the packaged hook bytes no longer match the
manifest, and memory injection and continuity-state work are suppressed. Do not regenerate hashes
around unexplained changes; restore `.claude/hooks/hooks.mjs` from the same reviewed source.

Editing `.claude/settings.local.json` does not raise a drift warning. That file is yours to change,
so disabling hooks by replacing it with the reviewed
`.claude/settings.permissions.example.json` while Claude Code is closed leaves `verify-integrity`
passing. Do not delete local settings, because that also removes the restrictive permission rules.
Review `/hooks` after restarting Claude Code.

Operational state under `.claude/hooks/.state/` is disposable. Close every Claude process using the
vault before deleting that exact state directory. This resets session counters and pending reflection
notices; it does not delete Markdown notes.

See the official [Claude Code hooks reference](https://code.claude.com/docs/en/hooks) for the upstream
event and settings contract.

## Automated test failures

Run the harness from the repository root:

```powershell
powershell.exe -NoProfile -NonInteractive -File .\tests\Invoke-Tests.ps1
pwsh.exe -NoProfile -NonInteractive -File .\tests\Invoke-Tests.ps1
```

The harness uses an isolated temporary directory and a process-local `Read-Host` test double. It must
not launch Obsidian or Claude. Before reporting a failure, record the exact commit, failing test name,
PowerShell version, and Node version. Do not weaken a security assertion to make an unsupported machine
pass.

For initial installation instructions see [SETUP.md](SETUP.md); for disclosure-sensitive problems see
[SECURITY.md](SECURITY.md). Clean-machine acceptance failures must remain failed until the required
gate in [ACCEPTANCE.md](ACCEPTANCE.md) is repeated successfully on the same reviewed commit.
