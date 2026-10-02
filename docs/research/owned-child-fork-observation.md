# Owned-child fork observation

The runtime can retain kernel fork history for an actual child it spawns, when
`OwnedChild.spawn(observingForks: true, ...)` is selected internally. This is a
prerequisite for issues #21 and #82 under [MVP-PLAN.md §§3–4 and 9](../../MVP-PLAN.md)
and [ADR 0004](../decisions/0004-disposable-environments-persistent-work.md).
Ordinary launches continue to report descendant cleanup as unproven.

The observed launch starts suspended. Guesthouse captures its kernel birth and
registers one private `EVFILT_PROC` queue for `NOTE_FORK | NOTE_EXIT` before
resuming user code. The exclusive child waiter reads that queue only after its
exit observation, before the sole reap. No earlier read clears accumulated fork
flags. Only a successful reap and matching terminal kernel event can publish
`exitedWithoutFork` on that retained child.

Apple's [spawn implementation](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_exec.c)
suspends a child before it runs. Its
[process event filter](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_event.c)
accumulates subscribed flags until delivery. The
[fork implementation](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_fork.c)
and spawn implementation notify the parent's process filter when creating a
child. Native fixture tests separately cover `fork`, `vfork`, and `posix_spawn`.

If birth or queue registration is unavailable, Guesthouse does not resume user
code. A refused resume requests termination of only this actual unreaped child.
Signal delivery is never exit evidence. Failed observation or reaping leaves
the conclusion unproven. The private initial resume precedes the child owner's
publication and reaper; it does not expose a PID adoption or general signal API.

Any observed fork leaves descendants unproven, including children that already
exited or escaped their parent's session. Apple's
[current event header](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/sys/event.h)
marks automatic child tracking unsupported. An empty group snapshot or late
queue registration cannot reconstruct launch history.

Run the native fixtures with:

```bash
swift test --package-path Packages/GuesthouseRuntimeKit --filter OwnedChildForkTests -Xswiftc -warnings-as-errors
```

Nine test functions run benign fixture code compiled by the system compiler;
they exercise fast exit, creation paths, a live escaped descendant, ordinary
launches, unavailable birth, refused resume, and lost reap authority. They were
validated on arm64 macOS 26.6.2 (25G83). Removing the fork subscription makes the
descendant cases fail.

StateStore's runtime-only `settleInspectedLumeLaunch` explicitly checks the current
intent, service epoch, protected root/record and actually retained child. Its live
history must be `exitedWithoutFork`; a saved receipt cannot substitute for that
owner. The same lifetime lock, physical-root lease and atomic writer publish idle
metadata before releasing the child. Cancellation before publication changes
nothing. A publication failure retains actual ownership and the current store's
uncertainty fence, even if a complete idle record became visible before a failed
directory synchronization.

Run this integration's eleven test functions with:

```bash
swift test --package-path Packages/GuesthouseRuntimeKit --filter LumeLaunchSettlementTests -Xswiftc -warnings-as-errors
```

They check explicit completion and preserved work, running/ordinary/forked
children, missing or foreign receipts, restart refusal, queued close/root change,
cancellation and failed publication. Omitting the live-history guard produces
eight issues across the ordinary-exit, running-child and actual-fork regressions.

ProcessRunner's runtime-only invocation can opt into `forkHistory`. It delegates
to the same suspended launch and exclusive observer; its default remains ordinary
unobserved execution. The actual child owner carries history and the supplied
attempt ID through the runner. `ProcessReport.descendantScopeUnproven` remains
true: a parsed response, exit, timeout or cancellation is not settlement authority.

Native runner fixtures cover fast no-fork exit and actual `fork`, `vfork` and
`posix_spawn`. StateStore integration retains intent/receipt after runner return
and interruption, refuses ordinary or forked replacement, and allows only separate
explicit inspection of the retained completed no-fork owner. Removing the runner's
observation option produces four failed history assertions and one refused
settlement. These are shared runner/lifecycle prerequisites under MVP-PLAN.md
§§3–4/9 and ADR 0004, not provider execution or a provider-selection decision.

This history remains attached to a live child owner, never persisted as reusable
proof. Forked launches and restart recovery still require genuine reconciliation;
provider inventory and repair remain unfinished.

StateStore's internal fixed-launch boundary checks ownership and protected writable
paths, then performs strict bundle verification before publishing intent. It repeats
complete verification/coherence and writable-path checks after publication, and
uses the same synchronous runner spawner without another actor suspension before
attaching the actual child. Failed attachment retains that owner and requests only
direct-child termination; signals never settle metadata. Startup ownership is
scheduled before synchronous return, even if the facade is dropped.

The only options are version and create/detached-run/attach help, with no stdin,
five-second timeout, one-second termination grace and bounded stdout. This boundary
has no GUI/XPC consumer. Refusal tests use missing/unsigned fixtures; the historical
pin remains rejected, so no verified candidate launch happy path is claimed. The
complete bounded probe, typed XPC reply and actual candidate execution
remain separate work. No provider, installer,
wrapper, or VM is activated, and no metadata is cleared automatically on return,
timeout, cancellation or a delivered signal.

`inspectLumeProbeResponse` explicitly completes an already owned fixed launch. It
matches the protected record, current epoch and exact live child before waiting,
then rechecks ownership after waiting. Only complete, bounded UTF-8 responses are
interpreted; version text must match the pin exactly, including its components.
Help results expose advertised options only, with no VNC, Stop or GPU proof.
Raw bytes never enter diagnostic events, errors, metadata or exports. Diagnostics
use the persisted operation UUID and no fabricated environment identity (MVP §3).

A parsed response and zero exit status still cannot produce success: explicit live
no-fork inspection and atomic idle publication must finish first. Failed responses,
cancellation, timeout, ordinary/forked children, foreign receipts, restart and
publication uncertainty keep the launch blocked. `LumeProbeResponseTests` uses real
benign native processes and actual persisted ownership, with no verifier override
or synthetic cleanup proof. This completion boundary grants no launch authority;
production launches still require the existing strict fixed-launch boundary.

StateStore's internal `probeLume` retains one physical-root lease around the entire
version/create/detached-run/attach inspection. It reuses the fixed strict launcher
and actual inspected completion directly, with no nested acquisition or second
writer. Every step must settle before another starts; any refusal stops the sequence.
Cancellation is checked before and after each step. All three help surfaces must
advertise storage for the aggregate storage advertisement to be true.

`LumeProbeSequenceTests` exercises sequencing with real benign owned children and
refusal at the production entry. These fixtures grant no provider verification
authority. The signed candidate happy path remains unvalidated while the current
pin is rejected. Typed XPC wiring, actual candidate execution and fork/restart
reconciliation remain separate work; the aggregate never denotes provider readiness.

The Core `RuntimeProbeReport` carries only typed advertisements, closed failures and
at most eight typed diagnostic events. Its complete trace requires four distinct
started/succeeded pairs; refusal can retain prior real pairs and a final matching
failure, or no events when no diagnostic identity is available. An empty trace
does not prove that effects were unsent. `probeLumeReport` reuses `DiagnosticLog`
to capture the actual inspection events, with no invented operation/environment
identity or raw-error classifier. Core coding refuses foreign, incomplete,
contradictory or oversized traces. This data is not provider or cleanup authority.
Native request activation, lifetime/cancellation routing and GUI consumers remain
separate work; the ordinary version handshake still performs no provider execution.
