import Foundation

/// The Tart release Guesthouse is tested against (MVP-PLAN.md §3: "Pin command versions and
/// test output adapters"). Every parser in this directory targets this release's output.
public enum TartPin: Sendable {
    public static let version = TartVersion(SemanticVersion([2, 36, 0]))
    public static let releaseTag = "2.36.0"
    public static let repository = "https://github.com/openai/tart"
}

/// A Tart version as printed by `tart --version`.
public struct TartVersion: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    /// Always exactly three components, as Tart prints them: `2.36.0` is `[2, 36, 0]`.
    public let components: [Int]

    /// The comparable form. `SemanticVersion` treats a missing trailing component as zero and
    /// stores `2.36.0` as `2.36`, so this is the value to compare and `description` is the
    /// three-component spelling that the strict parse and the pin agree on.
    public var semantic: SemanticVersion { SemanticVersion(components) }

    /// - Precondition: at most three components; fewer are padded with zeros.
    public init(_ semantic: SemanticVersion) {
        precondition(semantic.components.count <= 3, "a Tart version has at most three components")
        components = semantic.components + Array(repeating: 0, count: max(0, 3 - semantic.components.count))
    }

    /// Parses the output of `tart --version`. Accepts the single line of the form `2.36.0`,
    /// `v2.36.0`, or `tart 2.36.0`, with all three numeric components present in their
    /// canonical decimal spelling (no leading zeros) and at most one prefix, ending in at most
    /// the one line terminator Tart prints. Anything else (extra or blank lines, a
    /// two-component version, `tart v2.36.0`, surrounding whitespace, trailing text) is not a
    /// version and must be treated as unknown, never as matching the pin.
    public init?(parsing output: String) {
        // Only the single expected terminator is removed, and the rest has to be the version
        // in full. Splitting on newlines would drop empty lines as well, so `\n2.36.0` and
        // `2.36.0\n\n` would reach the pin as the pinned spelling rather than as the drifted
        // output they are.
        var line = output[...]
        if line.last?.isNewline == true { line = line.dropLast() }
        guard let match = line.wholeMatch(of: #/(?:[Tt][Aa][Rr][Tt] |v)?((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))/#),
              let semantic = SemanticVersion(String(match.1))
        else { return nil }
        self.init(semantic)
    }

    /// Encoded as the canonical three-component string; decoding applies the same strict
    /// parse as CLI output, so a persisted or received `2.36` can never match the pin.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = TartVersion(parsing: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a three-component Tart version"))
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var matchesPin: Bool { self == TartPin.version }

    public static func < (lhs: TartVersion, rhs: TartVersion) -> Bool {
        lhs.semantic < rhs.semantic
    }

    /// Always three components (`2.36.0`, never `2.36`), the form the strict parse accepts.
    public var description: String {
        components.map(String.init).joined(separator: ".")
    }
}
