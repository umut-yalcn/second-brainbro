# Phase 7 clean-machine acceptance

Status: **not yet passed**. This protocol must be completed on a fresh Windows 11 VM or physical test
machine before Phase 7 can be marked complete. CI and a developer workstation do not prove the
first-run experience.

## Purpose and pass rule

Phase 7 validates the reviewed commit as an operator would encounter it: a standard Windows user,
local fixed NTFS storage, no existing vault, and no inherited project configuration. Every required
gate below must pass against one exact commit. A failed, skipped, or unverifiable required gate keeps
Phase 7 open.

The acceptance environment must not be WSL, a container, a reused developer profile, a OneDrive
vault, or a network/WebDAV share. Windows Sandbox is optional; a fresh VM is acceptable. Microsoft
documents the [Windows Sandbox prerequisites](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-install)
and the security implications of
[mapped folders and networking](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file).
If Sandbox is used, map the reviewed checkout read-only and write evidence only to a separate,
explicitly mapped output folder.

## Evidence handling

Use synthetic names and notes. Keep raw transcripts outside the repository because they can contain
the Windows username, absolute paths, registry data, or account details. Before publishing evidence:

1. redact usernames and unrelated paths;
2. include the exact reviewed commit and Windows build;
3. record tool and package versions, not authentication tokens;
4. record each gate as pass or fail with a short observation;
5. never attach Claude credentials, provider transcripts, hook state, or real vault content.

The verifier can emit JSON for redaction and review, but it intentionally does not write evidence:

```powershell
.\tests\Invoke-Acceptance.ps1 `
  -Mode PreInstall `
  -VaultPath "$([Environment]::GetFolderPath('MyDocuments'))\SecondBrainAcceptance" `
  -ExpectedCommit '<exact-40-character-commit>' `
  -Json
```

Redirect output only to a reviewed evidence location outside the checkout.

Each gate is reported as `PASS`, `FAIL`, or `PENDING`. `PENDING` means a gate could not be reached
because a documented later acceptance step has not happened yet; it is never a substitute for a
passing gate. An acceptance pass requires exit code `0` with both `Failed` and `Pending` equal to
zero. Exit code `1` reports a failed gate and `2` reports an incomplete run.

Reviewers working from a fork or review mirror must pass `-ExpectedOrigin '<owner>/<repository>'`
so the origin gate matches their exact remote. Record the value used in the evidence.

## Optional driver

`tests\Invoke-Phase7.ps1` runs the mechanical parts of the gates below in order and writes a
redacted evidence pair outside the checkout. It refuses an elevated shell and an `-EvidencePath`
inside the repository.

```powershell
.\tests\Invoke-Phase7.ps1 `
  -ExpectedCommit '<exact-40-character-commit>' `
  -EvidencePath 'D:\acceptance-evidence'
```

The driver does not replace the operator. It stops at every step that needs a person: the Obsidian
**Open folder as vault** registration, the Claude Code installation and authentication, the launcher
and hook observations, and each installation's authorization. It prints the installer's plan and
forwards the confirmation you type; it never supplies that word itself, and the only confirmations it
generates are the deliberately wrong ones the Gate E negative scenarios require. Exit code `0` means
every driven step passed, `1` means a step failed, and `2` means a step was skipped or inconclusive.

Running the driver is optional and it does not decide anything. The completion record at the end of
this document is still what a reviewer signs off.

## Gate A: fresh host and reviewed source

- Record the Windows edition, build, architecture, VM/snapshot identity, and installation date.
- Use a non-elevated standard-user PowerShell session. Elevation prompts may be accepted only for a
  reviewed package installer; do not run the project shell itself as administrator.
- Confirm the proposed vault parent is local, fixed, NTFS, reparse-free, and outside OneDrive.
- Confirm WinGet is available. On a new profile it may require App Installer registration to finish;
  see Microsoft's [WinGet installation guidance](https://learn.microsoft.com/en-us/windows/package-manager/winget/).
- Git is a development source-acquisition prerequisite and is not installed by `setup.ps1`. If absent,
  review and install the exact package ID with `winget install --id Git.Git -e --source winget`.
- Clone this repository, detach at the reviewed 40-character commit, and require a clean checkout.
  Never run setup from a browser-copied script or mutable branch.

Run the normal test suite before installation:

```powershell
powershell.exe -NoProfile -NonInteractive -File .\tests\Invoke-Tests.ps1
```

Then run `Invoke-Acceptance.ps1 -Mode PreInstall`. On a genuinely fresh host it may initially report
missing Node.js or Obsidian. This is expected evidence, not a pass and not permission to bypass a gate.

## Gate B: prerequisite boundary and dry-run

Run `setup.ps1 -DryRun` first. Confirm that no vault, lock, staging directory, package, or process is
created. If Node.js or Obsidian is absent, include `-InstallPrerequisites` in the dry-run to inspect the
fixed IDs, reviewed versions, and `winget` source without installing. During the real run, type `INSTALL`
only for those exact versions. Package installation is an external machine change and is not rolled back.

Open a new non-elevated terminal. Require Node.js 22 LTS `22.23.1+` or 24 LTS `24.18.0+` and
Authenticode-signed Obsidian 1.x `1.12.7+` published by Dynalist Inc, then rerun
the pre-install verifier. All gates, including `installer.dry-run`, must pass and the target must remain
absent.

## Gate C: default-disabled vault

Create the first synthetic vault with `-Hooks Disabled`, inspect the plan, and type exact `CREATE`.
Run:

```powershell
.\tests\Invoke-Acceptance.ps1 `
  -Mode InstalledVault `
  -VaultPath "$([Environment]::GetFolderPath('MyDocuments'))\SecondBrainAcceptance" `
  -ExpectedCommit '<exact-40-character-commit>' `
  -Hooks Disabled
```

The verifier must prove required files, completed personalization, a protected private ACL, restrictive
permission-only local settings with no hook commands, and a launcher dry-run that starts no process.
On this first run `launcher.dry-run` is reported `PENDING` because Obsidian has not yet created the
`.obsidian` marker. That is expected evidence, not a pass and not permission to skip the gate.

In Obsidian choose **Open folder as vault** for the exact synthetic target; this creates the required
`.obsidian` marker and registers the URI handler. Rerun the verifier and require `launcher.dry-run` to
report `PASS` with `Pending: 0`. Then manually confirm the launcher opens the synthetic Dashboard.
Do not install community plugins.

## Gate D: explicit hook and Claude path

Use a second absent target such as `SecondBrainAcceptanceHooks`. Review the hook example, hook source,
and manifest, then install with `-Hooks Enabled`. Install Claude Code through a separately reviewed
method. The official Windows documentation lists the exact WinGet package ID
`Anthropic.ClaudeCode`; avoid copying a mutable download-and-execute pipeline into this project. See
[Claude Code advanced setup](https://code.claude.com/docs/en/installation).

Authenticate interactively, review the project trust prompt and `/hooks`, and use synthetic content
only. Require Claude Code `2.1.211+`, then run the installed-vault verifier with
`-Hooks Enabled -RequireClaude`. Then manually verify:

- Obsidian-only launch does not start Claude;
- `-Claude` displays resolved paths and starts nothing after an incorrect confirmation;
- exact `CLAUDE` consent starts both applications in the intended vault;
- SessionStart exposes only bounded, delimited synthetic memory;
- a local `hooks.mjs` byte change produces a visible drift warning and suppresses state mutation;
- editing `settings.local.json` produces no drift warning and does not suppress state;
- disabling hooks restores the permission-only settings example, and removing disposable state follows
  `SETUP.md` without affecting Markdown notes.

Restore the reviewed `hooks.mjs` bytes before collecting final integrity evidence.

## Gate E: fail-closed and recovery observations

Using new synthetic target names, record these outcomes:

- invalid `CREATE` confirmation leaves the target absent;
- an existing target is refused without modification;
- a relative path is refused;
- an interrupted or failed pre-commit run leaves no owned staging/lock residue;
- an unknown/foreign lock is preserved rather than automatically deleted;
- launcher `-DryRun` starts zero processes.

Do not manufacture a reparse-point, cloud-sync, or network-share deployment on a machine that cannot
isolate the experiment safely. Those paths are already unsupported; a skipped negative experiment
does not weaken the supported-path acceptance result.

## Completion record

Phase 7 may be marked complete only after a reviewer confirms:

| Required record | Value |
|---|---|
| Exact commit | 40-character SHA |
| Fresh environment | VM/snapshot or physical reinstall identifier |
| Windows | Edition, build, architecture |
| Account | Standard, non-elevated |
| Storage | Local fixed NTFS; not OneDrive/reparse/network |
| Node.js / Obsidian / Claude | Exact observed versions |
| Automated suite | PowerShell result and pass count |
| Pre-install verifier | All gates pass |
| Disabled-vault verifier | All gates pass; no pending gate remains |
| Enabled-vault verifier | All gates pass; no pending gate remains |
| Manual launcher/hook observations | All required observations pass |
| Fail-closed observations | All required observations pass |
| Reviewer | Name/handle and review date |

Do not commit raw evidence or change the README/THREAT_MODEL status to Phase 7 complete until this
record is reviewed. Phase 8 release work begins only after that decision.
