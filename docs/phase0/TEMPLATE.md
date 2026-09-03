# Gate: `<name>`

Issue: `#<number>`. Run by: `<name>`. Completed: `<YYYY-MM-DDTHH:MM:SSZ>` (UTC). Guesthouse commit: `<git SHA of the checkout used>`. Status: `<in progress | passed | passed with follow-ups | failed | exception approved (link the ADR; only gates #38 and #39)>`.

## Versions

| Component | Value |
| --- | --- |
| Host Mac | `<model, RAM>` |
| Host macOS | `<version (build)>` |
| Guesthouse signed build | `<git SHA; Developer ID or development signing; launched from Finder>` |
| Guesthouse debug build | `<git SHA; launched from Xcode>` |
| Tart | `<version, Team ID verified yes/no>` |
| Guest macOS | `<version (build)>` |
| Xcode (guest) | `<version (build)>` |
| Simulator runtime (guest) | `<runtime version (build); destination used>` |
| Codex desktop | `<version (build)>` |
| Codex CLI (guest) | `<version, path>` |
| GitHub CLI (guest) | `<version>` |
| Git (guest) | `<version; executable path as resolved by the login shell>` |
| Provisioning scripts | `<version or commit>` |
| Guest VM configuration | `<preset name; CPU count; RAM; logical disk capacity>` |

## Required proofs

Copy the required proofs from the gate issue as a checklist and mark each one.

- [ ] `<proof 1>`
- [ ] `<proof 2>`

## Procedure and evidence

For each step: what was done, what was observed, and where the evidence is. Every piece of evidence must be redacted before it is committed: log excerpts and screenshots alike must contain no tokens, device codes, bootstrap or account passwords, private keys, or account identifiers. Review each screenshot for on-screen secrets (SSH pairing and provider sign-in screens are the usual offenders) and crop or mask them. Screenshots go under `docs/phase0/evidence/<gate>/`.

1. `<step>`: `<observation>`. Evidence: `<path or excerpt>`.

## Measurements

| Measure | Value |
| --- | --- |
| Total wall-clock time | |
| Active user time | |
| Peak host disk used | |
| Peak guest disk used | |
| Peak host memory used | |
| Peak guest memory used | |
| Peak host memory pressure | |
| Guest-console interventions | |
| Diagnostic-only commands used by the engineer (allowed by §10; no product follow-up) | |
| Actions performed by script or Terminal that must become GUI operations before beta | |

## Decision

What this gate decides for the design, and what changes in the plan or issues as a result. If the gate settled a design question (for example the Xcode transport, the console path, or the cold-boot authentication requirement), link the ADR written for it in `docs/decisions/`. If it did not, state explicitly: "No architectural decision resulted from this gate."

## Follow-ups

Issues opened or updated because of this run.
