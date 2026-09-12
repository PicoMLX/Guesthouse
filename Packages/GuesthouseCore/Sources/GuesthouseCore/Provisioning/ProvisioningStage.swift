import Foundation

/// The checkpoints of MVP-PLAN.md §9, in order:
/// Preflight → Runtime ready → macOS installed → Needs guest setup → SSH paired
/// → Guest secured → Xcode/tools ready → Accounts ready → Workspace validated → Ready.
///
/// A stage names the checkpoint an operation is working toward. "Needs guest setup" is a
/// checkpoint like the others; the fact that it requires the user at the console is expressed
/// by `StageStatus.needsUserAction`, not by the stage itself.
public enum ProvisioningStage: String, Codable, Hashable, Sendable, CaseIterable, Comparable {
    case preflight
    case runtimeReady
    case macOSInstalled
    case needsGuestSetup
    case sshPaired
    case guestSecured
    case xcodeToolsReady
    case accountsReady
    case workspaceValidated
    case ready

    public static let first: ProvisioningStage = .preflight

    /// The stage after this one, or `nil` for `ready`.
    public var next: ProvisioningStage? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    public static func < (lhs: ProvisioningStage, rhs: ProvisioningStage) -> Bool {
        let all = Self.allCases
        return all.firstIndex(of: lhs)! < all.firstIndex(of: rhs)!
    }
}

/// Proof, written to the journal, that a stage was reached.
public struct Checkpoint: Codable, Hashable, Sendable {
    public let stage: ProvisioningStage
    public let reachedAt: Date

    public init(stage: ProvisioningStage, reachedAt: Date) {
        self.stage = stage
        self.reachedAt = reachedAt
    }
}
