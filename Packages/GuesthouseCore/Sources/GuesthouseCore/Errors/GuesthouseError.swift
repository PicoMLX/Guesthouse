import Foundation

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
    case runtimeMissing
    case runtimeIncompatible(found: SanitizedText?, required: String)
    case guestNotReachable(EnvironmentID)
    case hostKeyChanged(EnvironmentID)
    case credentialsLocked(CredentialStore)
    case loginExpired(Provider)
    case toolMismatch(tool: String, found: SanitizedText?, expected: String)
    case xcodeComponentsIncomplete(missing: MissingComponents)
    case vmSlotUnavailable(maximum: Int)
    case operationOutcomeUnknown(OperationID)
    case unauthorizedCaller
    case protocolMismatch(client: Int, service: Int)
    case invalidRequest(InvalidRequestReason)
    case canceled

    public enum UnsupportedHostReason: Codable, Hashable, Sendable {
        case notAppleSilicon
        case macOSTooOld(found: SanitizedText, minimum: String)
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
    }

    /// Coarse grouping for filtering diagnostics and choosing presentation.
    public enum Category: String, Codable, Hashable, Sendable, CaseIterable {
        case host, storage, runtime, guest, credentials, tools, workflow, ipc, user
    }

    public var category: Category {
        switch self {
        case .unsupportedHost: .host
        case .insufficientDisk: .storage
        case .downloadVerificationFailed, .runtimeMissing, .runtimeIncompatible: .runtime
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
        case .unsupportedHost(.notAppleSilicon):
            "This Mac has an Intel processor. Guesthouse needs an Apple silicon Mac to run a macOS virtual machine."
        case .unsupportedHost(.macOSTooOld(let found, let minimum)):
            "This Mac runs macOS \(found.value). Guesthouse needs macOS \(Self.sanitize(minimum)) or later."
        case .unsupportedHost(.insufficientMemory(let found, let minimum)):
            "This Mac has \(Self.formatMemory(found)) of memory. Guesthouse needs at least \(Self.formatMemory(minimum)) to run a development Mac alongside your other apps."
        case .insufficientDisk(let required, let available, let volume):
            Self.insufficientDiskMessage(required: required, available: available, volume: volume.value)
        case .downloadVerificationFailed(let artifact, let check):
            "The downloaded \(artifact.value) failed its \(check.rawValue) check and was not installed. The download may be incomplete or tampered with."
        case .runtimeMissing:
            "The virtual machine runtime is not installed."
        case .runtimeIncompatible(let found, let required):
            "The installed virtual machine runtime (\(found?.value ?? "unknown version")) is not the tested version \(Self.sanitize(required))."
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
            "The development Mac has \(Self.sanitize(tool)) \(found?.value ?? "missing") but the tested version is \(Self.sanitize(expected))."
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
        case .unsupportedHost: [.cancel]
        case .insufficientDisk: [.freeDiskSpace, .retry, .openSettings, .cancel]
        case .downloadVerificationFailed: [.retry, .cancel]
        case .runtimeMissing: [.repair(.runtime), .cancel]
        case .runtimeIncompatible: [.repair(.runtime), .exportWork, .cancel]
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
        case .runtimeMissing: "runtimeMissing"
        case .runtimeIncompatible: "runtimeIncompatible"
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
    /// begins inside the visible prefix is always fully inside the redacted window.
    static let sanitizeLookahead = 512

    public static func sanitize(_ value: String, limit: Int = 80) -> String {
        // Only the window plus one scalar is ever looked at, so the cost is independent of the
        // input's size.
        let window = value.unicodeScalars.prefix(limit + Self.sanitizeLookahead + 1)
        let truncated = window.count > limit + Self.sanitizeLookahead
        let bounded = String(String.UnicodeScalarView(window.prefix(limit + Self.sanitizeLookahead)))
        // Complete escape sequences go first, so styling inside a token cannot leave a
        // fragment behind once the bare control scalars are dropped. Combining marks go too:
        // a mark inside a token would otherwise split it out of the redactor's reach.
        let stripped = Redactor.stripTerminalEscapes(bounded)
        var normalized = String(String.UnicodeScalarView(stripped.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned,
                 .nonspacingMark, .spacingMark, .enclosingMark:
                false
            default:
                true
            }
        }))
        if truncated {
            // A URL authority still open at the cut may be userinfo whose terminating `@` fell
            // outside the window: treat the whole remainder as a credential.
            normalized = normalized.replacing(#/(:\/\/)[^\s\/]*$/#) { match in "\(match.1)\(Redactor.marker("userinfo"))" }
        }
        let redacted = Redactor().redact(fieldValue: normalized)
        let scalars = redacted.unicodeScalars
        guard scalars.count > limit else { return redacted }
        return String(String.UnicodeScalarView(scalars.prefix(limit))) + "…"
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

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private static func formatMemory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
}

extension GuesthouseError: CustomStringConvertible {
    public var description: String { redactedDescription }
}

extension GuesthouseError: LocalizedError {
    public var errorDescription: String? { userMessage }

    public var recoverySuggestion: String? {
        switch recoveryActions.first {
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
