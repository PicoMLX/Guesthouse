import Foundation

/// An immutable in-memory folder. The sandboxed GUI chooses the destination; Core does no I/O.
public struct DiagnosticsExport: Sendable {
    public let files: [String: Data]
    init(files: [String: Data]) { self.files = files }
}

public enum DiagnosticsExportError: Error, Sendable, Equatable {
    case tooManyEnvironments, duplicateEnvironment, encodingFailed
    public var userMessage: String {
        switch self {
        case .tooManyEnvironments, .duplicateEnvironment: "The diagnostic environment selection is invalid."
        case .encodingFailed: "Guesthouse could not prepare the diagnostic export."
        }
    }
    public var recoveryActions: [RecoveryAction] { [.inspectState, .cancel] }
}

/// Explicit export projection, not serialization of private status/identity records (#30,
/// MVP-PLAN.md §§2–3, ADR 0003). Input accepts typed diagnostics only. Metadata is whitelisted;
/// unknown/unsupported version syntax is omitted, never echoed as an arbitrary string.
public enum DiagnosticsExportBuilder {
    public static let historyNotice = "Partial diagnostic history. The runtime connection may omit intermediate events under load; discardedCount counts only local history evictions."
    public static let exclusions = [
        "Raw process output, command arguments, environment variables and underlying error descriptions.",
        "Authentication transcripts, credentials, tokens, private keys, account names and device codes.",
        "Filesystem paths, network addresses, repository contents, screenshots and accessibility data.",
        "Unrecognized version/build values, arbitrary capability strings and provisioning script identifiers."
    ]

    /// Versions use one to three numeric components; ambiguous four-component/address-like
    /// values and unsupported suffixes are omitted. Builds use Apple's bounded syntax. These are
    /// observations, not claims of compatibility, signature verification or provider acceptance.
    public static func build(log: DiagnosticLog, appVersion: String? = nil, appBuild: String? = nil,
                             runtime: RuntimeVersionInfo? = nil,
                             environments: [EnvironmentStatus] = []) throws(DiagnosticsExportError) -> DiagnosticsExport {
        guard environments.count <= 2 else { throw .tooManyEnvironments }
        guard Set(environments.map(\.environmentID)).count == environments.count else { throw .duplicateEnvironment }
        let manifest = Manifest(appVersion: version(appVersion), appBuild: buildNumber(appBuild),
            serviceVersion: version(runtime?.serviceVersion), serviceBuild: buildNumber(runtime?.serviceBuild),
            protocolVersion: runtime.flatMap { $0.protocolVersion.rawValue > 0 ? $0.protocolVersion.rawValue : nil },
            reportedRuntimeProvider: runtime?.runtime?.provider, reportedRuntimeVersion: version(runtime?.runtime?.version),
            environments: environments.map { EnvironmentMetadata($0) },
            eventEnvironmentIDs: Set(log.records.compactMap { $0.event.environmentID }).sorted { $0.uuid.uuidString < $1.uuid.uuidString },
            recordCount: log.records.count, discardedCount: log.discardedCount)
        do {
            // Validate all encodable values before rendering dates as text; errors stay typed.
            let events = try log.jsonData()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            return DiagnosticsExport(files: [
                "manifest.json": try encoder.encode(manifest),
                "diagnostics.json": events,
                "log.txt": Data((historyNotice + "\n\n" + log.text).utf8),
                "excluded.txt": Data((exclusions.joined(separator: "\n") + "\n").utf8)
            ])
        } catch { throw .encodingFailed }
    }

    private static func version(_ value: String?) -> [Int]? {
        guard let value, let parsed = SemanticVersion(value),
              value.split(separator: ".", omittingEmptySubsequences: false).count <= 3 else { return nil }
        return parsed.components
    }
    private static func buildNumber(_ value: String?) -> UInt64? {
        guard let value, !value.isEmpty, value.utf8.count <= 20,
              value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UInt64(value)
    }
    private static func appleBuild(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 11,
              value.range(of: "^[0-9]{1,3}[A-Z][0-9]{1,6}[a-z]?$", options: .regularExpression) != nil else { return nil }
        return value
    }
    private struct Manifest: Encodable {
        let schemaVersion = 1
        let historyNotice = DiagnosticsExportBuilder.historyNotice
        let exclusions = DiagnosticsExportBuilder.exclusions
        let appVersion: [Int]?, appBuild: UInt64?
        let serviceVersion: [Int]?, serviceBuild: UInt64?
        let protocolVersion: Int?
        let reportedRuntimeProvider: VMProvider?, reportedRuntimeVersion: [Int]?
        let environments: [EnvironmentMetadata]
        let eventEnvironmentIDs: [EnvironmentID]
        let recordCount: Int
        let discardedCount: UInt64
    }
    private struct EnvironmentMetadata: Encodable {
        let environmentID: EnvironmentID
        let hostMacOSVersion: [Int]?, hostMacOSBuild: String?
        let guestMacOSBuild: String?, xcodeBuild: String?
        let codexDesktopVersion: [Int]?, codexDesktopBuild: UInt64?
        let runtimeProvider: VMProvider?, runtimeVersion: [Int]?
        let codexCLIVersion: [Int]?, githubCLIVersion: [Int]?
        init(_ status: EnvironmentStatus) {
            let observed = status.observed
            environmentID = status.environmentID
            hostMacOSVersion = version(observed.hostMacOSVersion?.description)
            hostMacOSBuild = appleBuild(observed.hostMacOSBuild)
            guestMacOSBuild = appleBuild(observed.guestMacOSBuild)
            xcodeBuild = appleBuild(observed.xcodeBuild)
            codexDesktopVersion = version(observed.codexDesktopVersion)
            codexDesktopBuild = buildNumber(observed.codexDesktopBuild)
            runtimeProvider = observed.runtimeProvider; runtimeVersion = version(observed.runtimeVersion)
            codexCLIVersion = version(observed.codexCLIVersion); githubCLIVersion = version(observed.githubCLIVersion)
        }
    }
}
