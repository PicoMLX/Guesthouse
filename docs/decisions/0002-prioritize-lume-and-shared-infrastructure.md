# 2. Prioritize Lume candidate work and shared infrastructure

Date: 2026-09-05

## Status

Accepted for work prioritization only. Provider selection remains pending.

## Context

The owner has directed active work toward Lume and shared infrastructure, with new Tart-specific work set aside. [MVP-PLAN.md](../../MVP-PLAN.md) §§1, 3, 4, and 10 still describe the Tart-based implementation plan. [Issue #48](https://github.com/PicoMLX/Guesthouse/issues/48) tracks the roadmap; [issue #82](https://github.com/PicoMLX/Guesthouse/issues/82) tracks Lume as a candidate. Work priority needs to be explicit without converting a candidate into a proven provider.

Issue #82 records a 2026-09-03 observation on macOS 26.4.1: the official Lume 0.5.3 archive matched its published digest but failed strict signature verification. The [candidate runbook](https://github.com/PicoMLX/Guesthouse/blob/931dc8462299feab10b7422130a707ed89204092/docs/runbooks/lume-phase0.md) remains **not run**. Its signed XPC probe is the implemented procedure; its lifecycle and VNC sections require a separate reviewed, bounded runtime diagnostic. This decision adds no experiment or verification result.

## Decision

- Prioritize maintenance and review of the Lume candidate work in #82 and shared infrastructure: storage, redaction, process execution, typed XPC, ownership/recovery models, compatibility checks, and reusable GUI/workspace contracts. Respect each task's dependencies and existing PR coverage.
- Defer new Tart-specific parser, bundle-verification, and lifecycle work tracked by [#13](https://github.com/PicoMLX/Guesthouse/issues/13), [#23](https://github.com/PicoMLX/Guesthouse/issues/23), and [#25](https://github.com/PicoMLX/Guesthouse/issues/25). Retain existing code, PRs, findings, and documentation for reference; deferral is reversible and does not mean completed or rejected.
- Keep reusable work in mixed areas such as [#24](https://github.com/PicoMLX/Guesthouse/issues/24) and [#32](https://github.com/PicoMLX/Guesthouse/issues/32). Review their provider-specific dependencies before reuse. A historical Tart ancestor does not make shared work obsolete or make its Tart lifecycle implementation a Lume implementation.
- Preserve the security boundaries in `MVP-PLAN.md` §§3 and 8: authenticated named XPC operations, service-chosen executables and arguments, private managed storage, strict runtime verification, redacted diagnostics, and no arbitrary host commands or shared host credentials.

Lume remains a candidate. Before accepting it, obtain and pin a corrected artifact that passes strict verification, then have a person complete the signed-app/provider preflight through the reviewed diagnostic boundary. Resolve the required storage, lifecycle, bootstrap-credential, and VNC containment proofs; software tests and CLI help do not establish them. Do not weaken verification to proceed with the rejected artifact.

A separate accepted provider-selection ADR must record the evidence and resulting architecture. Update the plan, gate issues, [phase-zero registry](../phase0/README.md), and [record template](../phase0/TEMPLATE.md) before recording formal Lume gate evidence. Native guest GPU/MLX capability still requires the §10 hardware proof; CPU or Simulator results do not establish it. The existing gate requirements and explicitly limited exception process remain in force.

## Consequences

Tart-specific instructions in the plan remain labeled legacy reference until the provider decision and corresponding updates replace them. Shared requirements continue to govern current work. Future changes should cite this decision when the old Tart work order conflicts with the active priority.

No phase-zero gate passes or fails because of this decision. All nine records remain not started, and the complete-path gate still precedes splitting the later-phase epics. Issues #48 and #82 remain open tracking work and evidence; this documentation change closes neither.
