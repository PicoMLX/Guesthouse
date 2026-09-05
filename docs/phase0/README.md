# Phase 0: recorded gate results

`MVP-PLAN.md` §10 defines eight phase-zero gates plus a final complete-path run. Each is an experiment a person runs on the reference Mac. The result lives here, in one file per gate, written from [TEMPLATE.md](TEMPLATE.md).

The [Lume/shared work-priority decision](../decisions/0002-prioritize-lume-and-shared-infrastructure.md) records no gate result; all nine gates remain **not started**. Provider-specific procedures require review and updates to the plan, gate issues, registry, and template after a separate accepted provider-selection ADR, before formal Lume gate evidence is recorded. Existing proof requirements and the narrow exception rules below remain unchanged.

A gate record is evidence, not a plan. It is written only from an actual run, never from reasoning about what should happen. Autonomous agents do not run gates and do not fill in these files.

## Gates

| Gate | Issue | Record | Status |
| --- | --- | --- | --- |
| Host boundary and signing | [#34](https://github.com/PicoMLX/Guesthouse/issues/34) | `host-boundary.md` | not started |
| GUI session, VM ownership, and console lifecycle | [#35](https://github.com/PicoMLX/Guesthouse/issues/35) | `lifecycle.md` | not started |
| SSH pairing and cold-boot credentials | [#36](https://github.com/PicoMLX/Guesthouse/issues/36) | `ssh-cold-boot.md` | not started |
| Xcode import transport benchmark | [#37](https://github.com/PicoMLX/Guesthouse/issues/37) | `xcode-import.md` | not started |
| Non-admin Xcode tests and native MLX | [#38](https://github.com/PicoMLX/Guesthouse/issues/38) | `xcode-mlx.md` | not started |
| Multi-repo workflow, local override, review, two draft PRs | [#39](https://github.com/PicoMLX/Guesthouse/issues/39) | `multirepo.md` | not started |
| Guest maintenance authorization and host sleep recovery | [#40](https://github.com/PicoMLX/Guesthouse/issues/40) | `maintenance-sleep.md` | not started |
| Codex desktop and guest CLI compatibility | [#41](https://github.com/PicoMLX/Guesthouse/issues/41) | `compat.md` | not started |
| Complete-path run and go/no-go decision | [#42](https://github.com/PicoMLX/Guesthouse/issues/42) | `full-path.md` | not started |

Status values: `not started`, `in progress`, `passed`, `passed with follow-ups`, `failed`, `exception approved`. Update this table in the same pull request as the record.

`passed with follow-ups` means every required proof in the gate's checklist passed, and what remains is work that does not affect any of them. A gate with a failed proof is `failed`, whatever else went well: the follow-up status never carries an unproven requirement.

`exception approved` exists only for the two proofs where `MVP-PLAN.md` §10 allows a scope or architecture decision instead of a fix: the native MLX/GPU proof in #38 ("obtain a scope or architecture decision") and the local-override proof in #39 ("narrow the supported project shape explicitly"). It covers that proof alone. Every other proof in the same gate's checklist (for example the non-admin Simulator and macOS tests in #38, or graphical review and the two draft PRs in #39) must still pass, the record must mark the excepted proof explicitly, and an ADR in `docs/decisions/` must record the decision, linked from the gate record. Every other gate must reach `passed` or `passed with follow-ups`: §10 says first-boot UI, runtime ownership, secure cold-boot authentication, and GUI-only pairing failures are resolved before the UI expands, not waived.

## What a passing phase 0 means

Every gate above has status `passed`, `passed with follow-ups`, or `exception approved`, each with a record of the exact versions used (and, for the gates whose result depends on the repositories under test, the fixture commits used), and the complete-path run reports total setup time, active user time, peak disk and memory use, and the number of guest-console interventions. The complete-path run (#42) comes last: its record's UTC completion timestamp must be later than every other gate's completion timestamp and than the commits that added the ADRs those gates produced (same-day runs are ordered by timestamp, never by date alone), and it must use the transport, console path, authentication approach, and project shape those decisions selected. A complete-path run made before one of those decisions changed is obsolete and must be repeated. The same applies to the versions: #42 must run on the component tuple the earlier gates validated. If Tart, macOS, Xcode, the Simulator runtime, Codex desktop or CLI, the GitHub CLI, or the provisioning scripts changed since a gate ran, either pin #42 to the validated versions or rerun every gate whose proofs depend on what changed, and record which. A complete-path run on a tuple no gate validated does not close phase 0. A `failed` gate blocks phase 0: `MVP-PLAN.md` §10 requires resolving a failed lifecycle, pairing, cold-boot, or GPU gate before expanding the UI. The only way past a failed gate is `exception approved`, and only for #38 and #39 as described above: an explicit, approved exception recorded as an ADR in [`docs/decisions/`](../decisions/README.md) that states what was not proven and why work continues anyway, linked from the gate record. Decisions that came out of the gates are also written as ADRs. Only then are the Phase 2 to 5 epics split into implementation issues.
