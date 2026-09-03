import Foundation
import GuesthouseCore
import Synchronization
import XPC

/// Keeps the service alive while it supervises work, and answers "is the VM I recorded still
/// mine?" after a relaunch (MVP-PLAN.md §3, "Keep documented XPC activity/transactions
/// outstanding while supervising running VMs or operations"; §4, process ownership).
///
/// Finding, documented as the plan asks: the Swift `XPCListener`/`XPCSession` API keeps a
/// bundled XPC service alive only while a message is being handled or a reply is pending.
/// Once `runtimeVersion` or `startEnvironment` has replied, launchd may terminate an idle
/// service and abandon a running VM. Supervision therefore holds an explicit
/// `xpc_transaction_begin()` per in-flight operation and one for every supervised VM
/// process, ended only when the operation finishes or the process is confirmed gone. This
/// does not outlive the client: when the app quits, the service still goes with it (§3).
public final class OperationSupervisor: Sendable {
    /// A held transaction. Ending it twice is harmless.
    public final class Token: Sendable {
        private let ended = Mutex(false)
        private let onEnd: @Sendable () -> Void

        init(onEnd: @escaping @Sendable () -> Void) {
            self.onEnd = onEnd
        }

        public func end() {
            let first = ended.withLock { flag -> Bool in
                if flag { return false }
                flag = true
                return true
            }
            if first { onEnd() }
        }

        deinit { end() }
    }

    private let outstanding = Mutex(0)
    private let enumerator: LiveProcessEnumerator
    private let store: ProcessIdentityStore

    public init(store: ProcessIdentityStore, enumerator: LiveProcessEnumerator = LiveProcessEnumerator()) {
        self.store = store
        self.enumerator = enumerator
    }

    /// How many transactions are currently held. Zero means the service may idle-exit.
    public var outstandingTransactions: Int { outstanding.withLock { $0 } }

    /// Begins a transaction for an operation or a supervised process. Keep the token for as
    /// long as the work must keep the service alive.
    public func hold(_ reason: String) -> Token {
        outstanding.withLock { $0 += 1 }
        xpc_transaction_begin()
        return Token { [self] in
            self.outstanding.withLock { $0 -= 1 }
            xpc_transaction_end()
        }
    }

    /// Records a launched process durably before the caller reports it as started.
    public func recordLaunch(pid: Int32, executable: URL, arguments: [String], vmName: String, environment: EnvironmentID) async throws -> ProcessIdentity {
        guard let live = enumerator.live(pid: pid) else {
            throw SupervisionError.processNotObservable(pid: pid)
        }
        // Dates are rounded to milliseconds so the persisted record reads back exactly; the
        // reconciler's one-second start-time tolerance covers the lost microseconds.
        let identity = ProcessIdentity(
            pid: pid,
            startTime: Self.millisecondPrecision(live.startTime),
            executablePath: executable.path,
            argumentsDigest: LiveProcessEnumerator.digest(of: arguments),
            vmName: vmName,
            environmentID: environment,
            recordedAt: Self.millisecondPrecision(Date())
        )
        try await store.record(identity)
        return identity
    }

    /// Forgets a process that is confirmed gone.
    public func forget(_ environment: EnvironmentID) async throws {
        try await store.remove(environment)
    }

    /// Reconciles every recorded identity against the live process table.
    /// - Parameter vmLockPresent: whether the VM's lock is held, per environment, as observed
    ///   by the caller; unknown lock state is treated as present so the verdict errs toward
    ///   uncertainty.
    public func reconcile(vmLockPresent: (EnvironmentID) -> Bool?) async -> [EnvironmentID: OwnershipVerdict] {
        var verdicts: [EnvironmentID: OwnershipVerdict] = [:]
        for (environment, recorded) in await store.all {
            let observed = enumerator.candidates(executable: URL(fileURLWithPath: recorded.executablePath), pid: recorded.pid)
            verdicts[environment] = ProcessReconciler.reconcile(recorded: recorded, observed: observed, vmLockPresent: vmLockPresent(environment) ?? true)
        }
        return verdicts
    }

    /// Pure helper for tests and for callers that already enumerated: the verdict for one
    /// recorded identity against a supplied observation.
    public static func verdict(recorded: ProcessIdentity, observed: [LiveProcess], vmLockPresent: Bool) -> OwnershipVerdict {
        ProcessReconciler.reconcile(recorded: recorded, observed: observed, vmLockPresent: vmLockPresent)
    }
}

extension OperationSupervisor {
    static func millisecondPrecision(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}

public enum SupervisionError: Error, Hashable, Sendable {
    case processNotObservable(pid: Int32)
}
