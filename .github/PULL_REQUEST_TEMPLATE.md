## What changed

Describe the focused change and its user or developer impact.

## Why

Explain the root cause or requirement. Call out any trust-boundary, permission, dependency, installer,
launcher, or hook behavior change.

## Validation

- [ ] `powershell.exe -NoProfile -NonInteractive -File .\tests\Invoke-Tests.ps1` passes.
- [ ] Tests and examples use synthetic data only.
- [ ] No credentials, real notes, private paths, local settings, runtime state, or unredacted logs are included.
- [ ] Relevant security, privacy, setup, architecture, troubleshooting, provenance, or acceptance documentation is updated.
- [ ] Existing fail-closed checks were preserved, or the threat-model change is explicitly justified.

## Security and privacy notes

State what data can be read, written, executed, logged, or sent over the network after this change.
Write `No change` only after checking the applicable boundaries.
