/// A line of text that has passed through `Redactor`.
///
/// Log sinks, the XPC event stream, and diagnostics exports accept only this type, so an
/// unredacted `String` cannot reach them by accident. The only ways to obtain one are
/// `Redactor` and a compile-time string literal.
struct RedactedLine: Hashable, Sendable, CustomStringConvertible {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    /// For fixed messages that contain nothing to redact, such as `"Started"`.
    init(literal: StaticString) {
        text = literal.description
    }

    var description: String { text }
}

extension RedactedLine: Codable {
    /// Decoded text is redacted again: a serialized or XPC-provided value is not trusted to
    /// have passed through `Redactor` on the other side. The line that gave a device code its
    /// context did not survive serialization, so codes are redacted unconditionally here.
    init(from decoder: any Decoder) throws {
        text = Redactor().redact(untrusted: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}
