/// A dotted numeric version such as `26.5.2` or `2.36.0`, compared component by component.
///
/// Missing trailing components count as zero, so `26.5` equals `26.5.0`. Anything that is not
/// a dotted sequence of integers fails to parse; callers must then treat the version as unknown
/// rather than guess.
public struct SemanticVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let components: [Int]

    /// Components must be nonnegative; the string initializer already enforces this, and an
    /// encoded negative component could never be decoded again.
    public init(_ components: [Int]) {
        precondition(components.allSatisfy { $0 >= 0 }, "version components must be nonnegative")
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 {
            trimmed.removeLast()
        }
        self.components = trimmed.isEmpty ? [0] : trimmed
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        var parsed: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            parsed.append(value)
        }
        guard !parsed.isEmpty else { return nil }
        self.init(parsed)
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let l = index < lhs.components.count ? lhs.components[index] : 0
            let r = index < rhs.components.count ? rhs.components[index] : 0
            if l != r { return l < r }
        }
        return false
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }
}

extension SemanticVersion: Codable {
    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let version = SemanticVersion(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a dotted numeric version: \(string)"))
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// An inclusive version range; `maximum == nil` means open-ended.
///
/// The bounds are immutable: a range that could be inverted after construction would let a
/// rule that once matched silently stop firing, without passing any of the checks below.
public struct VersionRange: Codable, Hashable, Sendable {
    public let minimum: SemanticVersion
    public let maximum: SemanticVersion?

    /// An inverted range would contain nothing and let a rule silently never fire.
    public init(minimum: SemanticVersion, maximum: SemanticVersion? = nil) {
        precondition(maximum.map { minimum <= $0 } ?? true, "inverted version range")
        self.minimum = minimum
        self.maximum = maximum
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let minimum = try c.decode(SemanticVersion.self, forKey: .minimum)
        let maximum = try c.decodeIfPresent(SemanticVersion.self, forKey: .maximum)
        if let maximum, maximum < minimum {
            throw DecodingError.dataCorruptedError(forKey: .maximum, in: c, debugDescription: "maximum is below minimum")
        }
        self.init(minimum: minimum, maximum: maximum)
    }

    public func contains(_ version: SemanticVersion) -> Bool {
        if version < minimum { return false }
        if let maximum, maximum < version { return false }
        return true
    }
}
