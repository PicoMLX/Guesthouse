import Foundation

/// Proof that Codex desktop really opened a guest workspace with an exact combination
/// of versions (MVP-PLAN.md §5: "Record connection verification for that exact tuple only
/// after the real desktop flow succeeds").
///
/// A record can only be created from `DesktopConnectionEvidence`. Version queries such as
/// `codex --version` are not evidence and have no way to produce one.
public struct ConnectionVerificationRecord: Codable, Hashable, Sendable {
    public let tuple: CompatibilityTuple
    public let verifiedAt: Date
    public let evidence: DesktopConnectionEvidence

    public init(tuple: CompatibilityTuple, verifiedAt: Date, evidence: DesktopConnectionEvidence) {
        self.tuple = tuple
        self.verifiedAt = verifiedAt
        self.evidence = evidence
    }
}

/// How a real desktop connection was confirmed.
public enum DesktopConnectionEvidence: Codable, Hashable, Sendable {
    /// The user confirmed in the GUI that the workspace opened in Codex desktop. This is the
    /// expected path while no machine-readable connection status exists.
    case userConfirmedWorkspaceOpened
    /// A supported, machine-readable status from the desktop application. Record its source
    /// so a future change in that interface is visible in diagnostics.
    case machineReadableStatus(source: String)
}
