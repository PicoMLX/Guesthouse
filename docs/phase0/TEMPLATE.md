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

For each step: what was done, what was observed, and where the evidence is. Log excerpts must be redacted (no tokens, device codes, passwords, or private keys). Screenshots go under `docs/phase0/evidence/<gate>/`.

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

What this gate decides for the design, and what changes in the plan or issues as a result. Reference the ADR if one was written.

## Follow-ups

Issues opened or updated because of this run.
