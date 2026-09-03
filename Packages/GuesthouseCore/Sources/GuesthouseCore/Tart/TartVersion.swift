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

    /// Parses the output of `tart --version`. Accepts exactly one non-empty line of the form
    /// `2.36.0`, `v2.36.0`, or `tart 2.36.0`, with all three numeric components present.
    /// Anything else (extra lines, a two-component version, trailing text) is not a version and
    /// must be treated as unknown, never as matching the pin.
    public init?(parsing output: String) {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count == 1 else { return nil }
        var text = lines[0]
        if text.lowercased().hasPrefix("tart ") { text = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        if text.hasPrefix("v") { text = String(text.dropFirst()) }
        guard text.wholeMatch(of: #/[0-9]+\.[0-9]+\.[0-9]+/#) != nil, let semantic = SemanticVersion(text) else { return nil }
        self.init(semantic)
    }

    public var matchesPin: Bool { self == TartPin.version }

    public static func < (lhs: TartVersion, rhs: TartVersion) -> Bool {
        lhs.semantic < rhs.semantic
    }

    public var description: String { semantic.description }
}
