# Compatibility migration

This migrates [issue #14](https://github.com/PicoMLX/Guesthouse/issues/14) from the old [#55 stack](https://github.com/PicoMLX/Guesthouse/pull/55) onto the structured Core contract. It implements the identity and connection-evidence requirements in `MVP-PLAN.md` §5, following [ADR 0002](decisions/0002-prioritize-lume-and-shared-infrastructure.md) and [ADR 0003](decisions/0003-structured-diagnostics.md).

## Private identity is not diagnostics

Compatibility records retain exact tool versions, resolved executable locations and capabilities for comparison. These are private state, not sanitized messages or exportable diagnostics. A valid path can contain a private name. No general-purpose secret recognizer attempts to decide whether arbitrary text is safe.

| Input | Record boundary |
| --- | --- |
| Host macOS version | Bounded dotted numeric `SemanticVersion` |
| Tool versions | Bounded ASCII identifiers starting with a digit; prerelease/build punctuation allowed |
| macOS and Xcode builds | Bounded ASCII alphanumeric identifiers starting with a digit |
| Capabilities | At most 64 bounded ASCII identifiers; canonical ordering and duplicates normalized only within that limit |
| Executable locations | Bounded absolute paths without dot components or control/format characters; Unicode and interior spaces preserved |
| Installation/protocol counts | Exactly one Codex CLI installation and a positive runtime protocol version |
| Connection evidence | Explicit user confirmation, or a registered status reader; this build registers none |

The probe must actually resolve executable locations and collect the observed identity. A value model cannot prove filesystem identity, a successful connection, or a user's action. The GUI must obtain confirmation only after the actual Codex workspace flow. A successful version command never supplies that confirmation.

## Provider and schema identity

The exact tuple carries both `runtimeProvider` and `runtimeVersion`; equal version strings do not make Lume and Tart interchangeable. Missing fields remain unknown. Tart is retained only as legacy identity, not as a newly selected provider.

Connection records use their own schema 2. Legacy schema 1 lacks explicit provider identity and is not accepted as new evidence. Unsupported or malformed history produces a fixed error with inspection/cancel actions, not automatic replacement or retry. The consumer must arrange any new confirmation separately and preserve unreadable state until it is inspected. Its storage reader must bound file input before decoding.

## Error and export boundary

`CompatibilityRecordError` carries a closed field identifier, schema numbers, or a fixed failure category. Its messages and recovery actions never include the rejected value or decoder description. `decodeHistory` converts decoding failures to that fixed error surface.

Neither `CompatibilityTuple` nor `ConnectionVerificationRecord` is a `DiagnosticEvent` attachment. Do not serialize these private records into diagnostics, export their paths, or log underlying decoding errors. Runtime/XPC/GUI consumers still need integration tests that enforce the [structured diagnostics boundary](structured-diagnostics-migration.md).

## Remaining integration

The numeric-version, tuple, record, manifest-entry and manifest-container changes are independently reviewed prerequisites. The provider-aware manifest uses its own schema 2 and typed incompatibility reasons; unknown schemas and raw-string reasons are rejected. Its notes and evidence references are private resource data, not error messages or diagnostic attachments.

The bundled manifest deliberately has no tested or verified combinations. The original Tart seed contained placeholders, not Lume evidence; it remains available in #55's preserved branch. Only actual validation should populate the active resource. This does not waive provider-selection or hardware gates.

The evaluator still needs migration before issue #14 is complete. These models do not implement probes or persistence, or certify a Lume configuration. Preserve the old PR's remaining behavior and useful tests without importing its redactor ancestry. Runtime/XPC/GUI consumers require their own integration tests and review.
