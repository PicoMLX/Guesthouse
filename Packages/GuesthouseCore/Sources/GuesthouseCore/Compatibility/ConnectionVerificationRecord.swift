import Foundation

/// A private record of confirmation that Codex desktop opened a guest workspace with an exact combination
/// of versions (MVP-PLAN.md §5: "Record connection verification for that exact tuple only
/// after the real desktop flow succeeds").
///
/// A record can only be created from `DesktopConnectionEvidence`. Version queries such as
/// `codex --version` are not evidence and have no way to name themselves one: the source of a
/// machine-readable status has to be an interface on `supportedStatusInterfaces`.
public struct ConnectionVerificationRecord: Hashable, Sendable {
    /// Record-level schema version, so the state store can migrate history when the tuple
    /// changes shape instead of misreading old evidence under a new schema.
    public let schemaVersion: SchemaVersion

    /// The record layout this build writes, and the only one `init(from:)` accepts.
    ///
    /// Its own number rather than `SchemaVersion.current`: that epoch moves whenever any
    /// persisted record in the package changes shape, so measuring this record against it
    /// would make every unchanged connection record unreadable after a release that only
    /// altered an environment or VM-slot format. This number moves when this record's shape
    /// moves, together with the migration that reads the previous one. `SchemaVersion` only
    /// refuses a number below 1; the schema-2 literal is valid. Legacy schema 1 lacks explicit
    /// provider identity, so it must not be accepted as Lume connection evidence.
    public static let currentSchema = SchemaVersion(2)!
    public let tuple: CompatibilityTuple
    public let verifiedAt: Date
    public let evidence: DesktopConnectionEvidence

    /// - Throws: `CompatibilityRecordError.implausibleObservation` when a guest-reported string
    ///   violates the bounded grammar of its version/build/capability/path field.
    ///   No general-purpose secret recognition is used; these are private identity records.
    ///   `.implausibleEvidenceSource` when the evidence names a status interface this build
    ///   does not read.
    public init(tuple: CompatibilityTuple, verifiedAt: Date, evidence: DesktopConnectionEvidence) throws(CompatibilityRecordError) {
        try Self.validate(tuple)
        try Self.validate(evidence)
        schemaVersion = Self.currentSchema
        self.tuple = tuple
        self.verifiedAt = verifiedAt
        self.evidence = evidence
    }

    public static let maximumObservationLength = 256
    /// Limits are UTF-8 bytes. A full path is bounded by the file system, not by the shape of a version string: a
    /// deeply nested but entirely valid bundle or executable must still be recordable.
    public static let maximumPathLength = 1024

    /// Every string must fit its identity field's grammar, not be a command transcript.
    public static func validate(_ tuple: CompatibilityTuple) throws(CompatibilityRecordError) {
        // Bounded in count as well as in length: the per-value checks below say nothing about
        // how many values a guest may report, and the whole list is what gets persisted.
        guard tuple.codexCLICapabilities.count <= CompatibilityTuple.maximumCapabilities else {
            throw .implausibleObservation(.codexCLICapabilities)
        }
        guard tuple.runtimeProtocolVersion > 0 else { throw .implausibleObservation(.runtimeProtocolVersion) }
        guard tuple.codexCLIInstallations == 1 else { throw .implausibleObservation(.codexCLIInstallations) }
        let versions: [(CompatibilityField, String)] = [
            (.codexDesktopVersion, tuple.codexDesktopVersion), (.codexDesktopBuild, tuple.codexDesktopBuild),
            (.runtimeVersion, tuple.runtimeVersion), (.codexCLIVersion, tuple.codexCLIVersion),
            (.githubCLIVersion, tuple.githubCLIVersion)
        ]
        for (field, value) in versions where !isVersionIdentifier(value) {
            throw .implausibleObservation(field)
        }
        // Phase-0 records accept a script version or commit, which need not start with a digit.
        guard isIdentifier(tuple.provisioningScriptVersion, punctuation: [43, 45, 46]) else {
            throw .implausibleObservation(.provisioningScriptVersion)
        }
        for (field, value) in [
            (CompatibilityField.hostMacOSBuild, tuple.hostMacOSBuild),
            (.guestMacOSBuild, tuple.guestMacOSBuild), (.xcodeBuild, tuple.xcodeBuild)
        ] where !isBuildIdentifier(value) { throw .implausibleObservation(field) }
        for value in tuple.codexCLICapabilities where !isIdentifier(value, punctuation: [45, 46, 58, 95]) {
            throw .implausibleObservation(.codexCLICapabilities)
        }
        // The two paths are identity, not description, so they are held to more than
        // plausibility (MVP-PLAN.md §5).
        let paths: [(CompatibilityField, String)] = [
            (.codexDesktopPath, tuple.codexDesktopPath),
            (.codexCLIPath, tuple.codexCLIPath),
        ]
        for (field, value) in paths where !isResolvedPath(value) {
            throw .implausibleObservation(field)
        }
    }

    /// Checks the lexical shape of an absolute path. The probe must resolve symlinks;
    /// this value model does not consult the filesystem or prove the executable exists.
    ///
    /// A login shell whose `PATH` carries a relative entry answers `which -a codex` with
    /// `codex` or `../bin/codex`, and a compromised probe can answer with either on purpose.
    /// Recording one as identity would let a different executable of the same name pass as the
    /// verified one from another working directory, which is exactly the substitution
    /// MVP-PLAN.md §5 tracks the resolved path to catch.
    static func isResolvedPath(_ value: String) -> Bool {
        guard isBoundedText(value, limit: maximumPathLength), value.hasPrefix("/"),
              !value.hasSuffix("/") else { return false }
        // `.` and `..` resolve against a working directory the record does not carry, so a path
        // holding either is not yet the one the probe was standing on.
        return !value.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    /// The machine-readable connection-status interfaces this build reads.
    ///
    /// MVP-PLAN.md §5 records verification for a tuple only after the real desktop flow
    /// succeeds and never equates `codex --version` with a successful desktop connection. A
    /// caller that names its own source can do exactly that — labeling any successful probe
    /// `.machineReadableStatus(source: "codex --version")` — so a name that merely looks like an
    /// interface is not one; it has to be on this list. This build has no registered reader,
    /// so the list is empty. The caller must obtain explicit GUI confirmation before using
    /// userConfirmedWorkspaceOpened. This model cannot itself prove that a user action occurred.
    public static let supportedStatusInterfaces: Set<String> = []

    /// The evidence names where a machine-readable status came from. That name goes into
    /// persisted history and decides whether a later handoff is allowed without asking, so it
    /// has to be an interface this build supports rather than a plausible-looking string.
    public static func validate(_ evidence: DesktopConnectionEvidence) throws(CompatibilityRecordError) {
        guard case .machineReadableStatus(let source) = evidence else { return }
        guard supportedStatusInterfaces.contains(source) else { throw .implausibleEvidenceSource }
    }

    private static func isBoundedText(_ value: String, limit: Int) -> Bool {
        guard !value.isEmpty, value.utf8.prefix(limit + 1).count <= limit,
              value.trimmingCharacters(in: .whitespacesAndNewlines) == value else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned: false
            default: true
            }
        }
    }

    private static func isIdentifier(_ value: String, punctuation: Set<UInt8>) -> Bool {
        guard isBoundedText(value, limit: maximumObservationLength) else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || punctuation.contains($0)
        }
    }

    private static func isVersionIdentifier(_ value: String) -> Bool {
        guard let first = value.utf8.first, (48...57).contains(first) else { return false }
        return isIdentifier(value, punctuation: [43, 45, 46])
    }

    private static func isBuildIdentifier(_ value: String) -> Bool {
        guard let first = value.utf8.first, (48...57).contains(first) else { return false }
        return isIdentifier(value, punctuation: [])
    }
}

public enum CompatibilityRecordError: Error, Hashable, Sendable, LocalizedError {
    /// A guest-reported value did not look like a version, build, or path.
    case implausibleObservation(CompatibilityField)
    /// The evidence named a status interface this build does not read.
    case implausibleEvidenceSource
    /// The stored history was written in a record layout this build does not read.
    case unsupportedSchema(found: SchemaVersion, supported: SchemaVersion)
    /// The stored history is not connection history this build can parse.
    case malformedHistory

    public var userMessage: String {
        switch self {
        case .implausibleObservation(let field):
            "The development Mac reported an unsupported \(field.title) value, so this connection was not recorded. Check the tools on the development Mac before trying again."
        case .implausibleEvidenceSource:
            "The Codex desktop app reported a connection status from an interface Guesthouse does not read, so this connection was not recorded. Confirm in Guesthouse that the workspace opened, or check the tools on the development Mac before trying again."
        case .unsupportedSchema(let found, let supported):
            "Guesthouse's record of successful Codex connections is in format \(found.rawValue), and this version reads format \(supported.rawValue). The earlier connections cannot be counted, so the next handoff asks you to confirm a connection once more."
        case .malformedHistory:
            "Guesthouse's record of successful Codex connections could not be read. The earlier connections cannot be counted, so the next handoff asks you to confirm a connection once more."
        }
    }

    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .implausibleObservation, .implausibleEvidenceSource:
            [.inspectState, .repair(.tools), .cancel]
        // Do not automatically retry or replace unreadable history. The consumer must
        // inspect it and arrange a new explicit connection confirmation separately.
        case .unsupportedSchema, .malformedHistory:
            [.inspectState, .cancel]
        }
    }

    public var errorDescription: String? { userMessage }
}

extension ConnectionVerificationRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, tuple, verifiedAt, evidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(SchemaVersion.self, forKey: .schemaVersion)
        // Exactly this record's layout until an explicit migration exists: an older or newer
        // record would otherwise be interpreted under a shape it was never written in.
        guard version == Self.currentSchema else {
            throw CompatibilityRecordError.unsupportedSchema(found: version, supported: Self.currentSchema)
        }
        schemaVersion = version
        let tuple = try container.decode(CompatibilityTuple.self, forKey: .tuple)
        let evidence = try container.decode(DesktopConnectionEvidence.self, forKey: .evidence)
        // History on disk is as untrusted as the probe that first produced it: an implausible
        // value must not become verification evidence by having survived one round trip.
        try Self.validate(tuple)
        try Self.validate(evidence)
        self.tuple = tuple
        self.evidence = evidence
        verifiedAt = try container.decode(Date.self, forKey: .verifiedAt)
    }

    /// Reads persisted connection history. Every failure becomes something the user can act
    /// on rather than a decoder's internal complaint: history that cannot be read decides
    /// whether the next handoff is allowed, so the state store has to be able to say so.
    /// The storage reader must bound input size before calling this in-memory decoder.
    public static func decodeHistory(from data: Data, using decoder: JSONDecoder = JSONDecoder()) throws(CompatibilityRecordError) -> [ConnectionVerificationRecord] {
        do {
            return try decoder.decode([ConnectionVerificationRecord].self, from: data)
        } catch let error as CompatibilityRecordError {
            throw error
        } catch {
            throw .malformedHistory
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(tuple, forKey: .tuple)
        try container.encode(verifiedAt, forKey: .verifiedAt)
        try container.encode(evidence, forKey: .evidence)
    }
}

/// How a real desktop connection was confirmed.
public enum DesktopConnectionEvidence: Codable, Hashable, Sendable {
    /// The user confirmed in the GUI that the workspace opened in Codex desktop. This is the
    /// expected path while this build has no registered machine-readable status reader.
    case userConfirmedWorkspaceOpened
    /// A supported, machine-readable status from the desktop application. Its source is one of
    /// `ConnectionVerificationRecord.supportedStatusInterfaces` and is recorded so a future
    /// change in that interface remains part of private connection history, not diagnostics.
    case machineReadableStatus(source: String)
}

extension CompatibilityField {
    public var title: String {
        switch self {
        case .hostMacOSVersion: "host macOS version"
        case .hostMacOSBuild: "host macOS build"
        case .codexDesktopVersion: "Codex desktop version"
        case .codexDesktopBuild: "Codex desktop build"
        case .codexDesktopPath: "Codex desktop location"
        case .runtimeProtocolVersion: "runtime protocol version"
        case .runtimeProvider: "virtual machine provider"
        case .runtimeVersion: "virtual machine runtime version"
        case .guestMacOSBuild: "guest macOS build"
        case .xcodeBuild: "Xcode build"
        case .codexCLIVersion: "Codex CLI version"
        case .codexCLIPath: "Codex CLI location"
        case .codexCLIInstallations: "Codex CLI installation count"
        case .codexCLICapabilities: "Codex CLI capabilities"
        case .githubCLIVersion: "GitHub CLI version"
        case .provisioningScriptVersion: "provisioning script version"
        }
    }
}
