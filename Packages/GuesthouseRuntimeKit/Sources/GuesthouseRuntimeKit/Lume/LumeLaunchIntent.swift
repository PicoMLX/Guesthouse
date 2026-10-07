import Foundation
import GuesthouseCore

/// Runtime-only correlation, never a PID, executable path or fabricated environment identity.
/// Persist before entering a launcher, including before its first suspension (MVP §§3–4).
struct LumeLaunchIntent: Codable, Equatable, Sendable {
    enum Command: String, Codable, CaseIterable, Sendable {
        case version, createHelp, detachedRunHelp, attachHelp
    }
    let operationID: UUID
    let serviceEpoch: UUID
    let attemptID: UUID
    let command: Command
}

enum LumeLaunchOwnershipFailure: Error, Equatable, Sendable, LocalizedError {
    case inspectionRequired, unsupportedFormat, corruptRecord, changedRoot
    var userMessage: String {
        "Guesthouse cannot establish that this runtime is available for another launch. Preserve its storage and inspect the actual owned processes before continuing."
    }
    var recoveryActions: [RecoveryAction] { [.inspectState, .cancel] }
    var errorDescription: String? { userMessage }
}

/// One bounded record owned by StateStore's existing lifetime lock. Genesis is permitted only
/// during createFresh's exclusive creation of a new root. Missing records on reopening never
/// mean idle. A saved intent stays unresolved across return, throw, cancellation and restart.
/// There is deliberately no settlement API: direct-child exit and synthetic inspection do not
/// prove whole-owned-set quiescence. No provider/probe execution is wired by this slice.
struct LumeRuntimeOwnership: Codable, Equatable, Sendable {
    let root: StateFileIdentity
    let intent: LumeLaunchIntent?
    let child: OwnedChild.LaunchIdentity?

    init(root: StateFileIdentity, intent: LumeLaunchIntent? = nil, child: OwnedChild.LaunchIdentity? = nil) {
        self.root = root
        self.intent = intent
        self.child = child
    }

    private struct Wire: Codable {
        let format: Int
        let root: StateFileIdentity
        let intent: LumeLaunchIntent?
        let child: OwnedChild.LaunchIdentity?
    }
    init(from decoder: any Decoder) throws {
        let wire = try Wire(from: decoder)
        guard wire.format == 1 else { throw LumeLaunchOwnershipFailure.unsupportedFormat }
        if let child = wire.child {
            guard child.isConsistent, child.runID == wire.intent?.attemptID else {
                throw LumeLaunchOwnershipFailure.corruptRecord
            }
        }
        root = wire.root
        intent = wire.intent
        child = wire.child
    }
    func encode(to encoder: any Encoder) throws {
        try Wire(format: 1, root: root, intent: intent, child: child).encode(to: encoder)
    }
}
