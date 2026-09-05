import Foundation

/// The three states MVP-PLAN.md §5 defines for a Codex handoff.
public enum CompatibilityState: Codable, Hashable, Sendable {
    /// This exact combination has a recorded real desktop connection.
    case verified(recordedAt: Date)
    /// Handoff is allowed only after the user performs and confirms a real desktop connection.
    case needsValidation(NeedsValidationReason)
    /// Handoff is blocked. Console access, shutdown, and work export stay available; the
    /// rule names what else the user can do.
    case incompatible(reason: String, recoveryActions: [RecoveryAction])

    public enum NeedsValidationReason: Codable, Hashable, Sendable {
        /// At least one component could not be identified. Never guess; ask for validation.
        case unknownFields([CompatibilityField])
        /// The guest login shell can see more than one Codex executable.
        case competingInstallations(count: Int)
        /// The guest login shell can see no Codex executable at all: a missing prerequisite,
        /// not something a real desktop connection could validate.
        case codexCLIMissing
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
            return .incompatible(reason: rule.reason, recoveryActions: rule.recoveryActions)
        }

        // No probe can see fewer than zero executables, so a count that says so is corrupt
        // rather than a report of the single unambiguous installation a handoff needs.
        if let installations = observed.codexCLIInstallations, installations < 0 {
            return .needsValidation(.unknownFields([.codexCLIInstallations]))
        }

        // No protocol version is below zero either, and a corrupt one must not become part of
        // an exact tuple that a later, equally corrupt observation could match as verified.
        if let protocolVersion = observed.runtimeProtocolVersion, protocolVersion < 0 {
            return .needsValidation(.unknownFields([.runtimeProtocolVersion]))
        }

        // A probe that found no executable is decisive on its own, whatever else is unknown.
        if observed.codexCLIInstallations == 0 {
            return .needsValidation(.codexCLIMissing)
        }

        // So is a probe that found several: refusing to name one of them is why the version and
        // path are unknown, and reporting that as missing fields hides the actual problem.
        if let installations = observed.codexCLIInstallations, installations > 1 {
            return .needsValidation(.competingInstallations(count: installations))
        }

        let unknown = observed.unknownFields
        guard unknown.isEmpty, let exact = observed.exact else {
            return .needsValidation(.unknownFields(unknown))
        }

        if let record = history.filter({ $0.tuple == exact }).max(by: { $0.verifiedAt < $1.verifiedAt }) {
            return .verified(recordedAt: record.verifiedAt)
        }

        // Official evidence for this exact combination counts regardless of what else the user
        // connected before; only then does unrelated history mean drift. Host ranges may
        // overlap, so every matching entry is asked, not only the first: one entry per tested
        // host build is the natural way to record two verifications of one combination. When
        // several cover this exact host, report its last successful connection (§5).
        let matching = manifest.tested.filter { $0.matches(exact) }
        if let verification = matching.compactMap(\.verification)
            .filter({ $0.covers(exact) })
            .max(by: { $0.verifiedAt < $1.verifiedAt }) {
            return .verified(recordedAt: verification.verifiedAt)
        }

        if let latest = history.max(by: { $0.verifiedAt < $1.verifiedAt }) {
            return .needsValidation(.changedSinceLastVerified(exact.differences(from: latest.tuple)))
        }

        guard !matching.isEmpty else {
            return .needsValidation(.untestedCombination)
        }
        guard matching.contains(where: \.isVerified) else {
            return .needsValidation(.neverConnected)
        }
        return .needsValidation(.verifiedOnDifferentHost)
    }
}
