# 3. Use structured diagnostics instead of raw-output redaction

Date: 2026-09-08

## Status

Accepted by the owner. Runtime and GUI migration remains required before those pending features merge.

## Context

[Issue #11](https://github.com/PicoMLX/Guesthouse/issues/11) grew from recognizable-secret filtering into a general parser for fragmented, encoded and terminal-rendered credentials. Its dependent PR stack became an MVP blocker. The owner approved excluding raw information from diagnostics while retaining useful error messages.

## Decision

- Diagnostic sinks accept `DiagnosticEvent`: closed operation/outcome/error enums, Guesthouse operation/environment UUIDs, and optional numeric exit status. `DiagnosticFailure` provides fixed explanations and recovery messages. No free-form message/metadata attachment exists.
- `DiagnosticLog` keeps a bounded session history and renders/encodes only those typed records. Its JSON export reconstructs the known schema, not a received dictionary. Unknown enum values fail decoding; ignored extra fields are never forwarded or re-exported. This is not an XPC admission/size validator.
- Raw stdout/stderr stays in bounded temporary runtime-adapter input when an operation needs it. Unused output is drained and discarded. There is no automatic output-to-log bridge and no raw-error fallback.
- Error messages are an allowed, useful product surface, not an exception for arbitrary credential-bearing text. Known causes produce Guesthouse explanations; unknown causes produce a fixed failure message, exit status when known, and inspection/recovery guidance. Never interpolate `localizedDescription`, parser errors, paths, arguments, or raw response snippets into diagnostics.
- Device codes may reach the dedicated temporary sign-in UI. They do not enter log events, OSLog, journals, exports or generic error payloads. Private keys and authorization headers are not diagnostic inputs.
- Keep existing redactor history/tests as deferred reference. Do not activate its public API or make its review convergence an MVP requirement. Resume it only through a separately approved concrete use case.

This supersedes only the redaction/logging direction in [ADR 0002](0002-prioritize-lume-and-shared-infrastructure.md) and `MVP-PLAN.md` §3. Named authenticated XPC, bounded input, safe process lifetime, private credential storage, strict runtime verification, Lume priority and hardware gates remain unchanged.

## Consequences

Unknown failures have less low-level diagnostic detail. The MVP does not export arbitrary guest text, even when requested through a debug flag. Additional diagnostic fields need a concrete use case and an explicit typed contract; do not recreate a generic string dictionary.

Migration uses the existing issues and preserves shared/provider work:

| Area | Required change |
| --- | --- |
| #11 / redactor stack ending at #59 | Structured Core contract replaces the merge prerequisite; old parser PRs are deferred, not declared fixed |
| #7 / #121, #122, #53 | Keep error categories and recovery; replace sanitized raw-text associated values with typed facts and fixed messages |
| #9 / #58 and later XPC envelopes | Carry `DiagnosticEvent`, not `RedactedLine`; explicitly version incompatible wire changes |
| #21 / #69 and provider adapters | Separate bounded parser input from diagnostic events; retain pipe draining, limits, timeout and termination guarantees |
| #27, #29, #30 / GUI and #79 | Consume typed events; show error/recovery messages; export only reconstructed structured records |
| #91 | Cross-session persistence remains deferred and must persist structured records, never old transcripts |

Main's redactor primitives are internal and have no active logging sink. This first replacement adds the public structured contract; it does not claim the unmerged runtime/XPC/GUI stack has already migrated. Each consumer must pass its own integration tests and normal CI/review gate before merging. Existing unresolved parser findings remain deferred evidence, not rejected security reports.

Acceptance is finite: operation/error rendering, typed encode/decode, unknown-field non-propagation, bounded retention, and proof at each consumer that raw output and underlying errors cannot reach diagnostic sinks. Existing process-lifetime and security checks remain required. Batch locally verified changes before publishing to avoid repeated CI runs for individual parser examples.
