import Foundation

/// Closed compatibility explanations, never text from a manifest or a process.
public enum CompatibilityBlockReason: Codable, Hashable, Sendable {
    case knownIncompatibleCombination
    case incompatibleComponent(CompatibilityField)

    public var userMessage: String {
        switch self {
        case .knownIncompatibleCombination:
            "This combination is known not to support a Codex desktop connection. Use the offered repair path while the environment is idle before connecting again."
        case .incompatibleComponent(let field):
            "The current \(field.title) is incompatible with this development setup. Use the offered repair path while the environment is idle before connecting again."
        }
    }
}

/// A combination known not to work. Every specified field must match the observed value
/// for the rule to apply; an unknown observed field never triggers it. A rule can single
/// out one CLI executable, one capability set, or one desktop bundle, so a broken
/// installation can be blocked without blocking a working one of the same version.
///
/// Immutable throughout: a rule blocks handoff, and the evaluator hands its `reason` and
/// `recoveryActions` straight to the GUI, so both invariants below have to survive from
/// construction to the moment the rule fires.
public struct CompatibilityIncompatibility: Codable, Hashable, Sendable {
    /// What stays available when a rule fires: a targeted repair of the tools whose
    /// combination is blocked, the console, work export, and stopping the environment (the
    /// persistent stop control is never an error button).
    ///
    /// The repair leads: a blocked combination that offered only console access and export
    /// would refuse every new handoff with no way out of it, and MVP-PLAN.md §5 asks for a
    /// route back rather than a dead end.
    public static let defaultRecoveryActions: [RecoveryAction] = [.repair(.tools), .openConsole, .exportWork, .cancel]

    /// A rule's own actions with everything §5 requires of a blocked state added back.
    ///
    /// MVP-PLAN.md §5 asks for an idle-time repair path for known-incompatible versions and
    /// says to "preserve console access, shutdown, and work export in **every** state", so
    /// this is not something a rule gets to choose. Expecting each rule to name the right
    /// actions itself was enough while the manifest was written here, but the rules are data:
    /// a `[.cancel]` in a decoded manifest, or an updated one that simply lists fewer, would
    /// otherwise hand the GUI a blocked handoff and a single dead end.
    ///
    /// The rule's own actions keep their order and lead, because they were written for this
    /// combination — except that a repair goes in front of them when the rule names none,
    /// which is where `defaultRecoveryActions` puts it and why. A repair the rule does name
    /// counts as the repair whatever it repairs: some incompatibilities are not fixed by the
    /// tools flow, and offering a second button that cannot help is worse than none.
    static func completed(_ actions: [RecoveryAction]) -> [RecoveryAction] {
        let namesARepair = actions.contains { if case .repair = $0 { true } else { false } }
        var completed: [RecoveryAction] = namesARepair ? [] : [.repair(.tools)]
        completed += actions
        for required in defaultRecoveryActions {
            // A repair is present either way by now, its own or the default one; asking
            // whether *this* repair is present would add the tools flow beside it.
            if case .repair = required { continue }
            guard !completed.contains(required) else { continue }
            completed.append(required)
        }
        return completed
    }

    public let hostMacOS: VersionRange?
    public let hostMacOSBuild: String?
    public let codexDesktopVersion: String?
    public let codexDesktopBuild: String?
    public let codexDesktopPath: String?
    public let runtimeProtocolVersion: Int?
    public let runtimeProvider: VMProvider?
    public let runtimeVersion: String?
    public let guestMacOSBuild: String?
    public let xcodeBuild: String?
    public let codexCLIVersion: String?
    public let codexCLIPath: String?
    /// An exact installation-count selector; nil leaves this dimension unconstrained.
    public let codexCLIInstallations: Int?
    /// Matches when the observed capability list, normalized, equals this list.
    public let codexCLICapabilities: [String]?
    public let githubCLIVersion: String?
    public let provisioningScriptVersion: String?
    /// Why handoff is blocked. Closed cases provide fixed Guesthouse-owned messages.
    public let reason: CompatibilityBlockReason
    /// What the GUI offers when this rule fires. Never empty.
    public let recoveryActions: [RecoveryAction]

    public init(
        hostMacOS: VersionRange? = nil,
        hostMacOSBuild: String? = nil,
        codexDesktopVersion: String? = nil,
        codexDesktopBuild: String? = nil,
        codexDesktopPath: String? = nil,
        runtimeProtocolVersion: Int? = nil,
        runtimeProvider: VMProvider? = nil,
        runtimeVersion: String? = nil,
        guestMacOSBuild: String? = nil,
        xcodeBuild: String? = nil,
        codexCLIVersion: String? = nil,
        codexCLIPath: String? = nil,
        codexCLIInstallations: Int? = nil,
        codexCLICapabilities: [String]? = nil,
        githubCLIVersion: String? = nil,
        provisioningScriptVersion: String? = nil,
        reason: CompatibilityBlockReason,
        recoveryActions: [RecoveryAction] = CompatibilityIncompatibility.defaultRecoveryActions
    ) {
        self.hostMacOS = hostMacOS
        self.hostMacOSBuild = hostMacOSBuild
        self.codexDesktopVersion = codexDesktopVersion
        self.codexDesktopBuild = codexDesktopBuild
        self.codexDesktopPath = codexDesktopPath
        self.runtimeProtocolVersion = runtimeProtocolVersion
        self.runtimeProvider = runtimeProvider
        self.runtimeVersion = runtimeVersion
        self.guestMacOSBuild = guestMacOSBuild
        self.xcodeBuild = xcodeBuild
        self.codexCLIVersion = codexCLIVersion
        self.codexCLIPath = codexCLIPath
        self.codexCLIInstallations = codexCLIInstallations
        self.codexCLICapabilities = codexCLICapabilities.map(CompatibilityTuple.normalize)
        self.githubCLIVersion = githubCLIVersion
        self.provisioningScriptVersion = provisioningScriptVersion
        self.reason = reason
        self.recoveryActions = Self.completed(recoveryActions)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let reason = try c.decode(CompatibilityBlockReason.self, forKey: .reason)
        let capabilities = try c.decodeIfPresent([String].self, forKey: .codexCLICapabilities)
        guard capabilities.map({ $0.count <= CompatibilityTuple.maximumCapabilities }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .codexCLICapabilities, in: c, debugDescription: "too many capabilities")
        }
        self.init(
            hostMacOS: try c.decodeIfPresent(VersionRange.self, forKey: .hostMacOS),
            hostMacOSBuild: try c.decodeIfPresent(String.self, forKey: .hostMacOSBuild),
            codexDesktopVersion: try c.decodeIfPresent(String.self, forKey: .codexDesktopVersion),
            codexDesktopBuild: try c.decodeIfPresent(String.self, forKey: .codexDesktopBuild),
            codexDesktopPath: try c.decodeIfPresent(String.self, forKey: .codexDesktopPath),
            runtimeProtocolVersion: try c.decodeIfPresent(Int.self, forKey: .runtimeProtocolVersion),
            runtimeProvider: try c.decodeIfPresent(VMProvider.self, forKey: .runtimeProvider),
            runtimeVersion: try c.decodeIfPresent(String.self, forKey: .runtimeVersion),
            guestMacOSBuild: try c.decodeIfPresent(String.self, forKey: .guestMacOSBuild),
            xcodeBuild: try c.decodeIfPresent(String.self, forKey: .xcodeBuild),
            codexCLIVersion: try c.decodeIfPresent(String.self, forKey: .codexCLIVersion),
            codexCLIPath: try c.decodeIfPresent(String.self, forKey: .codexCLIPath),
            codexCLIInstallations: try c.decodeIfPresent(Int.self, forKey: .codexCLIInstallations),
            codexCLICapabilities: capabilities,
            githubCLIVersion: try c.decodeIfPresent(String.self, forKey: .githubCLIVersion),
            provisioningScriptVersion: try c.decodeIfPresent(String.self, forKey: .provisioningScriptVersion),
            reason: reason,
            recoveryActions: try c.decodeIfPresent([RecoveryAction].self, forKey: .recoveryActions) ?? Self.defaultRecoveryActions
        )
    }

    public func applies(to observed: ObservedTuple) -> Bool {
        func check<T: Equatable>(_ rule: T?, _ value: T?) -> Bool {
            guard let rule else { return true }
            guard let value else { return false }
            return rule == value
        }
        let hostInRange: Bool
        if let hostMacOS {
            guard let version = observed.hostMacOSVersion else { return false }
            hostInRange = hostMacOS.contains(version)
        } else {
            hostInRange = true
        }
        return hostInRange
            && check(hostMacOSBuild, observed.hostMacOSBuild)
            && check(codexDesktopVersion, observed.codexDesktopVersion)
            && check(codexDesktopBuild, observed.codexDesktopBuild)
            && check(codexDesktopPath, observed.codexDesktopPath)
            && check(runtimeProtocolVersion, observed.runtimeProtocolVersion)
            && check(runtimeProvider, observed.runtimeProvider)
            && check(runtimeVersion, observed.runtimeVersion)
            && check(guestMacOSBuild, observed.guestMacOSBuild)
            && check(xcodeBuild, observed.xcodeBuild)
            && check(codexCLIVersion, observed.codexCLIVersion)
            && check(codexCLIPath, observed.codexCLIPath)
            && check(codexCLIInstallations, observed.codexCLIInstallations)
            // The rule's list is normalized at construction; an observation assembled field
            // by field need not be, and order must never decide whether a rule fires.
            && check(codexCLICapabilities, observed.codexCLICapabilities.map(CompatibilityTuple.normalize))
            && check(githubCLIVersion, observed.githubCLIVersion)
            && check(provisioningScriptVersion, observed.provisioningScriptVersion)
    }
}
