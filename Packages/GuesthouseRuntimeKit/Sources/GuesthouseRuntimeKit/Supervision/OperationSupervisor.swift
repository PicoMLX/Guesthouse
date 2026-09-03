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

    /// Records a launched process durably before the caller reports it as started. The
    /// observed process must be the one described: same executable and arguments, so a PID
    /// reused by another process between launch and observation is never recorded as ours.
    public func recordLaunch(pid: Int32, executable: URL, arguments: [String], vmName: String, environment: EnvironmentID) async throws -> ProcessIdentity {
        guard let live = enumerator.live(pid: pid) else {
            throw SupervisionError.processNotObservable(pid: pid)
        }
        guard live.executablePath == executable.path, live.argumentsDigest == LiveProcessEnumerator.digest(of: arguments) else {
            throw SupervisionError.processMismatch(pid: pid)
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

    /// What the caller knows about a VM's lock.
    public enum LockObservation: Sendable {
        case present
        case absent
        /// The inventory could not be read.
        case unknown
    }

    /// Reconciles every known environment against the live process table.
    ///
    /// Environments with a recorded identity get the reconciler's verdict; an environment
    /// without one whose VM lock is held is `uncertain(.unrecordedLaunch)` (the service died
    /// between spawning Tart and persisting the identity, or someone else started the VM);
    /// an unknown lock state is `uncertain(.inventoryUnavailable)`. An environment with no
    /// record and no lock has no verdict.
    public func reconcile(environments: [EnvironmentID], vmLock: (EnvironmentID) -> LockObservation) async -> [EnvironmentID: OwnershipVerdict] {
        var verdicts: [EnvironmentID: OwnershipVerdict] = [:]
        let recordedIdentities = await store.all
        for environment in Set(environments).union(recordedIdentities.keys) {
            let lock = vmLock(environment)
            if let recorded = recordedIdentities[environment] {
                let observed = enumerator.candidates(executable: URL(fileURLWithPath: recorded.executablePath), pid: recorded.pid)
                switch lock {
                case .unknown:
                    // Without the inventory, "no process" cannot become "exited".
                    let verdict = ProcessReconciler.reconcile(recorded: recorded, observed: observed, vmLockPresent: true)
                    verdicts[environment] = verdict == .uncertain(.lockHeldWithoutProcess) ? .uncertain(.inventoryUnavailable) : verdict
                case .present, .absent:
                    verdicts[environment] = ProcessReconciler.reconcile(recorded: recorded, observed: observed, vmLockPresent: lock == .present)
                }
            } else {
                switch lock {
                case .present: verdicts[environment] = .uncertain(.unrecordedLaunch)
                case .unknown: verdicts[environment] = .uncertain(.inventoryUnavailable)
                case .absent: break
                }
            }
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

/// Failures while recording a launch. Each leaves the outcome unknown until the caller
/// inspects the actual state, and says so.
public enum SupervisionError: Error, Hashable, Sendable, LocalizedError {
    /// The launched process could not be read from the process table.
    case processNotObservable(pid: Int32)
    /// The process with that PID is not the one that was launched.
    case processMismatch(pid: Int32)

    public var userMessage: String {
        switch self {
        case .processNotObservable:
            "Guesthouse started the development Mac's virtual machine but could not observe the process afterwards. Guesthouse will inspect the actual state before offering anything else."
        case .processMismatch:
            "The process Guesthouse started for the development Mac was replaced by another process before it could be recorded. Guesthouse will inspect the actual state before offering anything else."
        }
    }

    public var recoveryActions: [RecoveryAction] { [.inspectState, .cancel] }
    public var errorDescription: String? { userMessage }
}
