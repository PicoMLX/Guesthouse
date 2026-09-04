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
        /// The failure the user is reporting when the app could not reach its runtime. On a
        /// fresh launch there are no environments and no operation logs, so without this the
        /// bundle would describe nothing at all.
        public var launchFailure: LaunchFailure?
        public var excludedCategories: [String]

        /// A launch failure as the export records it: what the user was told, in their words.
        public struct LaunchFailure: Codable, Hashable, Sendable {
            public var message: String
            public var recovery: String?
            public var recoveryActions: [String]
        }
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
        launchError: GuesthouseError? = nil,
        exportedAt: Date = Date()
    ) -> DiagnosticsExport {
        let lines = scrubbedStream(logs)
        let manifest = DiagnosticsExport.Manifest(
            exportedAt: exportedAt,
            appVersion: GuesthouseError.sanitize(appVersion),
            appBuild: GuesthouseError.sanitize(appBuild),
            runtime: scrubbed(runtime),
            compatibility: scrubbed(compatibility),
            environmentIDs: environments.map(\.id),
            logLineCount: lines.count,
            launchFailure: launchError.map { error in
                DiagnosticsExport.Manifest.LaunchFailure(
                    message: scrub(error.userMessage),
                    recovery: error.recoverySuggestion.map { scrub($0) },
                    recoveryActions: error.recoveryActions.map { String(describing: $0) }
                )
            },
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
        // IPv6 first, so an IPv4-mapped address (`::ffff:192.0.2.1`) is taken whole. Trailing
        // punctuation is trimmed before validation: a sentence's period is not part of the
        // address, and leaving it in would let the address through.
        // The candidate must stand on its own: without these boundaries `foo::bar` offers
        // `::ba`, which is a valid compressed address, and the identifier would be eaten.
        let withoutIPv6 = text.replacing(#/(^|[^0-9A-Za-z_])([0-9A-Fa-f:.]{2,45})(?![0-9A-Za-z_])/#) { match in
            let before = String(match.output.1)
            let token = String(match.output.2)
            guard token.contains(":") else { return before + token }
            // Only trailing punctuation is trimmed: a leading colon is part of a compressed
            // address (`::1`), while a sentence's period at the end is not.
            let trimmed = Self.trimmingTrailingPunctuation(token)
            guard !trimmed.isEmpty, isIPv6(trimmed) else { return before + token }
            return before + "[redacted:address]" + token.dropFirst(trimmed.count)
        }
        // Only a real IPv4 literal is an address: a four-part version such as `1.2.3.456` is
        // exactly the information diagnostics exist to keep.
        return withoutIPv6.replacing(#/\b(?:\d{1,3}\.){3}\d{1,3}\b/#) { match in
            let token = String(withoutIPv6[match.range])
            return isIPv4(token) ? "[redacted:address]" : token
        }
    }

    static func trimmingTrailingPunctuation(_ token: String) -> String {
        var trimmed = Substring(token)
        while let last = trimmed.last, ".,;)]}".contains(last) { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    static func isIPv4(_ token: String) -> Bool {
        var buffer = in_addr()
        return token.withCString { inet_pton(AF_INET, $0, &buffer) } == 1
    }

    static func isIPv6(_ token: String) -> Bool {
        var buffer = in6_addr()
        return token.withCString { inet_pton(AF_INET6, $0, &buffer) } == 1
    }

    /// E-mail addresses and the identifier after "signed in as", "logged in as", "user",
    /// or "account" become `[redacted:account]`.
    static func scrubIdentities(_ text: String) -> String {
        text.replacing(#/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/#, with: "[redacted:account]")
            .replacing(#/(?i)\b((?:signed|logged) in (?:to \S+ )?as|account:?|user(?:name)?:?)\s+(?!\[redacted)(?![=:])(\S+)/#) { match in
                "\(match.output.1) [redacted:account]"
            }
            // Structured output writes the same fact without a space: `user=octocat`,
            // `"account":"alice"`. The label keeps its quoting so the line still parses.
            .replacing(#/(?i)(["']?\b(?:account|owner|user(?:name)?)["']?\s*[:=]\s*)(["']?)(?!\[redacted)[A-Za-z0-9._%+@-]+(["']?)/#) { match in
                "\(match.output.1)\(match.output.2)[redacted:account]\(match.output.3)"
            }
            // A home directory names its owner: `/Users/alice/…` is an account name in a path.
            .replacing(#/(/Users/)(?!\[redacted)[^/\s]+/#) { match in
                "\(match.output.1)[redacted:account]"
            }
    }

    /// Scrubs a stream of lines. A credential is often printed over two lines (`password:`
    /// on one, the value on the next), so a line that ends in a credential label redacts the
    /// value that follows it.
    public static func scrubbedStream(_ logs: [RedactedLine]) -> [String] {
        var result: [String] = []
        var expectingValue = false
        for line in logs {
            let scrubbed = scrub(line.text)
            let trimmed = scrubbed.trimmingCharacters(in: .whitespaces)
            if expectingValue, !trimmed.isEmpty {
                result.append(scrubbed.replacingOccurrences(of: trimmed, with: Redactor.marker("credential")))
                expectingValue = trimmed.isEmpty
                continue
            }
            expectingValue = trimmed.wholeMatch(of: #/(?i)(password|passphrase|secret|token|api[ _-]?key|credential)s?\s*[:=]/#) != nil
            result.append(scrubbed)
        }
        return result
    }

    /// The runtime's own report can name a path: a storage failure quotes where it tried to
    /// write, which is often under the user's home directory. Its problem is replaced with a
    /// scrubbed description so the manifest keeps the failure without the account name.
    static func scrubbed(_ runtime: RuntimeVersionInfo?) -> RuntimeVersionInfo? {
        guard var info = runtime, var tart = info.tart, let problem = tart.problem else { return runtime }
        tart.problem = .runtimeStateUnavailable(reason: SanitizedText(scrub(problem.userMessage), limit: 300))
        info.tart = tart
        return info
    }

    /// The observations that may appear in the manifest: paths carry the account name of
    /// whoever owns them, so they are scrubbed like any other exported value.
    static func scrubbed(_ tuple: ObservedTuple) -> ObservedTuple {
        var copy = tuple
        copy.codexDesktopPath = tuple.codexDesktopPath.map { scrub($0) }
        copy.codexCLIPath = tuple.codexCLIPath.map { scrub($0) }
        copy.codexCLICapabilities = tuple.codexCLICapabilities.map { $0.map { scrub($0) } }
        return copy
    }
}
