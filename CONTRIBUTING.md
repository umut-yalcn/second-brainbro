# Contributing

second-brainbro is a public source preview (alpha), not a supported release. Contributions should
improve the reviewed Windows 11 deployment without weakening its fail-closed defaults.

## Keep reports synthetic

Never attach a real Obsidian vault, personal notes, credentials, authentication cookies, private keys,
unredacted logs, or screenshots containing private paths or account information. Reproduce issues with
a new disposable vault and synthetic names and content.

Security-sensitive findings do not belong in public issues. Follow [SECURITY.md](SECURITY.md) and use
GitHub private vulnerability reporting when it is available.

## Before opening an issue

1. Read [README.md](README.md), [SETUP.md](SETUP.md), and
   [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
2. Confirm the deployment is within the supported boundary in
   [THREAT_MODEL.md](THREAT_MODEL.md).
3. Record an exact commit SHA and exact Windows, PowerShell, Node.js, Obsidian, and optional Claude
   Code versions.
4. Reduce the reproduction to synthetic data and redact user-specific absolute paths.

Unsupported OneDrive, WSL, WebDAV, network-share, Mem0, community-plugin, or unattended deployments
may be discussed, but they are not accepted as public-source-preview regressions without a separate threat
review.

## Pull requests

Create a focused branch from the current reviewed `main`. Do not commit generated vault state,
`.obsidian/`, `.claude/settings.local.json`, credentials, real notes, or acceptance evidence containing
personal data.

Before requesting review, run:

```powershell
powershell.exe -NoProfile -NonInteractive -File .\tests\Invoke-Tests.ps1
```

Update the relevant security, privacy, architecture, setup, troubleshooting, provenance, or acceptance
documentation whenever a trust boundary or supported dependency changes. Pull requests that weaken an
existing validation, permission deny, exact confirmation, or integrity check must explain the threat
model change explicitly.

By contributing, you agree that your contribution is provided under the repository's
[MIT license](LICENSE) and that your public Git author metadata may be visible.
