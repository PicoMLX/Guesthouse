/// Text that came from outside the app (CLI output, guest responses, file names), normalized,
/// redacted, and bounded once, at construction, so it can be stored in an error, encoded,
/// journaled, and shown without a second pass (MVP-PLAN.md §3, "Local storage").
///
/// Decoding sanitizes again: a serialized or XPC-provided value is not trusted to have been
/// made here.
public struct SanitizedText: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let value: String

    public init(_ raw: String, limit: Int = 80) {
        value = GuesthouseError.sanitize(raw, limit: limit)
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public var description: String { value }
}
