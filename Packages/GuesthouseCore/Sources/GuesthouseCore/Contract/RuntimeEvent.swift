import CryptoKit
import Foundation

/// Everything the runtime service streams back to the GUI.
public enum RuntimeEvent: Codable, Hashable, Sendable {
    /// The reply to `runtimeVersion`.
    case runtimeVersion(RuntimeVersionInfo)
    /// The request was journaled and is now in flight.
    case accepted(OperationID)
    case progress(OperationID, ProgressPhase)
    /// A redacted line of output. Never raw process output.
    case log(OperationID?, RedactedLine)
    case status(EnvironmentStatus)
    case completed(OperationID)
    case failed(OperationID, GuesthouseError)

    public var caseName: String {
        switch self {
        case .runtimeVersion: "runtimeVersion"
        case .accepted: "accepted"
        case .progress: "progress"
        case .log: "log"
        case .status: "status"
        case .completed: "completed"
        case .failed: "failed"
        }
    }
}

public struct RuntimeVersionInfo: Codable, Hashable, Sendable {
    public var serviceVersion: String
    public var serviceBuild: String
    public var protocolVersion: RuntimeProtocolVersion
    /// `nil` until the service has located a runtime bundle.
    public var tart: TartRuntimeInfo?

    public init(serviceVersion: String, serviceBuild: String, protocolVersion: RuntimeProtocolVersion = .current, tart: TartRuntimeInfo? = nil) {
        self.serviceVersion = serviceVersion
        self.serviceBuild = serviceBuild
        self.protocolVersion = protocolVersion
        self.tart = tart
    }

    public struct TartRuntimeInfo: Codable, Hashable, Sendable {
        /// Parsed from the runtime's own `--version` output: redacted and bounded before it
        /// is stored, so CLI text cannot reach the GUI or diagnostics unchanged.
        public private(set) var version: String
        /// Signature and digest checks passed against the pinned expectations.
        public var verified: Bool

        public init(version: String, verified: Bool) {
            self.version = GuesthouseError.sanitize(version, limit: 64)
            self.verified = verified
        }

        private enum CodingKeys: String, CodingKey { case version, verified }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(version: try c.decode(String.self, forKey: .version), verified: try c.decode(Bool.self, forKey: .verified))
        }
    }
}

/// A named step of an operation, shown as real progress instead of one indefinite spinner
/// (MVP-PLAN.md §2, step 2).
public struct ProgressPhase: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case inspectingState
        case verifyingRuntime
        case startingVM
        case waitingForNetwork
        case stoppingVM
        case forceStoppingVM
        case validatingSelection
        case copying
        case verifyingCopy
    }

    public var kind: Kind
    /// 0...1 when the phase can measure itself; `nil` for indeterminate phases. Only this
    /// type sets it, so a value that cannot be encoded never reaches an event.
    public private(set) var fraction: Double?
    /// False for phases that must not be interrupted (for example a rename after a copy).
    public var cancelable: Bool

    /// A fraction that is not finite or not within `0...1` is dropped, so a backend that
    /// divides by zero yields an indeterminate phase rather than an event that cannot be
    /// encoded.
    public init(kind: Kind, fraction: Double? = nil, cancelable: Bool = true) {
        self.kind = kind
        self.fraction = Self.valid(fraction)
        self.cancelable = cancelable
    }

    private enum CodingKeys: String, CodingKey { case kind, fraction, cancelable }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(Kind.self, forKey: .kind), fraction: try c.decodeIfPresent(Double.self, forKey: .fraction), cancelable: try c.decodeIfPresent(Bool.self, forKey: .cancelable) ?? true)
    }

    /// A copy of the phase measured at `fraction`, normalized the same way.
    public func measured(_ fraction: Double?) -> ProgressPhase {
        ProgressPhase(kind: kind, fraction: fraction, cancelable: cancelable)
    }

    static func valid(_ fraction: Double?) -> Double? {
        guard let fraction, fraction.isFinite, (0...1).contains(fraction) else { return nil }
        return fraction
    }
}

/// What the service knows about one environment right now. Produced by reconciling the
/// VM inventory, the process-identity verdict, and the journal; never read from a cache.
public struct EnvironmentStatus: Codable, Hashable, Sendable {
    public enum VMState: Codable, Hashable, Sendable {
        case notFound
        case stopped
        case running
        /// Ownership could not be established (for example a PID that no longer matches).
        /// Start is refused until a person or a repair resolves it. The reason is formed from
        /// runtime and process-identity diagnostics, which quote CLI text: `SanitizedText`
        /// bounds and redacts it at construction and again when decoded, so it reaches GUI
        /// status under the same rules as an observation or an error.
        case uncertain(reason: SanitizedText)
    }

    public enum Readiness: Codable, Hashable, Sendable {
        /// Reconciliation has not finished. The GUI shows "Checking environment".
        case checking
        case ready
        case needsAttention(GuesthouseError)
    }

    public var environmentID: EnvironmentID
    public var vm: VMState
    public var readiness: Readiness
    public var inFlightOperation: OperationID?
    /// Versions observed on the host and guest, with unknowns left `nil`.
    /// Only this type sets it, and only through `sanitizedForWire()`: a raw probe value can
    /// never be assigned into a status and encoded unchanged.
    public private(set) var observed: ObservedTuple
    public var reconciledAt: Date?

    public init(
        environmentID: EnvironmentID,
        vm: VMState,
        readiness: Readiness,
        inFlightOperation: OperationID? = nil,
        observed: ObservedTuple = ObservedTuple(),
        reconciledAt: Date? = nil
    ) {
        self.environmentID = environmentID
        self.vm = vm
        self.readiness = readiness
        self.inFlightOperation = inFlightOperation
        // Observations come from guest and CLI probes: every string is bounded and redacted
        // before it crosses XPC, at construction and again when decoded.
        self.observed = observed.sanitizedForWire()
        self.reconciledAt = reconciledAt
    }
}


extension ObservedTuple {
    /// Every string bounded and redacted; capabilities capped in number and length. A value
    /// that cannot survive as an identity — one a secret was removed from, or one longer than
    /// the sanitizer ever reads — becomes unknown instead.
    public func sanitizedForWire() -> ObservedTuple {
        mapped(string: { Self.bounded($0, limit: 256) }, capabilities: Self.boundedCapabilities)
    }

    /// The same bounds for an observation that has already crossed the wire: the sender is
    /// another process, so every string is redacted and bounded again. No identity is derived
    /// here, and a generated `[exact:…]` suffix is left as it arrived rather than read as
    /// forged marker text, so a status the sender sanitized is evaluated by the receiver under
    /// the identity it was sent with. A peer that invents a suffix gains nothing: it supplies
    /// every other field of the observation as well.
    func boundedForDecoding() -> ObservedTuple {
        mapped(
            string: { GuesthouseError.sanitize($0, limit: 256) },
            capabilities: { values in
                Self.canonicalCapabilities(values.prefix(Self.maximumCapabilities).map { GuesthouseError.sanitize($0, limit: 128) })
            }
        )
    }

    /// `clean` returns `nil` for an observation that cannot serve as an identity, and the field
    /// becomes unknown rather than being kept as a value two different observations could share.
    private func mapped(string clean: (String) -> String?, capabilities: ([String]) -> [String]?) -> ObservedTuple {
        var copy = self
        copy.hostMacOSBuild = hostMacOSBuild.flatMap(clean)
        copy.codexDesktopVersion = codexDesktopVersion.flatMap(clean)
        copy.codexDesktopBuild = codexDesktopBuild.flatMap(clean)
        copy.codexDesktopPath = codexDesktopPath.flatMap(clean)
        copy.tartVersion = tartVersion.flatMap(clean)
        copy.guestMacOSBuild = guestMacOSBuild.flatMap(clean)
        copy.xcodeBuild = xcodeBuild.flatMap(clean)
        copy.codexCLIVersion = codexCLIVersion.flatMap(clean)
        copy.codexCLIPath = codexCLIPath.flatMap(clean)
        copy.codexCLICapabilities = codexCLICapabilities.flatMap(capabilities)
        copy.githubCLIVersion = githubCLIVersion.flatMap(clean)
        copy.provisioningScriptVersion = provisioningScriptVersion.flatMap(clean)
        return copy
    }

    /// Sanitizing is lossy, and these values are also an identity: a long path and a
    /// decomposed one can bound to the same text. A value the sanitizer changed therefore
    /// carries a digest of the exact observation, so two different observations never
    /// collapse into one verified compatibility tuple. `nil` means the observation cannot be
    /// an identity at all, and the field is reported unknown rather than as a value another
    /// observation could match (MVP-PLAN.md §5: report unknown rather than guess).
    static func bounded(_ value: String, limit: Int) -> String? {
        let scalars = value.unicodeScalars
        let inspectable = limit + GuesthouseError.sanitizeLookahead
        // Text past the window is never read: it is not redacted and no digest covers it, so
        // two values that share the window are indistinguishable here. Reporting one of them
        // as an exact observation would let a changed executable match the connection record
        // of the one before it. The window is measured, and everything below works on it, so
        // arbitrarily long CLI output is never copied or scanned in full either.
        let window = scalars.prefix(inspectable + 1)
        guard window.count <= inspectable else { return nil }
        // Untrusted text must not be able to forge the suffix this function appends. Escaping
        // the escape before the marker keeps that neutralization injective: were the marker
        // alone rewritten, `foo[exact:` and `foo[exact\u{FFFD}:` would both arrive at the
        // latter and two different observations would share one identity.
        let escaped = String(String.UnicodeScalarView(window))
            .replacingOccurrences(of: identityEscape, with: identityEscape + identityEscape)
            .replacingOccurrences(of: identityMarker, with: "[exact\(identityEscape):")
        // Escaping grows the text — every escape scalar becomes two — so the string that
        // reaches the sanitizer can stand outside the window the raw value was measured
        // against. The window is what makes both answers below honest: past it nothing is
        // redacted and the digest would cover a tail nobody inspected, publishing a verifier
        // for whatever credential was placed there. A value that no longer fits is unknown,
        // for the same reason one that never fit is.
        guard escaped.unicodeScalars.count <= inspectable else { return nil }
        let (sanitized, wasRedacted) = GuesthouseError.sanitizeReporting(escaped, limit: limit)
        // A redacted value stands for a secret. It gets no digest, since that would let a guess
        // be confirmed, and it is not an identity either: two paths that differ only in the
        // credential they contain redact to the same text, and calling that an exact value
        // would reuse one path's verification record for the other. Whether redaction happened
        // comes from the sanitizer itself, not from marker text the value could contain.
        guard !wasRedacted else { return nil }
        // A value the sanitizer left alone is its own identity. One it merely bounded or
        // normalized carries a digest of the inspected text, counted against the same limit.
        guard sanitized != escaped else { return sanitized }
        let room = max(16, limit - identitySuffixLength)
        return "\(GuesthouseError.sanitize(escaped, limit: room)) \(identityMarker)\(digest(of: escaped))]"
    }

    /// `" [exact:" + 12 hex + "]"`, plus the one scalar the sanitizer adds when it truncates.
    static let identitySuffixLength = 22
    static let identityMarker = "[exact:"
    static let identityEscape = "\u{FFFD}"
    static let maximumCapabilities = 64
    /// The most raw entries a probe may report before the answer stops being a capability list.
    /// Bounding and redacting an entry is real work, and the canonical list is built and sorted
    /// before `maximumCapabilities` applies, so without this the cost of constructing a status
    /// would follow whatever the guest printed rather than the bounded shape that goes over the
    /// wire. Far above any real CLI's capability list, and far below a size worth inspecting.
    static let maximumReportedCapabilities = 1024

    /// The canonical form of a reported capability list: duplicates collapsed, and the order
    /// the guest happened to use removed. Bounded by `maximumReportedCapabilities` rather than
    /// by the wire cap, because the cap is applied *after* this: the identity below is derived
    /// from the canonical form, and capping before the sort would make it depend on the order
    /// the probe reported in. `CompatibilityTuple.normalize` refuses to canonicalize a list
    /// over the wire cap on purpose — a persisted record's count check must still see a flood
    /// of duplicates rather than the one entry they collapse to — and an observation on the
    /// wire is capped rather than refused, so it canonicalizes here instead.
    static func canonicalCapabilities(_ values: [String]) -> [String] {
        guard values.count <= maximumReportedCapabilities else {
            return Array(values.prefix(maximumReportedCapabilities + 1))
        }
        return Array(Set(values)).sorted()
    }

    /// The first `maximumCapabilities` entries of the canonical list, each bounded; when entries
    /// are dropped, one further entry names how many and carries a digest of the whole list, so
    /// two capability sets that share a prefix keep different identities. That entry wears the
    /// same identity marker as a bounded value, so a literal capability shaped like it is
    /// neutralized and cannot pass a different capability set off as a capped one. The digest is
    /// over the bounded entries: an entry past the cap is never inspected, and hashing it raw
    /// would publish a digest of whatever secret it holds.
    ///
    /// The list is made canonical before it is capped and hashed, not after. A probe may report
    /// the same capabilities in any order, or twice; which entries the cap keeps and what the
    /// digest covers must not depend on that, or one capability set would produce two
    /// identities and revalidate a connection that never changed.
    ///
    /// `nil` when any entry is not an identity: dropping just that entry would let two
    /// different capability sets collapse into one. `nil` too when there are more raw entries
    /// than `maximumReportedCapabilities`, which is checked before any of them is read: keeping
    /// a prefix of such a list is not open either, because the digest below would then cover
    /// the prefix and two different lists that share one would arrive at a single identity.
    static func boundedCapabilities(_ values: [String]) -> [String]? {
        guard values.count <= maximumReportedCapabilities else { return nil }
        var entries: [String] = []
        for value in values {
            guard let entry = bounded(value, limit: 128) else { return nil }
            entries.append(entry)
        }
        let canonical = Self.canonicalCapabilities(entries)
        guard canonical.count > maximumCapabilities else { return canonical }
        let kept = Array(canonical.prefix(maximumCapabilities - 1))
        let omitted = canonical.count - kept.count
        return Self.canonicalCapabilities(kept + ["\(omitted) more \(identityMarker)\(digest(ofList: canonical))]"])
    }

    /// A digest over a length-prefixed encoding, so no two different lists can produce the
    /// same input: a value containing the separator cannot be mistaken for two values.
    static func digest(ofList values: [String]) -> String {
        var data = Data()
        for value in values {
            let bytes = Data(value.utf8)
            withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(of value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
