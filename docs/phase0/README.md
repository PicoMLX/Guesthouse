# Phase 0: recorded gate results

`MVP-PLAN.md` §10 defines eight phase-zero gates plus a final complete-path run. Each is an experiment a person runs on the reference Mac. The result lives here, in one file per gate, written from [TEMPLATE.md](TEMPLATE.md).

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

Status values: `not started`, `in progress`, `passed`, `passed with follow-ups`, `failed`, `exception approved`. A gate moves from `failed` to `exception approved` only when an ADR in `docs/decisions/` records the approved exception and the record links it. Update this table in the same pull request as the record.

## What a passing phase 0 means

Every gate above has status `passed`, `passed with follow-ups`, or `exception approved`, each with a record of the exact versions used, and the complete-path run reports total setup time, active user time, peak disk and memory use, and the number of guest-console interventions. A `failed` gate blocks phase 0: `MVP-PLAN.md` §10 requires resolving a failed lifecycle, pairing, cold-boot, or GPU gate before expanding the UI. The only way past a failed gate is `exception approved`: an explicit, approved exception recorded as an ADR in [`docs/decisions/`](../decisions/README.md) that states what was not proven and why work continues anyway, linked from the gate record. Decisions that came out of the gates are also written as ADRs. Only then are the Phase 2 to 5 epics split into implementation issues.
