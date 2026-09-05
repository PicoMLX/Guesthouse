import Foundation

/// A wire-safe explanation of why Guesthouse's private runtime storage cannot be used.
///
/// The runtime service owns the filesystem-specific error. This value carries only the
/// bounded, redacted context the GUI needs to give a truthful and non-destructive recovery.
public struct RuntimeStorageProblem: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case protectionDrift
        case insecureDirectory
        case unwritable
    }

    public let kind: Kind
    public let path: SanitizedText
    public let detail: SanitizedText

    public init(kind: Kind, path: String, detail: String) {
        self.kind = kind
        self.path = SanitizedText(path, limit: 200)
        self.detail = SanitizedText(detail, limit: 120)
    }

    private enum CodingKeys: String, CodingKey { case kind, path, detail }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(Kind.self, forKey: .kind),
            path: try container.decode(String.self, forKey: .path),
            detail: try container.decode(String.self, forKey: .detail)
        )
    }
}

/// Every failure Guesthouse shows to the user, with a category, a message, and recovery actions.
///
/// Associated values are structured on purpose: identifiers, sizes, versions, component names,
/// and paths. Never a token, password, device code, or raw command output; anything that can
/// originate outside the app is a `SanitizedText`, redacted and bounded at construction, so
/// the encoded form of an error carries no raw value either (MVP-PLAN.md §3, "Local storage").
public enum GuesthouseError: Error, Codable, Hashable, Sendable {
    case unsupportedHost(UnsupportedHostReason)
    case insufficientDisk(requiredBytes: UInt64, availableBytes: UInt64, volumePath: SanitizedText)
    case downloadVerificationFailed(artifact: SanitizedText, check: VerificationCheck)
    case runtimeStorageUnavailable(RuntimeStorageProblem)
    case runtimeMissing
    case runtimeIncompatible(found: SanitizedText?, required: SanitizedText)
    case runtimeProbeFailed
    case guestNotReachable(EnvironmentID)
    case hostKeyChanged(EnvironmentID)
    case credentialsLocked(CredentialStore)
    case loginExpired(Provider)
    case toolMismatch(tool: SanitizedText, found: SanitizedText?, expected: SanitizedText)
    case xcodeComponentsIncomplete(missing: MissingComponents)
    case vmSlotUnavailable(maximum: Int)
    case operationOutcomeUnknown(OperationID)
    case unauthorizedCaller
    case protocolMismatch(client: Int, service: Int)
    case invalidRequest(InvalidRequestReason)
    case canceled

    public enum UnsupportedHostReason: Codable, Hashable, Sendable {
        case notAppleSilicon
        /// The Mac's processor is not the one the configured policy requires. `notAppleSilicon`
        /// is the default-policy spelling of this; this case carries both sides. Both are
        /// `SanitizedText`, so what a decoded payload put in either is bounded and redacted
        /// where the value is built rather than where it is shown, and re-encoding the error
        /// cannot carry the original through.
        case wrongArchitecture(found: SanitizedText, required: SanitizedText)
        case macOSTooOld(found: SanitizedText, minimum: SanitizedText)
        /// The processor architecture could not be determined; the check can be run again.
        case architectureUnknown
        case insufficientMemory(foundBytes: UInt64, minimumBytes: UInt64)
    }

    public enum VerificationCheck: String, Codable, Hashable, Sendable {
        case digest, signature, size
    }

    public enum CredentialStore: String, Codable, Hashable, Sendable {
        case hostKeychain, guestKeychain
    }

    public enum Provider: String, Codable, Hashable, Sendable {
        case github, codex
    }

    public enum InvalidRequestReason: String, Codable, Hashable, Sendable {
        case oversized, pathEscapesAllowedRoot, invalidVMName, unsupportedOperation, malformed
        /// The caller has too many requests in flight on one session.
        case tooManyInFlight
    }

    /// Coarse grouping for filtering diagnostics and choosing presentation.
    public enum Category: String, Codable, Hashable, Sendable, CaseIterable {
        case host, storage, runtime, guest, credentials, tools, workflow, ipc, user
    }

    public var category: Category {
        switch self {
        case .unsupportedHost: .host
        case .insufficientDisk, .runtimeStorageUnavailable: .storage
        case .downloadVerificationFailed, .runtimeMissing, .runtimeIncompatible, .runtimeProbeFailed: .runtime
        case .guestNotReachable, .hostKeyChanged: .guest
        case .credentialsLocked, .loginExpired: .credentials
        case .toolMismatch, .xcodeComponentsIncomplete: .tools
        case .vmSlotUnavailable, .operationOutcomeUnknown: .workflow
        case .unauthorizedCaller, .protocolMismatch, .invalidRequest: .ipc
        case .canceled: .user
        }
    }

    /// Plain-language explanation shown to the user. Says what happened and, where useful,
    /// what it means; the recovery actions say what to do.
    public var userMessage: String {
        switch self {
        case .unsupportedHost(.wrongArchitecture(let found, let required)):
            "This Mac has \(found.value); Guesthouse needs \(required.value). Development Macs cannot run here."
        case .unsupportedHost(.notAppleSilicon):
            "This Mac has an Intel processor. Guesthouse needs an Apple silicon Mac to run a macOS virtual machine."
        case .unsupportedHost(.architectureUnknown):
            "Guesthouse could not determine this Mac's processor type. Check this Mac again; if it keeps failing, export diagnostics."
        case .unsupportedHost(.macOSTooOld(let found, let minimum)):
            "This Mac runs macOS \(found.value). Guesthouse needs macOS \(minimum.value) or later."
        case .unsupportedHost(.insufficientMemory(let found, let minimum)):
            "This Mac has \(Self.formatMemory(found)) of memory. Guesthouse needs at least \(Self.formatMemory(minimum)) to run a development Mac alongside your other apps."
        case .insufficientDisk(let required, let available, let volume):
            Self.insufficientDiskMessage(required: required, available: available, volume: volume.value)
        case .downloadVerificationFailed(let artifact, let check):
            "The downloaded \(artifact.value) failed its \(check.rawValue) check and was not installed. The download may be incomplete or tampered with."
        case .runtimeStorageUnavailable(let problem):
            switch problem.kind {
            case .protectionDrift:
                "Guesthouse stopped because its storage folder \(problem.path.value) is no longer private (\(problem.detail.value)). Leave the folder and its contents in place—they may include unpublished work. Quit and reopen Guesthouse so it can restore the required protection."
            case .insecureDirectory:
                "Guesthouse cannot safely use the item at its storage path \(problem.path.value) (\(problem.detail.value)). Preserve the item and any linked destination exactly as they are; they may contain unpublished work. Cancel and inspect the path before changing anything."
            case .unwritable:
                "Guesthouse cannot write to its storage folder \(problem.path.value) (\(problem.detail.value)). Leave the folder and its contents in place because they may contain unpublished work. Free disk space or restore write access, then quit and reopen Guesthouse."
            }
        case .runtimeMissing:
            "The virtual machine runtime is not installed."
        case .runtimeIncompatible(let found, let required):
            "The installed virtual machine runtime (\(found?.value ?? "unknown version")) is not the tested version \(required.value)."
        case .runtimeProbeFailed:
            "Guesthouse could not inspect the installed virtual machine runtime. It may be damaged or unresponsive."
        case .guestNotReachable(let id):
            "The development Mac \(id.tartVMName) is not answering over the network."
        case .hostKeyChanged(let id):
            "The development Mac \(id.tartVMName) presented a different SSH identity than the one recorded when it was paired. Guesthouse will not connect until this is repaired."
        case .credentialsLocked(.guestKeychain):
            "The development Mac's keychain is locked, so GitHub and Codex cannot use their saved sign-in."
        case .credentialsLocked(.hostKeychain):
            "This Mac's keychain is locked, so Guesthouse cannot read the SSH passphrase it stored."
        case .loginExpired(let provider):
            "Your \(Self.name(of: provider)) sign-in on the development Mac has expired."
        case .toolMismatch(let tool, let found, let expected):
            "The development Mac has \(tool.value) \(found?.value ?? "missing") but the tested version is \(expected.value)."
        case .xcodeComponentsIncomplete(let missing):
            "Xcode is installed on the development Mac but is missing required components: \(Self.list(missing))."
        case .vmSlotUnavailable(let maximum):
            "Guesthouse manages at most \(maximum) development Macs, including stopped and preserved ones. Export any unpublished work from one you no longer need, then delete it to make room."
        case .operationOutcomeUnknown:
            "Guesthouse lost contact with its runtime before this operation reported a result. The operation may or may not have completed."
        case .unauthorizedCaller:
            "A process that is not Guesthouse tried to use the Guesthouse runtime service and was refused."
        case .protocolMismatch(let client, let service):
            "The Guesthouse app (protocol \(client)) and its runtime service (protocol \(service)) are from different versions. Reinstall Guesthouse to repair this."
        case .invalidRequest(let reason):
            "The runtime service rejected a request from the app (\(Self.describe(reason))). This is a bug in Guesthouse, not something you did."
        case .canceled:
            "The operation was canceled."
        }
    }

    /// Actions the GUI may offer, in preference order. Never empty.
    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .unsupportedHost(.macOSTooOld): [.openSettings, .cancel]
        case .unsupportedHost(.architectureUnknown): [.retry, .cancel]
        case .unsupportedHost: [.cancel]
        case .insufficientDisk: [.freeDiskSpace, .retry, .openSettings, .cancel]
        case .downloadVerificationFailed: [.retry, .cancel]
        // Phase 0 discovery runs once per service launch; do not promise an unwired retry.
        // A write failure can mean full disk, denied access, or a read-only volume. Until the
        // GUI has a storage-repair flow, do not offer a button that addresses only one cause.
        case .runtimeStorageUnavailable: [.cancel]
        case .runtimeMissing: [.repair(.runtime), .cancel]
        case .runtimeIncompatible: [.repair(.runtime), .exportWork, .cancel]
        case .runtimeProbeFailed: [.repair(.runtime), .cancel]
        case .guestNotReachable: [.inspectState, .retry, .openConsole, .cancel]
        case .hostKeyChanged: [.repair(.sshPairing), .openConsole, .exportWork, .cancel]
        case .credentialsLocked(.guestKeychain): [.openConsole, .repair(.credentials), .cancel]
        case .credentialsLocked(.hostKeychain): [.retry, .openSettings, .cancel]
        case .loginExpired: [.signInAgain, .cancel]
        case .toolMismatch: [.repair(.tools), .openConsole, .exportWork, .cancel]
        case .xcodeComponentsIncomplete: [.repair(.xcodeComponents), .openConsole, .exportWork, .cancel]
        case .vmSlotUnavailable: [.exportWork, .deleteEnvironment, .cancel]
        case .operationOutcomeUnknown: [.inspectState, .cancel]
        case .unauthorizedCaller: [.cancel]
        case .protocolMismatch: [.reinstallApp, .cancel]
        case .invalidRequest: [.cancel]
        // A cancellation may have interrupted a mutation midway; the state is inspected
        // before the same operation is offered again (MVP-PLAN.md §9).
        case .canceled: [.inspectState, .cancel]
        }
    }

    /// Whether running the same operation again is a reasonable first response.
    public var isRetryable: Bool {
        recoveryActions.contains(.retry)
    }

    /// A description safe for logs and diagnostics bundles. Identical to `description`;
    /// the type carries nothing that needs redacting.
    public var redactedDescription: String {
        "\(caseName)[\(category.rawValue)]: \(userMessage)"
    }

    /// The bare case name, for tests and log filtering. An explicit switch rather than
    /// reflection so that it can never recurse into `description` and so that adding a case
    /// is a compile error until this is updated.
    public var caseName: String {
        switch self {
        case .unsupportedHost: "unsupportedHost"
        case .insufficientDisk: "insufficientDisk"
        case .downloadVerificationFailed: "downloadVerificationFailed"
        case .runtimeStorageUnavailable: "runtimeStorageUnavailable"
        case .runtimeMissing: "runtimeMissing"
        case .runtimeIncompatible: "runtimeIncompatible"
        case .runtimeProbeFailed: "runtimeProbeFailed"
        case .guestNotReachable: "guestNotReachable"
        case .hostKeyChanged: "hostKeyChanged"
        case .credentialsLocked: "credentialsLocked"
        case .loginExpired: "loginExpired"
        case .toolMismatch: "toolMismatch"
        case .xcodeComponentsIncomplete: "xcodeComponentsIncomplete"
        case .vmSlotUnavailable: "vmSlotUnavailable"
        case .operationOutcomeUnknown: "operationOutcomeUnknown"
        case .unauthorizedCaller: "unauthorizedCaller"
        case .protocolMismatch: "protocolMismatch"
        case .invalidRequest: "invalidRequest"
        case .canceled: "canceled"
        }
    }

    private static func name(of provider: Provider) -> String {
        switch provider {
        case .github: "GitHub"
        case .codex: "Codex"
        }
    }

    private static func describe(_ reason: InvalidRequestReason) -> String {
        switch reason {
        case .oversized: "the request was too large"
        case .pathEscapesAllowedRoot: "a path pointed outside the allowed location"
        case .invalidVMName: "the virtual machine name was not valid"
        case .unsupportedOperation: "the operation is not supported by this service version"
        case .malformed: "the request could not be decoded"
        case .tooManyInFlight: "too many requests were in flight at once"
        }
    }

    /// Values that can originate outside the app (CLI output, guest responses, file names)
    /// are normalized, redacted, and bounded before interpolation, in that order, so a message
    /// and its `redactedDescription` can never carry a credential, an injected line, a
    /// bidirectional override, or an unbounded value.
    ///
    /// Order matters: normalization first, so a token split by a control character cannot be
    /// reassembled after redaction; the bound is in Unicode scalars, so a run of combining
    /// marks cannot hide behind a single `Character`.
    /// Input is bounded before any work: only the first `limit + lookahead` scalars are
    /// normalized and redacted, so an oversized value costs a bounded amount of memory and CPU.
    /// The lookahead is longer than any credential the redactor recognizes, so a secret that
    /// begins inside the visible prefix is inside the window unless scalars that normalization
    /// drops padded it out; the repairs below cover the value left standing at the cut.
    static let sanitizeLookahead = 512

    public static func sanitize(_ value: String, limit: Int = 80) -> String {
        sanitizeReporting(value, limit: limit).value
    }

    /// The sanitized text, and whether the redactor actually replaced something. Callers that
    /// need to tell "a secret was removed" from "the text merely happens to contain the
    /// marker" use this rather than searching the result for marker text.
    public static func sanitizeReporting(_ value: String, limit: Int = 80) -> (value: String, redacted: Bool) {
        // This is public API, so the bound is clamped rather than trusted: an extreme limit
        // would otherwise overflow the window arithmetic and a negative one would hand
        // `prefix` an invalid length, trapping instead of returning sanitized text.
        let limit = min(max(limit, 1), SanitizedText.maximumLimit)
        // Only the window plus one scalar is ever looked at, so the cost is independent of the
        // input's size.
        let window = value.unicodeScalars.prefix(limit + Self.sanitizeLookahead + 1)
        let truncated = window.count > limit + Self.sanitizeLookahead
        let bounded = String(String.UnicodeScalarView(window.prefix(limit + Self.sanitizeLookahead)))
        // Complete escape sequences go first, so styling inside a token cannot leave a
        // fragment behind once the bare control scalars are dropped. A sequence that can only
        // have borrowed its terminator from the value goes further and takes its whole run
        // with it, because stripping it would silently repair a credential into something the
        // patterns below no longer recognize. Combining marks go too: a mark inside a token
        // would otherwise split it out of the redactor's reach.
        let spliced = Redactor.redactEscapeSplicedRuns(bounded)
        let stripped = Redactor.stripTerminalEscapes(spliced)
        var normalized = String(String.UnicodeScalarView(stripped.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned,
                 .nonspacingMark, .spacingMark, .enclosingMark:
                false
            case .spaceSeparator:
                // A no-break or ideographic space splits a credential exactly as a control
                // character does. The ordinary space is a real word boundary and stays.
                scalar == " "
            default:
                true
            }
        }))
        var truncationRedacted = false
        if truncated {
            // Normalization drops scalars, so a window full of raw input can normalize to far
            // less: a run of combining marks between a device code's first and last character
            // pushes that last character out of the window and leaves `AB12-CD3`, which no
            // pattern recognizes. Whenever the window was cut and normalization shortened it,
            // the run at the cut is a fragment of something unknown and does not survive. A
            // value that was only long, not padded, keeps the whole window and the two repairs
            // below.
            if normalized.unicodeScalars.count < limit + Self.sanitizeLookahead {
                normalized = normalized.replacing(#/\S+$/#, with: Redactor.marker("truncated"))
            }
            // A URL authority still open at the cut may be userinfo whose terminating `@` fell
            // outside the window: treat the whole remainder as a credential. The delimiter is
            // recognized in both the spellings the redactor's own userinfo rule accepts, since a
            // URL that reached a log through JSON keeps that encoding's escaped slashes, and is
            // put back exactly as it came in.
            let opened = normalized
            normalized = normalized.replacing(#/(:(?:\\?\/){2})[^\s\/]*$/#) { match in "\(match.1)\(Redactor.marker("userinfo"))" }
            // A JWT whose payload is longer than the window loses the second `.` the redactor
            // matches on, so a token that began inside the visible prefix would be emitted in
            // the clear. A JOSE header followed by a segment running to the cut is one. The
            // header is looked for the way `redactedJWT` looks for it, after each `_` and `-`
            // as well as at the start: those are Base64URL characters, so an untrusted name
            // concatenated in front of the token (`artifact_<jwt>`) is inside the segment this
            // rule captures, and asking `isJOSEHeader` about the whole of it always says no.
            normalized = normalized.replacing(#/\b([A-Za-z0-9_-]{4,})\.[A-Za-z0-9_-]*$/#) { match in
                guard let start = Redactor.joseHeaderStart(match.1) else { return String(match.0) }
                return match.1[..<start] + Redactor.marker("jwt")
            }
            truncationRedacted = normalized != opened
        }
        let redacted = Redactor().redact(fieldValue: normalized)
        // The truncation-time replacement counts as redaction, and so does the escape-spliced
        // run dropped before normalization: both remove credential text, and a caller must not
        // treat what is left as merely bounded and attach an identity digest of the original.
        let wasRedacted = spliced != bounded || truncationRedacted || redacted != normalized
        let scalars = redacted.unicodeScalars
        guard scalars.count > limit else { return (redacted, wasRedacted) }
        return (String(String.UnicodeScalarView(scalars.prefix(limit))) + "…", wasRedacted)
    }

    static func list(_ components: MissingComponents) -> String {
        let shown = components.listed.map(\.value).joined(separator: ", ")
        return components.omitted > 0 ? "\(shown), and \(components.omitted) more" : shown
    }

    /// Names the shortfall explicitly, and falls back to exact byte counts when rounding would
    /// make the two amounts read the same.
    static func insufficientDiskMessage(required: UInt64, available: UInt64, volume: String) -> String {
        let shortfall = required > available ? required - available : 0
        var requiredText = formatBytes(required)
        var availableText = formatBytes(available)
        if requiredText == availableText {
            requiredText = "\(required.formatted()) bytes"
            availableText = "\(available.formatted()) bytes"
        }
        let shortfallText = shortfall < 1_000_000 ? "\(shortfall.formatted()) bytes" : formatBytes(shortfall)
        return "This step needs \(requiredText) free on \(sanitize(volume)), but only \(availableText) is available, \(shortfallText) short."
    }

    /// `ByteCountFormatter` takes an `Int64`, so an amount above that range would be shown as
    /// half of itself. An amount that large is named exactly instead, so a requirement no
    /// disk could satisfy is not reported as a plausible one.
    private static func formatBytes(_ bytes: UInt64) -> String {
        guard let representable = Int64(exactly: bytes) else { return "\(bytes.formatted()) bytes" }
        return ByteCountFormatter.string(fromByteCount: representable, countStyle: .file)
    }

    private static func formatMemory(_ bytes: UInt64) -> String {
        guard let representable = Int64(exactly: bytes) else { return "\(bytes.formatted()) bytes" }
        return ByteCountFormatter.string(fromByteCount: representable, countStyle: .memory)
    }
}

extension GuesthouseError: CustomStringConvertible {
    public var description: String { redactedDescription }
}

extension GuesthouseError: LocalizedError {
    public var errorDescription: String? { userMessage }

    public var recoverySuggestion: String? {
        if case .runtimeStorageUnavailable(let problem) = self, problem.kind == .unwritable {
            return "Free disk space or restore write access, then quit and reopen Guesthouse."
        }
        return switch recoveryActions.first {
        case .retry: "Try again."
        case .inspectState: "Check the environment before doing anything else."
        case .repair: "Use Repair to fix this without deleting the development Mac."
        case .openConsole: "Open the Mac console to continue."
        case .exportWork: "Export unpublished work first."
        case .openSettings: "Open Settings."
        case .signInAgain: "Sign in again."
        case .freeDiskSpace: "Free up disk space, then try again."
        case .deleteEnvironment: "Delete a development Mac you no longer need."
        case .reinstallApp: "Reinstall Guesthouse."
        case .cancel, .none: nil
        }
    }
}
