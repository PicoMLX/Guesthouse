/// Named, measured runtime progress (#9, MVP-PLAN.md §2), never an output transcript.
public struct ProgressPhase: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case inspectingState, verifyingRuntime, startingVM, waitingForNetwork, stoppingVM
        case forceStoppingVM, validatingSelection, copying, verifyingCopy
    }
    public let kind: Kind
    /// Invalid/nonfinite measurements become indeterminate, not false completion.
    public let fraction: Double?
    /// The runtime still enforces safe cancellation; this is a UI presentation hint.
    public let cancelable: Bool

    public init(kind: Kind, fraction: Double? = nil, cancelable: Bool = true) {
        self.kind = kind
        self.fraction = Self.valid(fraction)
        self.cancelable = cancelable
    }

    private enum CodingKeys: String, CodingKey { case kind, fraction, cancelable }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(Kind.self, forKey: .kind),
                  fraction: try c.decodeIfPresent(Double.self, forKey: .fraction),
                  cancelable: try c.decodeIfPresent(Bool.self, forKey: .cancelable) ?? true)
    }

    public func measured(_ fraction: Double?) -> Self {
        Self(kind: kind, fraction: fraction, cancelable: cancelable)
    }

    private static func valid(_ fraction: Double?) -> Double? {
        guard let fraction, fraction.isFinite, (0...1).contains(fraction) else { return nil }
        return fraction
    }
}
