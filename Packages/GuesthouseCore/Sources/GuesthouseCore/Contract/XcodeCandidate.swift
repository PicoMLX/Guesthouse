/// Bounded metadata from a selected Xcode bundle (#26, MVP §§2–3). This is not a signature,
/// compatibility, complete-copy or guest readiness result. No host path travels in this value.
public struct XcodeCandidate: Codable, Hashable, Sendable {
    public let version: SemanticVersion
    public let build: String
    /// Nil when no complete bounded estimate is available; never substitute a partial sum.
    public let sizeEstimateBytes: UInt64?

    public init?(version: SemanticVersion, build: String, sizeEstimateBytes: UInt64? = nil) {
        guard ConnectionVerificationRecord.isBuildIdentifier(build) else { return nil }
        self.version = version
        self.build = build
        self.sizeEstimateBytes = sizeEstimateBytes
    }

    private enum CodingKeys: String, CodingKey { case version, build, sizeEstimateBytes }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self(version: try c.decode(SemanticVersion.self, forKey: .version),
            build: try c.decode(String.self, forKey: .build), sizeEstimateBytes: try c.decodeIfPresent(UInt64.self, forKey: .sizeEstimateBytes)) else {
            throw DecodingError.dataCorruptedError(forKey: .build, in: c, debugDescription: "Unsupported Xcode build identity.")
        }
        self = value
    }
}

/// Selection-specific recovery, with no paths, plist values or underlying errors (ADR 0003).
public enum XcodeSelectionFailure: String, Error, Codable, Hashable, Sendable, CaseIterable {
    case unavailable, notAnApplication, notXcode, metadataUnreadable
    public var userMessage: String {
        switch self {
        case .unavailable: "Guesthouse could not access the selected application. Select Xcode again."
        case .notAnApplication: "The selection is not a complete application bundle. Choose an installed Xcode application."
        case .notXcode: "The selected application does not identify itself as Xcode. Choose the Xcode application."
        case .metadataUnreadable: "Guesthouse could not read valid Xcode version and build information. Choose a complete Xcode installation."
        }
    }
    public var recoveryActions: [RecoveryAction] { [.reviewRequest, .cancel] }
}
