# Gate: <name>

Issue: #<number>. Run by: <name>. Date: <YYYY-MM-DD>. Status: <in progress | passed | failed | passed with follow-ups>.

## Versions

| Component | Value |
| --- | --- |
| Host Mac | <model, RAM> |
| Host macOS | <version (build)> |
| Guesthouse build | <git SHA, signed or debug, launched from Finder or Xcode> |
| Tart | <version, Team ID verified yes/no> |
| Guest macOS | <version (build)> |
| Xcode (guest) | <version (build)> |
| Codex desktop | <version (build)> |
| Codex CLI (guest) | <version, path> |
| GitHub CLI (guest) | <version> |
| Provisioning scripts | <version or commit> |

## Required proofs

Copy the required proofs from the gate issue as a checklist and mark each one.

- [ ] <proof 1>
- [ ] <proof 2>

## Procedure and evidence

For each step: what was done, what was observed, and where the evidence is. Every piece of evidence must be redacted before it is committed: log excerpts and screenshots alike must contain no tokens, device codes, bootstrap or account passwords, private keys, or account identifiers. Review each screenshot for on-screen secrets (SSH pairing and provider sign-in screens are the usual offenders) and crop or mask them. Screenshots go under `docs/phase0/evidence/<gate>/`.

1. <step>: <observation>. Evidence: <path or excerpt>.

## Measurements

| Measure | Value |
| --- | --- |
| Total wall-clock time | |
| Active user time | |
| Peak host disk used | |
| Peak guest disk used | |
| Peak host memory pressure | |
| Guest-console interventions | |
| Terminal or script use by the engineer (must become GUI operations) | |

## Decision

What this gate decides for the design, and what changes in the plan or issues as a result. If the gate settled a design question (for example the Xcode transport, the console path, or the cold-boot authentication requirement), link the ADR written for it in `docs/decisions/`. If it did not, state explicitly: "No architectural decision resulted from this gate."

## Follow-ups

Issues opened or updated because of this run.
