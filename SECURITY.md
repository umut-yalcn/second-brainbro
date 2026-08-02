# Security policy

## Release status

second-brainbro is currently a public source preview (alpha), not a release. No signed public release
is supported yet.
The only reviewed deployment target is the Windows 11 configuration in
[THREAT_MODEL.md](THREAT_MODEL.md). Mutable `main`, unreviewed forks, development branches, and copied
setup commands are not release artifacts.

When signed releases begin, this file will list supported immutable tags and their verification
material. Until then, reports should reference an exact commit SHA and use synthetic reproduction data.

## Reporting a vulnerability

Do not publish sensitive exploit details, personal vault content, credentials, or unredacted logs in
a public issue.

1. If GitHub displays **Security → Report a vulnerability** for this repository, use that private
   reporting form.
2. If private vulnerability reporting is unavailable, open a minimal public issue asking the
   maintainer to establish a private contact channel. Include no technical details beyond the affected
   component and the fact that the issue may be security-sensitive.
3. In the private report, include the exact commit, Windows and PowerShell versions, Node.js version,
   whether hooks were enabled, reproduction steps using synthetic data, impact, and any proposed fix.

Reports are handled on a best-effort basis; there is no response-time or bounty commitment. Please
allow time for validation and coordinated remediation before public disclosure.

## In-scope examples

- bypassing target, reparse-point, OneDrive, NTFS, or existing-target installer checks;
- command or path injection in setup, personalization, the launcher, or hook execution;
- hook activation without explicit local opt-in;
- memory injection or continuity-state mutation after manifest drift or invalid hook input;
- raw Claude session IDs written to paths or operational logs;
- cross-session deletion or state confusion;
- repository secrets, private keys, or credentials committed by the project;
- GitHub Actions exposure of write tokens or secrets to untrusted pull-request code.

## Out-of-scope examples

- an attacker already controlling the same Windows user account;
- vulnerabilities in Windows, Node.js, Obsidian, Claude Code, GitHub, or an AI provider that do not
  arise from this repository's integration;
- unsupported OneDrive, WSL, WebDAV, network-share, Mem0, community-plugin, or unattended deployments;
- prompt-injection resistance as an absolute guarantee;
- recovery of data or credentials intentionally pasted into AI-readable notes.

## Safe evidence collection

Use synthetic vault content. Redact usernames and absolute paths where they are not essential. Never
attach `.claude/settings.local.json`, `.env` files, hook state, provider transcripts, or real companion
memory without first replacing sensitive content. The commands in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) are designed to collect bounded diagnostics without reading
note bodies.

For deployment assumptions and review triggers, see [THREAT_MODEL.md](THREAT_MODEL.md). For data that
may leave the device, see [PRIVACY.md](PRIVACY.md).
