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
    public let semantic: SemanticVersion

    public init(_ semantic: SemanticVersion) {
        self.semantic = semantic
    }

    /// Parses the output of `tart --version`. Accepts `2.36.0`, `v2.36.0`, and `tart 2.36.0`;
    /// anything else is not a version and must be treated as unknown, never guessed.
    public init?(parsing output: String) {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLine = text.split(whereSeparator: \.isNewline).first else { return nil }
        text = String(firstLine)
        if text.lowercased().hasPrefix("tart ") { text = String(text.dropFirst(5)) }
        if text.hasPrefix("v") { text = String(text.dropFirst()) }
        guard let semantic = SemanticVersion(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        self.init(semantic)
    }

    public var matchesPin: Bool { self == TartPin.version }

    public static func < (lhs: TartVersion, rhs: TartVersion) -> Bool {
        lhs.semantic < rhs.semantic
    }

    public var description: String { semantic.description }
}
