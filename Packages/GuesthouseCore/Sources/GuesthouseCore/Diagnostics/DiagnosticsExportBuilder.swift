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

/// Export only reconstructed DiagnosticEvent records (MVP-PLAN.md §§2–3, ADR 0003).
/// Private status, tool/version observations and arbitrary metadata are not export inputs.
public enum DiagnosticsExportBuilder {
    public static let historyNotice = "Partial diagnostic history. The runtime connection may omit intermediate events under load; discardedCount counts local evictions across the complete session, including environments outside this selection."
    public static let exclusions = [
        "Raw process output, command arguments, environment variables and underlying error descriptions.",
        "Authentication transcripts, credentials, tokens, private keys, account names and device codes.",
        "Filesystem paths, network addresses, repository contents, screenshots and accessibility data.",
        "Private status, tool/version observations, capability strings and provisioning script identifiers."
    ]

    /// Nil selects the complete session; an empty selection includes global events only.
    /// Environment selection never admits private EnvironmentStatus metadata.
    public static func build(log: DiagnosticLog,
                             environmentIDs: [EnvironmentID]? = nil) throws(DiagnosticsExportError) -> DiagnosticsExport {
        if let environmentIDs {
            guard environmentIDs.count <= 2 else { throw .tooManyEnvironments }
            guard Set(environmentIDs).count == environmentIDs.count else { throw .duplicateEnvironment }
        }
        let log = environmentIDs.map { log.selecting(environments: Set($0)) } ?? log
        let manifest = Manifest(
            selectedEnvironmentIDs: environmentIDs,
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

    private struct Manifest: Encodable {
        let schemaVersion = 1
        let historyNotice = DiagnosticsExportBuilder.historyNotice
        let exclusions = DiagnosticsExportBuilder.exclusions
        let selectedEnvironmentIDs: [EnvironmentID]?
        let eventEnvironmentIDs: [EnvironmentID]
        let recordCount: Int
        let discardedCount: UInt64
    }
}
