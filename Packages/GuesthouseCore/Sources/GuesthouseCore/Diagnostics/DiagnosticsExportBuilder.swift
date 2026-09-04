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
        public var launchFailure: ReportedFailure?
        /// What the exported environment's last operation failed with. An operation that fails
        /// before it produces output leaves nothing in the log, so the failure the user opened
        /// Diagnostics about would otherwise be absent from the bundle.
        public var operationFailure: ReportedFailure?
        public var excludedCategories: [String]

        /// A failure as the export records it: what the user was told, in their words.
        public struct ReportedFailure: Codable, Hashable, Sendable {
            public var message: String
            public var recovery: String?
            public var recoveryActions: [String]

            /// Scrubbed on the way in, because a message quotes what failed: a path under the
            /// user's home directory, or the address a guest did not answer on.
            public init(message: String, recovery: String?, recoveryActions: [String]) {
                self.message = DiagnosticsExportBuilder.scrub(message)
                self.recovery = recovery.map { DiagnosticsExportBuilder.scrub($0) }
                self.recoveryActions = recoveryActions
            }

            public init(_ error: GuesthouseError) {
                self.init(
                    message: error.userMessage,
                    recovery: error.recoverySuggestion,
                    recoveryActions: error.recoveryActions.map { String(describing: $0) }
                )
            }
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
        launchFailure: DiagnosticsExport.Manifest.ReportedFailure? = nil,
        operationFailure: DiagnosticsExport.Manifest.ReportedFailure? = nil,
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
            launchFailure: launchFailure,
            operationFailure: operationFailure,
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

    /// IPv4, IPv6, and MAC literals become `[redacted:address]`. IPv6 candidates are validated
    /// with `inet_pton`, so compressed (`::1`, `2001:db8::1`) and IPv4-mapped forms are caught
    /// and clock times are not.
    static func scrubAddresses(_ text: String) -> String {
        // A MAC address is six hex pairs, which `inet_pton` rejects as an IPv6 candidate and
        // the IPv4 pass never sees; it identifies the machine just as well as an IP does, so
        // it is taken first, before the IPv6 pass can consume part of it. The boundaries are
        // identifier-aware like the IPv4 and IPv6 ones: guest output writes the address inside
        // a generated name (`nic_52:54:00:12:34:56_state`), and an underscore boundary let that
        // form through both this pass and the IPv6 one. A colon is still not a boundary, so a
        // longer colon run cannot be cut into six pairs.
        let withoutMAC = text.replacing(#/(^|[^0-9A-Za-z:])([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})(?![0-9A-Za-z:])/#) { match in
            String(match.output.1) + "[redacted:address]"
        }
        // IPv6 next, so an IPv4-mapped address (`::ffff:192.0.2.1`) is taken whole. Trailing
        // punctuation is trimmed before validation: a sentence's period is not part of the
        // address, and leaving it in would let the address through.
        // The candidate must not start or end inside a word: without a boundary `foo::bar`
        // offers `::ba`, which is a valid compressed address, and the identifier would be
        // eaten. An underscore is a boundary all the same, because machine-generated output
        // writes an address inside an identifier (`peer_2001:db8::1_status`) the way it does
        // with IPv4 — and `foo_::bar` still offers only `::ba` in front of a letter.
        let withoutIPv6 = withoutMAC.replacing(#/(^|[^0-9A-Za-z])([0-9A-Fa-f:.]{2,45})(?![0-9A-Za-z])/#) { match in
            let before = String(match.output.1)
            let token = String(match.output.2)
            guard token.contains(":") else { return before + token }
            guard let address = Self.longestAddressPrefix(of: token) else { return before + token }
            return before + "[redacted:address]" + token.dropFirst(address.count)
        }
        // Only a real IPv4 literal is an address: a four-part version such as `1.2.3.456` is
        // exactly the information diagnostics exist to keep. The boundaries are digit-aware
        // rather than word-aware, because machine-generated output writes an address inside an
        // identifier (`peer_192.168.64.7`, `192.168.64.7_status`) where `\b` does not fall.
        return withoutIPv6.replacing(#/(^|[^0-9.])((?:\d{1,3}\.){3}\d{1,3})(?![0-9])(?!\.[0-9])/#) { match in
            let before = String(match.output.1)
            let token = String(match.output.2)
            return isIPv4(token) ? before + "[redacted:address]" : before + token
        }
    }

    /// The longest leading part of `token` that is a valid IPv6 address, or nil. A delimiter
    /// that follows an address is not part of it — `2001:db8::1: connection failed` ends the
    /// address at the label's colon — while `2001:db8::` is itself a whole address, so the
    /// candidate is tried at full length first and shortened one character at a time.
    static func longestAddressPrefix(of token: String) -> String? {
        var candidate = Substring(token)
        while !candidate.isEmpty {
            if isIPv6(String(candidate)) { return String(candidate) }
            guard let last = candidate.last, ".,;)]}:".contains(last) else { return nil }
            candidate = candidate.dropLast()
        }
        return nil
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
        // A local login is `user@host` with no dotted suffix (`alice@guesthouse`), and the
        // host half of `alice@192.168.64.7` is already `[redacted:address]` by the time this
        // runs. Both name the account `excluded.txt` promises the export omits. SSH syntax
        // brackets an IPv6 host, and the address pass keeps those brackets around its marker,
        // so `alice@[2001:db8::1]` reaches this as a doubled-bracket form; without it the
        // account in front of an IPv6 host would stay in the export.
        text.replacing(#/[A-Za-z0-9._%+-]+@(?:\[\[redacted:address\]\]|\[redacted:address\]|[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)/#, with: "[redacted:account]")
            // A display name has spaces in it: `Signed in as Alice Smith` left `Smith` behind
            // when the value was a single token. A quoted value is taken whole; an unquoted one
            // continues through further capitalized words, which is what the rest of a name
            // looks like, and stops at anything else so `user: octocat (admin)` keeps its
            // qualifier and a sentence after the name is not swallowed. The label group carries
            // its own case-insensitivity, because the continuation must stay case-sensitive.
            .replacing(#/\b((?i:(?:signed|logged) in (?:to \S+ )?as|account:?|user(?:name)?:?))\s+(?!\[redacted)(?![=:])("[^"]*"|'[^']*'|\S+(?: [A-Z][^\s]*){0,3})/#) { match in
                "\(match.output.1) [redacted:account]"
            }
            // Structured output writes the same fact without a space: `user=octocat`,
            // `"account":"alice"`. A quoted value runs to its closing quote, so a name with a
            // space in it (`"user":"Alice Smith"`) goes whole rather than leaving its surname.
            // The label keeps its quoting so the line still parses.
            .replacing(#/(?i)(["']?\b(?:account|owner|user(?:name)?)["']?\s*[:=]\s*)(?:(")(?!\[redacted)[^"]*"|(')(?!\[redacted)[^']*'|(?!\[redacted)[A-Za-z0-9._%+@-]+)/#) { match in
                let quote = match.output.2.map(String.init) ?? match.output.3.map(String.init) ?? ""
                return "\(match.output.1)\(quote)[redacted:account]\(quote)"
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
    /// write, which is often under the user's home directory. Only the free text is replaced.
    static func scrubbed(_ runtime: RuntimeVersionInfo?) -> RuntimeVersionInfo? {
        guard var info = runtime, var tart = info.tart, let problem = tart.problem else { return runtime }
        tart.problem = scrubbed(problem)
        info.tart = tart
        return info
    }

    /// Replaces an error's free text and keeps its case. The manifest's category, message,
    /// and recovery actions are all derived from the case, so rewriting a missing runtime or
    /// a failed verification as a saved-state failure would make the export say the wrong
    /// thing about what went wrong and what to do about it.
    static func scrubbed(_ error: GuesthouseError) -> GuesthouseError {
        switch error {
        case .runtimeStateUnavailable(let reason):
            .runtimeStateUnavailable(reason: scrubbed(reason))
        case .runtimeStorageUnavailable(let reason, let problem):
            .runtimeStorageUnavailable(reason: scrubbed(reason), problem: problem)
        case .runtimeIncompatible(let found, let required):
            .runtimeIncompatible(found: found.map { scrubbed($0) }, required: required)
        case .insufficientDisk(let required, let available, let volumePath):
            .insufficientDisk(requiredBytes: required, availableBytes: available, volumePath: scrubbed(volumePath))
        case .downloadVerificationFailed(let artifact, let check):
            .downloadVerificationFailed(artifact: scrubbed(artifact), check: check)
        case .toolMismatch(let tool, let found, let expected):
            .toolMismatch(tool: scrubbed(tool), found: found.map { scrubbed($0) }, expected: expected)
        default:
            // Every remaining case carries identifiers, sizes, and enumerated reasons, never
            // text that could name an address or an account.
            error
        }
    }

    static func scrubbed(_ text: SanitizedText) -> SanitizedText {
        SanitizedText(scrub(text.value), limit: SanitizedText.maximumLimit)
    }

    /// The observations that may appear in the manifest. Wire sanitization removes credentials
    /// but not identities, and a guest is free to answer any of these with an address or an
    /// account name, so every string the tuple carries is scrubbed rather than only the paths.
    static func scrubbed(_ tuple: ObservedTuple) -> ObservedTuple {
        var copy = tuple
        copy.hostMacOSBuild = tuple.hostMacOSBuild.map { scrub($0) }
        copy.codexDesktopVersion = tuple.codexDesktopVersion.map { scrub($0) }
        copy.codexDesktopBuild = tuple.codexDesktopBuild.map { scrub($0) }
        copy.codexDesktopPath = tuple.codexDesktopPath.map { scrub($0) }
        copy.tartVersion = tuple.tartVersion.map { scrub($0) }
        copy.guestMacOSBuild = tuple.guestMacOSBuild.map { scrub($0) }
        copy.xcodeBuild = tuple.xcodeBuild.map { scrub($0) }
        copy.codexCLIVersion = tuple.codexCLIVersion.map { scrub($0) }
        copy.codexCLIPath = tuple.codexCLIPath.map { scrub($0) }
        copy.codexCLICapabilities = tuple.codexCLICapabilities.map { $0.map { scrub($0) } }
        copy.githubCLIVersion = tuple.githubCLIVersion.map { scrub($0) }
        copy.provisioningScriptVersion = tuple.provisioningScriptVersion.map { scrub($0) }
        return copy
    }
}
