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
        value = GuesthouseError.sanitize(raw, limit: min(max(limit, 1), Self.maximumLimit))
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

/// Component names an untrusted guest reported as missing, bounded at construction and when
/// decoded so neither a message nor an encoded payload grows with the guest's list.
public struct MissingComponents: Hashable, Sendable, Codable, ExpressibleByArrayLiteral {
    public static let maximumListed = 20

    /// At most `maximumListed` names.
    public let listed: [SanitizedText]
    /// How many further names were reported and dropped.
    public let omitted: Int

    public init(_ components: [SanitizedText]) {
        listed = Array(components.prefix(Self.maximumListed))
        omitted = max(0, components.count - Self.maximumListed)
    }

    public init(arrayLiteral elements: SanitizedText...) {
        self.init(elements)
    }

    private enum CodingKeys: String, CodingKey { case listed, omitted }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var names = try c.nestedUnkeyedContainer(forKey: .listed)
        var kept: [SanitizedText] = []
        var dropped = 0
        while !names.isAtEnd {
            guard kept.count < Self.maximumListed else {
                // Past the cap only the number matters, so the element is stepped over
                // instead of being sanitized and retained: a list from a hostile sender
                // costs no more than counting it.
                _ = try names.decode(SkippedName.self)
                dropped += 1
                continue
            }
            kept.append(try names.decode(SanitizedText.self))
        }
        listed = kept
        let declaredOmitted = try c.decodeIfPresent(Int.self, forKey: .omitted) ?? 0
        // A sender can declare `Int.max` omitted names; the total saturates so a malformed
        // payload cannot trap in its receiver.
        omitted = Self.saturatingSum(max(0, declaredOmitted), dropped)
    }

    /// Consumes one element of the encoded list without materializing it.
    private struct SkippedName: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    private static func saturatingSum(_ a: Int, _ b: Int) -> Int {
        let (sum, overflowed) = a.addingReportingOverflow(b)
        return overflowed ? .max : sum
    }

    public var count: Int { Self.saturatingSum(listed.count, omitted) }
}
