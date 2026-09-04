import Darwin
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
        // The kernel reports the real path (`/private/var/…`, not `/var/…`); the recorded path
        // is the same form, so the reconciler compares like with like.
        let resolvedExecutable = Self.realPath(of: executable)
        guard live.executablePath == resolvedExecutable, live.argumentsDigest == LiveProcessEnumerator.digest(of: arguments) else {
            throw SupervisionError.processMismatch(pid: pid)
        }
        // The process must name the VM the caller says it launched, and that VM must be the
        // one this environment owns: all three have to agree, or later reconciliation would
        // claim the wrong machine, and a record that disagrees with itself would make the
        // whole identity document unreadable on the next start (MVP-PLAN.md §4).
        guard live.claimedVMName == vmName, vmName == environment.tartVMName else {
            throw SupervisionError.processMismatch(pid: pid)
        }
        // The start time is stored exactly as observed: the reconciler compares it for
        // equality, and the store persists dates losslessly.
        let identity = ProcessIdentity(
            pid: pid,
            startTime: live.startTime,
            executablePath: resolvedExecutable,
            argumentsDigest: LiveProcessEnumerator.digest(of: arguments),
            vmName: vmName,
            environmentID: environment,
            recordedAt: Date()
        )
        try await store.record(identity)
        return identity
    }

    /// The recorded identity for an environment, if any.
    public func identity(for environment: EnvironmentID) async -> ProcessIdentity? {
        await store.identity(for: environment)
    }

    /// What the process table says about a recorded identity. `absent` is proof the recorded
    /// process is gone; `unavailable` is the process table declining to answer, which is not
    /// the same thing and must never end supervision (MVP-PLAN.md §4).
    public enum IdentityObservation: Hashable, Sendable {
        case present(LiveProcess)
        case absent
        case unavailable
    }

    /// Observes `identity` against the live process table. A PID that now carries a different
    /// start time, executable, or arguments belongs to another process, which proves the
    /// recorded one exited; a PID that exists but cannot be read proves nothing.
    public func observe(_ identity: ProcessIdentity) -> IdentityObservation {
        switch enumerator.observe(pid: identity.pid) {
        case .absent:
            .absent
        case .unavailable:
            .unavailable
        case .present(let live):
            live.startTime == identity.startTime
                && live.executablePath == identity.executablePath
                && live.argumentsDigest == identity.argumentsDigest
                ? .present(live) : .absent
        }
    }

    /// The live process that is exactly `identity` (same PID, start time, executable, and
    /// arguments), or `nil`: a PID that now belongs to another process is never a match.
    /// A caller that must tell "gone" from "unreadable" uses `observe` instead.
    public func verify(_ identity: ProcessIdentity) -> LiveProcess? {
        guard case .present(let live) = observe(identity) else { return nil }
        return live
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
                // One scan answers both questions: which processes are there, and whether any
                // candidate could not be read. An unreadable one is never an exit.
                let scan = enumerator.candidates(executable: URL(fileURLWithPath: recorded.executablePath), pid: recorded.pid)
                guard !scan.unreadable else {
                    verdicts[environment] = .uncertain(.processUnobservable)
                    continue
                }
                let observed = scan.processes
                let verdict: OwnershipVerdict
                switch lock {
                case .unknown:
                    // Without the inventory, "no process" cannot become "exited".
                    let unlocked = ProcessReconciler.reconcile(recorded: recorded, observed: observed, vmLockPresent: true)
                    verdict = unlocked == .uncertain(.lockHeldWithoutProcess) ? .uncertain(.inventoryUnavailable) : unlocked
                case .present, .absent:
                    verdict = ProcessReconciler.reconcile(recorded: recorded, observed: observed, vmLockPresent: lock == .present)
                }
                // That verdict was decided from processes running the *recorded* binary. A Tart
                // at another path — what a runtime upgrade leaves behind — can be starting the
                // same VM right now and appears in no such scan, so the VM's own name is asked
                // for before an exit or an ownership is declared. This holds whatever the
                // inventory said: a missing inventory is a reason to check the process table
                // harder, not to skip it (MVP-PLAN.md §4).
                if verdict == .exited {
                    verdicts[environment] = claimVerdict(forVM: recorded.vmName) ?? .exited
                } else if case .ownedRunning = verdict, otherClaimantExists(ofVM: recorded.vmName, besides: recorded.pid) {
                    // The same scan matters when the record does match: the lock cannot say
                    // which of two processes naming this VM controls it, so an exact match on
                    // its own is not ownership. Only a claimant actually read downgrades this
                    // verdict; an incomplete scan does not, because the recorded process was
                    // read and matched, which an empty scan cannot claim.
                    verdicts[environment] = .uncertain(.anotherProcessClaimsVM)
                } else {
                    verdicts[environment] = verdict
                }
            } else {
                switch lock {
                case .present: verdicts[environment] = .uncertain(.unrecordedLaunch)
                case .unknown: verdicts[environment] = .uncertain(.inventoryUnavailable)
                // No record and no lock, but a live process may already be claiming this VM
                // between its launch and the lock: that is not a free environment.
                case .absent: verdicts[environment] = claimVerdict(forVM: environment.tartVMName)
                }
            }
        }
        return verdicts
    }

    /// What a scan for processes naming `vmName` says about the VM being free: a claimant that
    /// was read, a claimant the scan could not finish reading, or `nil` when the scan proved
    /// neither. `nil` is the only answer that leaves an environment available.
    private func claimVerdict(forVM vmName: String) -> OwnershipVerdict? {
        let claimants = enumerator.claimants(ofVM: vmName)
        if !claimants.processes.isEmpty { return .uncertain(.anotherProcessClaimsVM) }
        return claimants.unreadable ? .uncertain(.processUnobservable) : nil
    }

    /// Whether a process other than `pid` names `vmName`. Used where the recorded process is
    /// alive: a second claimant makes ownership uncertain, but a scan that could not be
    /// finished does not, because the record itself was read and matched.
    private func otherClaimantExists(ofVM vmName: String, besides pid: Int32) -> Bool {
        enumerator.claimants(ofVM: vmName).processes.contains { $0.pid != pid }
    }

    /// Pure helper for tests and for callers that already enumerated: the verdict for one
    /// recorded identity against a supplied observation.
    public static func verdict(recorded: ProcessIdentity, observed: [LiveProcess], vmLockPresent: Bool) -> OwnershipVerdict {
        ProcessReconciler.reconcile(recorded: recorded, observed: observed, vmLockPresent: vmLockPresent)
    }
}

extension OperationSupervisor {
    /// `realpath(3)`: every symbolic link resolved, including the `/var` → `/private/var`
    /// prefix that Foundation's URL resolution keeps.
    static func realPath(of url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard let resolved = realpath(url.path, &buffer) else { return url.path }
        return String(cString: resolved)
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
