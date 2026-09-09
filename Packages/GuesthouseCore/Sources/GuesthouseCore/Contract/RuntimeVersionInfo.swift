/// Private identity/status metadata. Never attach this value to diagnostics or export it as a log.
public struct RuntimeVersionInfo: Codable, Hashable, Sendable {
    public let serviceVersion: String?
    public let serviceBuild: String?
    public let protocolVersion: RuntimeProtocolVersion
    /// The inspected runtime, which may be a candidate. This does not select a production provider.
    public let runtime: RuntimeIdentityInfo?

    public init(serviceVersion: String?, serviceBuild: String?,
                protocolVersion: RuntimeProtocolVersion = .current, runtime: RuntimeIdentityInfo? = nil) {
        self.serviceVersion = Self.admit(serviceVersion)
        self.serviceBuild = Self.admit(serviceBuild)
        self.protocolVersion = protocolVersion
        self.runtime = runtime
    }

    private enum CodingKeys: String, CodingKey { case serviceVersion, serviceBuild, protocolVersion, runtime }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(serviceVersion: try c.decodeIfPresent(String.self, forKey: .serviceVersion),
                  serviceBuild: try c.decodeIfPresent(String.self, forKey: .serviceBuild),
                  protocolVersion: try c.decode(RuntimeProtocolVersion.self, forKey: .protocolVersion),
                  runtime: try c.decodeIfPresent(RuntimeIdentityInfo.self, forKey: .runtime))
    }

    static func admit(_ value: String?) -> String? {
        value.flatMap { ConnectionVerificationRecord.isVersionIdentifier($0) ? $0 : nil }
    }
}

/// Reported pinned bundle identity/signature/entitlement checks, not archive digest or hardware
/// evidence. Only the runtime verifier may supply true; decoding a report is not verification.
public struct RuntimeIdentityInfo: Codable, Hashable, Sendable {
    public let provider: VMProvider
    public let version: String?
    public let verified: Bool
    public let problem: GuesthouseError?

    public init(provider: VMProvider, version: String?, verified: Bool, problem: GuesthouseError? = nil) {
        self.provider = provider
        self.version = RuntimeVersionInfo.admit(version)
        // A missing/invalid identity or a reported problem cannot become a usable verification.
        self.verified = verified && self.version != nil && problem == nil
        self.problem = problem ?? (verified && self.version == nil ? .runtimeIncompatible : nil)
    }

    private enum CodingKeys: String, CodingKey { case provider, version, verified, problem }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(provider: try c.decode(VMProvider.self, forKey: .provider),
                  version: try c.decodeIfPresent(String.self, forKey: .version),
                  verified: try c.decode(Bool.self, forKey: .verified),
                  problem: try c.decodeIfPresent(GuesthouseError.self, forKey: .problem))
    }
}
