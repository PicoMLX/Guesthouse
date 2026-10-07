import Foundation
import GuesthouseCore

enum LumeLaunchValidationError: Error, CaseIterable, Hashable, Sendable, LocalizedError {
    case storageMismatch, bundleChanged

    var userMessage: String {
        switch self {
        case .storageMismatch: "The verified Lume runtime does not belong to the selected Guesthouse storage. Inspect the selected storage before continuing."
        case .bundleChanged: "The installed Lume runtime changed after verification. Inspect it and acquire a newly verified runtime before continuing."
        }
    }
    var recoveryActions: [RecoveryAction] {
        self == .storageMismatch ? [.inspectState, .cancel] : [.repair(.runtime), .cancel]
    }
    var errorDescription: String? { userMessage }
}

/// Retained #84 launch-binding checks on #279/#280's storage and verifier (MVP §§3–4).
/// No runner, provider command, activation, metadata writer or raw diagnostic output.
/// Call at every launch inside LumeRuntimeCoordinator.shared's whole-operation lease; every
/// managed replacement must share that lease. The final path-based interval is subject to the
/// same-user process exclusion. #84's cleanup/restart ownership requirement remains open.
enum LumeLaunchValidation {
    /// An expected location/snapshot is only a coherence input; even an injected unsigned
    /// fixture cannot mint a VerifiedLumeBundle without the production strict signature gate.
    static func reverify(expected: LumeBundle, identity: LumeBundleFileIdentity,
                         in storage: RuntimeStorage) throws -> VerifiedLumeBundle {
        try relocate(expected: expected, identity: identity, in: storage).verify()
    }

    /// Read-only split for deterministic binding regressions. This result is NOT verified
    /// authority: callers must still run `verify()`; no process API accepts a LumeBundle.
    static func relocate(expected: LumeBundle, identity: LumeBundleFileIdentity,
                         in storage: RuntimeStorage) throws -> LumeBundle {
        guard expected.url == (try LumeBundle.expectedLocation(in: storage)) else {
            throw LumeLaunchValidationError.storageMismatch
        }
        guard let current = try LumeBundle.locate(in: storage) else {
            throw LumeLaunchValidationError.bundleChanged
        }
        guard let observed = current.fileIdentity else { throw LumeVerificationError.insecureBundleLayout }
        guard observed == identity else { throw LumeLaunchValidationError.bundleChanged }
        return current
    }
}
