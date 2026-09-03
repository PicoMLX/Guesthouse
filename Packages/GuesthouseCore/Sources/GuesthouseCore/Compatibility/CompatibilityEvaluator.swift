import Foundation

/// The three states MVP-PLAN.md §5 defines for a Codex handoff.
public enum CompatibilityState: Codable, Hashable, Sendable {
    /// This exact combination has a recorded real desktop connection.
    case verified(recordedAt: Date)
    /// Handoff is allowed only after the user performs and confirms a real desktop connection.
    case needsValidation(NeedsValidationReason)
    /// Handoff is blocked. Console access, shutdown, and work export stay available.
    case incompatible(reason: String)

    public enum NeedsValidationReason: Codable, Hashable, Sendable {
        /// At least one component could not be identified. Never guess; ask for validation.
        case unknownFields([CompatibilityField])
        /// The guest login shell can see more than one Codex executable.
        case competingInstallations(count: Int)
        /// A known combination, but no real connection has ever been recorded for it.
        case neverConnected
        /// The manifest records a connection for this combination, but on a different host
        /// version or build than the one observed.
        case verifiedOnDifferentHost
        /// Something changed since the last recorded connection.
        case changedSinceLastVerified([CompatibilityField])
        /// This combination is not in the manifest at all.
        case untestedCombination
    }

    public var allowsHandoff: Bool {
        if case .verified = self { return true }
        return false
    }
}

/// Pure decision logic. No I/O; the caller supplies what it observed and what it remembers.
public enum CompatibilityEvaluator: Sendable {
    /// - Parameters:
    ///   - observed: what was read from the host, desktop app, and guest right now.
    ///   - manifest: the shipped list of tested combinations.
    ///   - history: previously recorded real connections, in any order.
    public static func evaluate(
        observed: ObservedTuple,
        manifest: CompatibilityManifest,
        history: [ConnectionVerificationRecord]
    ) -> CompatibilityState {
        if let rule = manifest.incompatibilities.first(where: { $0.applies(to: observed) }) {
            return .incompatible(reason: rule.reason)
        }

        let unknown = observed.unknownFields
        guard unknown.isEmpty, let exact = observed.exact else {
            return .needsValidation(.unknownFields(unknown))
        }

        if exact.codexCLIInstallations != 1 {
            return .needsValidation(.competingInstallations(count: exact.codexCLIInstallations))
        }

        if let record = history.filter({ $0.tuple == exact }).max(by: { $0.verifiedAt < $1.verifiedAt }) {
            return .verified(recordedAt: record.verifiedAt)
        }

        // Official evidence for this exact combination counts regardless of what else the user
        // connected before; only then does unrelated history mean drift.
        let tested = manifest.tested.first(where: { $0.matches(exact) })
        if let verification = tested?.verification, verification.covers(exact) {
            return .verified(recordedAt: verification.verifiedAt)
        }

        if let latest = history.max(by: { $0.verifiedAt < $1.verifiedAt }) {
            return .needsValidation(.changedSinceLastVerified(exact.differences(from: latest.tuple)))
        }

        guard let tested else {
            return .needsValidation(.untestedCombination)
        }
        guard tested.verification != nil else {
            return .needsValidation(.neverConnected)
        }
        return .needsValidation(.verifiedOnDifferentHost)
    }
}
