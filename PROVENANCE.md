# Provenance and upstream relationship

## Imported source

This repository was derived from
[avenoxai/avenoxbeyin](https://github.com/avenoxai/avenoxbeyin). The documented upstream baseline is
commit:

```text
3961c0cb5afb5a4803b2ce19e2464c093ba934a6
avenoxbeyin v1 — open-source AI second brain template
```

The public repository intentionally starts from a clean root containing the reviewed Windows snapshot,
not the private development commit graph or pull-request history. The maintainer retains that private
archive for audit and recovery. This is a derived repository, not a GitHub-native fork; the upstream
commit identifier, original license notice, and material transformation record are preserved here.

## Material transformations

The Windows fork replaces the original platform-specific activation and automation path with:

- a fail-closed transactional Windows 11 installer;
- deterministic, allowlisted Node.js personalization;
- restrictive gitignored local permissions installed by default, with hooks activated only by explicit opt-in;
- version-pinned optional WinGet prerequisites and protected Windows vault ACLs;
- manifest-based hook drift detection and session-isolated bounded state;
- a version- and signature-validated Obsidian launcher with optional explicit, version-gated Claude consent;
- Windows PowerShell 5.1 and PowerShell 7 CI coverage on pinned Node.js LTS patch versions;
- Windows-specific threat, privacy, setup, architecture, security, and recovery documentation.

These changes do not imply endorsement by the upstream author. Issues in this Windows integration
should be reported to this repository rather than assumed to be upstream defects.

## License

The imported project is MIT licensed. The retained [LICENSE](LICENSE) applies to this derived work and
preserves the original copyright notice. Because the public repository uses a clean root, public commit
history is not a complete authorship record; this document and the upstream repository provide the
required provenance context.

## Verification limits

A commit hash identifies repository content but is not, by itself, a signature or proof that a local
checkout came from the intended maintainer. No signed hardened public release exists yet. Phase 8 must
publish an immutable tag, release checksums or equivalent verification material, and the exact release
commit before public installation instructions can treat an artifact as reviewed.

Until then, follow the source-preview policy in [README.md](README.md), the deployment
constraints in [THREAT_MODEL.md](THREAT_MODEL.md), and the reporting guidance in
[SECURITY.md](SECURITY.md).
