import Foundation

/// The Tart release Guesthouse is tested against (MVP-PLAN.md §3: "Pin command versions and
/// test output adapters"). Every parser in this directory targets this release's output.
public enum TartPin {
    public static let version = TartVersion(SemanticVersion([2, 36, 0]))
    public static let releaseTag = "2.36.0"
    public static let repository = "https://github.com/openai/tart"
}

/// A Tart version as printed by `tart --version`.
public struct TartVersion: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    /// Always exactly three components, so the encoded string and the strict decoder agree.
    public let semantic: SemanticVersion

    /// - Precondition: at most three components; fewer are padded with zeros.
    public init(_ semantic: SemanticVersion) {
        precondition(semantic.components.count <= 3, "a Tart version has at most three components")
        let padded = semantic.components + Array(repeating: 0, count: max(0, 3 - semantic.components.count))
        self.semantic = SemanticVersion(padded)
    }

    /// Parses the output of `tart --version`. Accepts exactly one non-empty line of the form
    /// `2.36.0`, `v2.36.0`, or `tart 2.36.0`, with all three numeric components present and
    /// at most one prefix. Anything else (extra lines, a two-component version, `tart v2.36.0`,
    /// trailing text) is not a version and must be treated as unknown, never as matching the pin.
    public init?(parsing output: String) {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count == 1,
              let match = lines[0].wholeMatch(of: #/(?:[Tt][Aa][Rr][Tt] |v)?([0-9]+\.[0-9]+\.[0-9]+)/#),
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
        let padded = semantic.components + Array(repeating: 0, count: max(0, 3 - semantic.components.count))
        return padded.map(String.init).joined(separator: ".")
    }
}
