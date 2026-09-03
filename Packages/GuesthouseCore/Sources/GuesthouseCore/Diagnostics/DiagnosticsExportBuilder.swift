import Darwin
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

    /// Builds the export from already-redacted lines and known facts. Addresses and account
    /// identifiers are scrubbed from the log as well, since a redacted line may still name one.
    public static func build(
        appVersion: String,
        appBuild: String,
        runtime: RuntimeVersionInfo?,
        compatibility: ObservedTuple,
        environments: [DevelopmentEnvironment],
        logs: [RedactedLine],
        exportedAt: Date = Date()
    ) -> DiagnosticsExport {
        let lines = logs.map { scrub($0.text) }
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

    static func encode(_ manifest: DiagnosticsExport.Manifest) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(manifest)) ?? Data()
    }

    /// Everything the export removes from a line that redaction left in: network addresses
    /// and account identifiers. Applied to anything shown or copied as diagnostics, not only
    /// to the written bundle.
    public static func scrub(_ text: String) -> String {
        scrubIdentities(scrubAddresses(text))
    }

    /// IPv4 and IPv6 literals become `[redacted:address]`. IPv6 candidates are validated with
    /// `inet_pton`, so compressed (`::1`, `2001:db8::1`) and IPv4-mapped forms are caught and
    /// clock times are not.
    static func scrubAddresses(_ text: String) -> String {
        // IPv6 first, so an IPv4-mapped address (`::ffff:192.0.2.1`) is taken whole.
        let withoutIPv6 = text.replacing(#/[0-9A-Fa-f:.]{2,45}/#) { match in
            let token = String(text[match.range])
            guard token.contains(":"), isIPv6(token) else { return token }
            return "[redacted:address]"
        }
        return withoutIPv6.replacing(#/\b(?:\d{1,3}\.){3}\d{1,3}\b/#, with: "[redacted:address]")
    }

    static func isIPv6(_ token: String) -> Bool {
        var buffer = in6_addr()
        return token.withCString { inet_pton(AF_INET6, $0, &buffer) } == 1
    }

    /// E-mail addresses and the identifier after "signed in as", "logged in as", "user",
    /// or "account" become `[redacted:account]`.
    static func scrubIdentities(_ text: String) -> String {
        text.replacing(#/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/#, with: "[redacted:account]")
            .replacing(#/(?i)\b((?:signed|logged) in (?:to \S+ )?as|account:?|user(?:name)?:?)\s+(?!\[redacted)(\S+)/#) { match in
                "\(match.output.1) [redacted:account]"
            }
    }
}
