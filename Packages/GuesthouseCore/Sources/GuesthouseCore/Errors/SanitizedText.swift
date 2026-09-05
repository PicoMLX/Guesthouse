/// Text that came from outside the app (CLI output, guest responses, file names), normalized,
/// redacted, and bounded once, at construction, so it can be stored in an error, encoded,
/// journaled, and shown without a second pass (MVP-PLAN.md §3, "Local storage").
///
/// The bound is at most `maximumLimit` scalars whatever the caller asks for. Decoding
/// sanitizes again at that maximum, so a value made with any permitted limit survives a
/// round trip unchanged while a raw serialized value is still bounded and redacted.
public struct SanitizedText: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public static let defaultLimit = 80
    public static let maximumLimit = 1_024

    public let value: String

    public init(_ raw: String, limit: Int = SanitizedText.defaultLimit) {
        value = Self.sanitize(raw, limit: min(max(limit, 1), Self.maximumLimit))
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self), limit: Self.maximumLimit)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public var description: String { value }
}
