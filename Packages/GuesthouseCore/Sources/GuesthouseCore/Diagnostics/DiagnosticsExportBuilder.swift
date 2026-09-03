import Foundation

/// A diagnostics bundle the user can share: a manifest of what is known, the redacted log,
/// and a list of what was deliberately left out (MVP-PLAN.md §2 "Essential screens", §3
/// "Local storage": private keys, tokens, device codes, authorization headers, and raw
/// authentication logs never leave the Mac; environments are named by UUID, never by address).
public struct DiagnosticsExport: Hashable, Sendable {
    public struct Manifest: Codable, Hashable, Sendable {
        public var exportedAt: Date
        public var appVersion: String
        public var appBuild: String
        public var runtime: RuntimeVersionInfo?
        /// The compatibility fields that are known; unknown ones stay `nil`.
        public var compatibility: ObservedTuple
        public var environmentIDs: [EnvironmentID]
        public var logLineCount: Int
        public var excludedCategories: [String]
    }

    public static let manifestFileName = "manifest.json"
    public static let logFileName = "log.txt"
    public static let excludedFileName = "excluded.txt"

    public let manifest: Manifest
    public let logText: String
    public let excludedText: String

    /// The files of the bundle, in a fixed order.
    public var files: [(name: String, contents: Data)] {
        [
            (Self.manifestFileName, DiagnosticsExportBuilder.encode(manifest)),
            (Self.logFileName, Data(logText.utf8)),
            (Self.excludedFileName, Data(excludedText.utf8)),
        ]
    }
}

public enum DiagnosticsExportBuilder {
    /// What an export never contains, listed in `excluded.txt` so the reader knows why a
    /// value is missing rather than guessing.
    public static let excludedCategories = [
        "Private keys and certificates",
        "Tokens, API keys, and passwords",
        "Device and one-time codes",
        "Authorization headers and raw authentication output",
        "Network addresses (development Macs are identified by UUID instead)",
        "User account names and e-mail addresses",
    ]

    /// Builds the export from already-redacted lines and known facts. Addresses are scrubbed
    /// from the log as well, since a redacted line may still name one.
    public static func build(
        appVersion: String,
        appBuild: String,
        runtime: RuntimeVersionInfo?,
        compatibility: ObservedTuple,
        environments: [DevelopmentEnvironment],
        logs: [RedactedLine],
        exportedAt: Date = Date()
    ) -> DiagnosticsExport {
        let lines = logs.map { scrubAddresses($0.text) }
        let manifest = DiagnosticsExport.Manifest(
            exportedAt: exportedAt,
            appVersion: GuesthouseError.sanitize(appVersion),
            appBuild: GuesthouseError.sanitize(appBuild),
            runtime: runtime,
            compatibility: compatibility,
            environmentIDs: environments.map(\.id),
            logLineCount: lines.count,
            excludedCategories: excludedCategories
        )
        let excluded = "This export deliberately omits:\n" + excludedCategories.map { "- \($0)" }.joined(separator: "\n") + "\n"
        return DiagnosticsExport(manifest: manifest, logText: lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"), excludedText: excluded)
    }

    /// Writes the bundle as a folder. Existing files of the same names are replaced.
    public static func write(_ export: DiagnosticsExport, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for file in export.files {
            try file.contents.write(to: directory.appending(path: file.name), options: .atomic)
        }
    }

    static func encode(_ manifest: DiagnosticsExport.Manifest) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(manifest)) ?? Data()
    }

    /// IPv4 and IPv6 literals become `[redacted:address]`.
    static func scrubAddresses(_ text: String) -> String {
        text.replacing(#/\b(?:\d{1,3}\.){3}\d{1,3}\b/#, with: "[redacted:address]")
            .replacing(#/\b(?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{1,4}\b/#, with: "[redacted:address]")
    }
}
