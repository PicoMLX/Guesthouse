# Owned process input closure

The runtime runner's stdin delivery supports `MVP-PLAN.md` §3 and ADR 0003/0004: the host owns its actual pipe, temporary bytes never enter diagnostics, and closing that pipe never proves descendant quiescence or a provider outcome.

The October 2 full package run on the typed probe report composition reproduced three assertions already visible in the probe stack's Cloud reports: `earlyExitReportsUndeliveredInput` reported `inputClosed == false`; the retained-reader regression reported false closure and read a non-EOF result. Both functions then passed unchanged in isolation. That is a local reproduction of the input symptoms, not a diagnosis of the separate native XPC reply timeouts or the Cloud prebuild timeouts.

## Ownership and cancellation

[Apple's Dispatch I/O documentation](https://developer.apple.com/documentation/dispatch/dispatchio/close(flags:)) and the shipped SDK's `dispatch/io.h` specify best-effort interruption of outstanding I/O. The application cannot close the borrowed descriptor before the I/O cleanup handler relinquishes it. Requesting cancellation alone therefore cannot establish EOF.

The existing `InputDelivery` now owns a nonblocking write source on a private serial queue. Each callback attempts at most 16 KiB and treats EAGAIN/EINTR as retryable; descriptor-local `F_SETNOSIGPIPE` preserves the process-wide signal policy. Cancellation fences subsequent writes under the same mutex and releases the pending bytes. An unstarted source is activated for cleanup, so release or cancellation before Start cannot strand the pipe.

Only the source's cancellation handler closes the actual `FileHandle`. [Apple requires this ordering](https://developer.apple.com/documentation/dispatch/dispatchsourceprotocol/setcancelhandler(handler:)) to avoid closing or reusing a descriptor while a handler/system reference can still touch it. The completion group leaves after that close; the report's closure flag remains false if closure fails or the existing deadline expires. No actor/cooperative executor blocks on that group.

## Validation scope

The retained runner tests continue to exercise zero/large input delivery, EOF, unread input, exit, cancellation and deadlines. New real-pipe tests cover a full pipe canceled without reader progress, pre-start cancellation, release before Start and EPIPE after the read end closes. The full-pipe test waits for actual data before canceling and observes real EOF while retaining the read end. Its EOF observation drains only the bounded pending bytes, handles EINTR and waits through EAGAIN within five seconds; no flag or cancellation request substitutes for an actual zero-byte read.

This changes only the existing input owner. It adds no process launcher, signal authority, metadata settlement or synthetic cleanup proof. The process runner's output and descendant inspection policies are unchanged. The production provider remains disabled, the rejected Lume 0.5.3 pin remains unchanged, and no provider/wrapper/installer/VM is executed by these fixtures.
