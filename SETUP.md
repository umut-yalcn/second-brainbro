# SETUP.md — Windows 11 transactional installer runbook

> Public source preview (alpha), not a release. Run only from a locally checked-out, reviewed commit. Never execute setup
> instructions fetched from a live URL, and never install an unreviewed mutable `main` for another user.

Read [THREAT_MODEL.md](THREAT_MODEL.md), [PRIVACY.md](PRIVACY.md), and
[SECURITY.md](SECURITY.md) first. The supported environment is
Windows 11, a standard user account, a local fixed NTFS volume, patched Node.js 22 LTS (`22.23.1+`)
or 24 LTS (`24.18.0+`), and Authenticode-signed Obsidian 1.x (`1.12.7+`) published by Dynalist Inc. OneDrive,
WSL, WebDAV, network shares, unattended setup, Mem0, and community plugins are unsupported.
Git is required to acquire the development checkout but is not a runtime dependency of an installed
vault. WinGet is required only when `-InstallPrerequisites` is requested.
Node.js is required while the installer personalizes and verifies a new vault, and remains a runtime
dependency when continuity hooks are enabled. Claude Code is optional for Obsidian-only use; Claude
integration requires version `2.1.211+`.

## Safety contract

`setup.ps1`:

1. requires an absolute target whose parent already exists;
2. refuses an existing target, drive/user/system root, OneDrive, UNC/network path, non-fixed or non-NTFS
   volume, Windows reserved name, and any existing reparse-point ancestor;
3. verifies the bundled template contains no reparse point;
4. prints the canonical plan without printing the user biography;
5. validates personalization inputs while making no filesystem or package change in `-DryRun` mode;
6. requires the exact interactive confirmation `CREATE` before taking a per-target lock or creating
   staging;
7. creates a non-inheriting staging ACL limited to the current user, SYSTEM, and Administrators;
8. copies, personalizes, always installs restrictive local Claude permissions, activates hook commands
   only if requested, and verifies everything in staging;
9. exposes the target only with a same-volume directory rename after all checks pass and re-verifies its ACL;
10. on failure, removes only a staging directory with the expected parent, prefix, and ownership marker;
11. never overwrites, merges into, updates, or repairs an existing vault.

A Node.js or Obsidian installation is a separate machine-level change. It occurs only when
`-InstallPrerequisites` is present and the user types `INSTALL` for each missing package. The installer
uses exact package IDs and reviewed versions (`OpenJS.NodeJS.LTS` `24.18.0` and
`Obsidian.Obsidian` `1.12.7`) from the explicit `winget` source. Package-manager changes cannot be
transactionally rolled back with the vault and are reported as a separate boundary.

## 1. Review and dry-run

```powershell
git status --short
git rev-parse HEAD
Get-Content -Raw .\setup.ps1
Get-Content -Raw .\THREAT_MODEL.md

$documents = [Environment]::GetFolderPath('MyDocuments')
$target = Join-Path $documents 'SecondBrain'

.\setup.ps1 `
  -VaultPath $target `
  -OsName 'ExampleOS' `
  -UserName 'Example User' `
  -UserBio 'Local Windows second brain for reviewed notes' `
  -Companion 'Guide' `
  -Hooks Disabled `
  -OptionalArea Goals,Private `
  -DryRun
```

### Parameter reference

| Parameter | Required/default | Purpose and constraint |
|---|---|---|
| `VaultPath` | required | Absolute absent target on a local fixed NTFS volume with an existing safe parent |
| `OsName` | required | Personalized system name and Windows-safe directory token |
| `UserName` | required | Display name used in the scaffold |
| `UserBio` | required | Maximum 500-character plain-text description; no line breaks, template braces, backticks, or `$()` syntax |
| `Companion` | required | Companion display name |
| `Hooks` | `Disabled` | `Disabled` or explicit `Enabled` local hook activation |
| `OptionalArea` | none | Any combination of `Goals`, `Private`, `Body`, and `Mind` |
| `InstallPrerequisites` | off | Permit separately confirmed, version-pinned installs from the explicit `winget` source for missing Node.js or Obsidian |
| `DryRun` | off | Validate and print the plan without package, lock, staging, or target changes |
| `Today` | current date | Explicit `yyyy-MM-dd` personalization date when reproducibility requires it |

Parameters `OsName`, `UserName`, and `Companion` accept the conservative name allowlist enforced by
`personalize.mjs`. `Today` defaults to the current `yyyy-MM-dd` date.

Optional areas are `Goals`, `Private`, `Body`, and `Mind`. `Private` creates `🔐 400-Vault`. Every
installed vault receives local settings that deny Claude's Bash and PowerShell tools and deny built-in
reads of this path. Users can change or bypass those settings; the folder is not encryption and must not contain
credentials, private keys, recovery codes, or other high-impact secrets.

## 2. Create the vault

Run the same command without `-DryRun`, re-check the displayed canonical path and choices, then type
`CREATE`. If a supported patched Node.js LTS or Obsidian is missing, either install it manually first or add
`-InstallPrerequisites` and review each displayed WinGet package ID and version before typing `INSTALL`.

The installer always copies `settings.permissions.example.json` to the gitignored
`.claude/settings.local.json` in default mode. This does not activate executable project hooks.
Its filesystem-root-anchored rules deny built-in reads and edits of the optional private folder and
common secret-file patterns even when Claude starts from a vault subdirectory. These controls are
defence in depth, not an encryption boundary.

Hooks default to `Disabled`. To opt in, first review these exact files:

```powershell
Get-Content -Raw .\template\.claude\settings.hooks.example.json
Get-Content -Raw .\template\.claude\settings.permissions.example.json
Get-Content -Raw .\template\.claude\hooks\hooks.mjs
Get-Content -Raw .\template\.claude\hook-manifest.json
```

Then use `-Hooks Enabled`. The installer copies the example to the gitignored
`.claude/settings.local.json` inside staging and runs `verify-integrity` before commit. Hook commands run
with the current Windows user's permissions, and selected companion memory may be sent to Claude as
context. Hook drift detection does not protect against malware or an attacker controlling the same user.
Claude integration and the documented filesystem-root-anchored Read/Edit rules require Claude Code
`2.1.211+`. The launcher validates that version only after exact `CLAUDE` consent, preserving zero-process
dry-run behavior.

## 3. Independent post-install checks

```powershell
$target = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'SecondBrain'

Test-Path -LiteralPath "$target\CLAUDE.md"                       # True
Test-Path -LiteralPath "$target\Open-SecondBrain.ps1"           # True
Test-Path -LiteralPath "$target\.claude\settings.json"         # False
Test-Path -LiteralPath "$target\.claude\settings.local.json"   # True
Select-String -Path "$target\CLAUDE.md" -Pattern '\{\{[^}]*\}\}' # no output
```

If hooks were enabled:

```powershell
node "$target\.claude\hooks\hooks.mjs" verify-integrity
```

Start Obsidian, choose **Open folder as vault**, and select the exact installed `$target`. This both
registers the `obsidian://` protocol and creates the local `.obsidian` marker the launcher requires.
Then close Obsidian and inspect the launcher plan:

```powershell
Set-Location -LiteralPath $target
.\Open-SecondBrain.ps1 -DryRun
```

Open only Obsidian and the Dashboard with `.\Open-SecondBrain.ps1`. To additionally start Claude Code
in the vault, run `.\Open-SecondBrain.ps1 -Claude`, review the displayed paths, and type the exact
confirmation `CLAUDE`. The launcher creates no desktop shortcut, changes no settings, enables no hooks,
and writes no state or log. It refuses UNC/network, OneDrive, non-fixed/non-NTFS, or reparse-point paths.
It uses the registered Obsidian URI rather than depending on the separately enabled Obsidian CLI.

Hook state is isolated by a SHA-256 key derived from Claude Code's validated `session_id`; concurrent
sessions no longer share prompt counts or start timestamps. State remains local under
`.claude/hooks/.state/` and is age/count bounded.

## Failure handling

An installer error before the final rename must leave the final target absent. The installer removes its
own lock and owned staging directory. A pre-existing or foreign lock is preserved and blocks setup; inspect
it before manually deleting it. Never delete an unknown `.second-brainbro-*` path merely to bypass a
failure. If a package was installed before a later vault error, treat it as a completed external change.
Use [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for exact error fragments, bounded diagnostics, and safe
lock/staging recovery. Do not weaken a path or integrity check to make an unsupported deployment pass.

## Disable, reset, or remove

Close Claude Code before changing hook configuration or state.

- Disable hooks by replacing `.claude\settings.local.json` with the reviewed
  `.claude\settings.permissions.example.json`; do not delete the local settings because that would also
  remove the sensitive-path and shell-tool denies. Review `/hooks` after restarting Claude Code.
- Reset disposable hook state by removing the exact installed `.claude\hooks\.state\` directory only
  after every Claude process using that vault is closed.
- Back up wanted Markdown notes before removing a test vault through normal Windows file management.
- The installer is not an uninstaller or updater. Reinstallation requires a new absent target.
- Deleting local files does not delete data already processed or retained by an AI provider.

## Automated Windows verification

Run the same zero-dependency test harness used by CI from either supported shell:

```powershell
powershell.exe -NoProfile -NonInteractive -File .\tests\Invoke-Tests.ps1
pwsh.exe -NoProfile -NonInteractive -File .\tests\Invoke-Tests.ps1
```

The harness uses a unique local temporary directory, a dummy Obsidian marker with process-local
version/signature test doubles, a `Read-Host` test double, explicit BOM-less UTF-8 hook input, and copied vaults. It never launches
Obsidian or Claude, never writes to an existing vault, and removes its test directory in a `finally`
block. See [ARCHITECTURE.md](ARCHITECTURE.md) for component boundaries.

## Verifying an installed vault

`tests\Invoke-Acceptance.ps1` is a read-only health check. It confirms the host, the reviewed
checkout, the required files, the protected ACL, the restrictive local settings, and a launcher
dry-run that starts no process. It installs nothing and changes nothing.

```powershell
.	ests\Invoke-Acceptance.ps1 `
  -Mode InstalledVault `
  -VaultPath "$([Environment]::GetFolderPath('MyDocuments'))\SecondBrain" `
  -ExpectedCommit (git rev-parse HEAD) `
  -Hooks Enabled
```

Exit code `0` means every gate passed, `1` means a gate failed, and `2` means a gate could not be
reached yet - most often because Obsidian has not opened the folder as a vault. This check runs on the
machine you use; it is not evidence that the first-run experience works on a clean Windows install,
and this repository makes no such claim.
