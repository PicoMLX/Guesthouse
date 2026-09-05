import Darwin
import Foundation

/// An IP address printed by `tart ip`, validated with `inet_pton`.
public struct GuestIPAddress: Hashable, Sendable, CustomStringConvertible {
    public enum Family: String, Codable, Hashable, Sendable {
        case ipv4, ipv6
    }

    public let rawValue: String
    public let family: Family

    public init?(_ string: String) {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace), !text.utf8.contains(0) else { return nil }
        var v4 = in_addr()
        if text.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            rawValue = text
            family = .ipv4
            return
        }
        var v6 = in6_addr()
        if text.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            rawValue = text
            family = .ipv6
            return
        }
        return nil
    }

    public var description: String { rawValue }
}

/// Encoded as the bare address string; decoding re-validates, so a persisted or received value
/// can never carry an address that `init?(_:)` would reject or a family that disagrees with it.
extension GuestIPAddress: Codable {
    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let address = GuestIPAddress(string) else {
            // The rejected text is never echoed: it came from outside the app.
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an IP address"))
        }
        self = address
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum TartIPParser: Sendable {
    /// `tart ip` prints exactly one address, followed by at most one line terminator, on
    /// success. Anything else — a blank line, padding around the address, several lines, a
    /// message — is a failure; the caller classifies stderr separately.
    public static func parse(_ stdout: String) throws(TartParseError) -> GuestIPAddress {
        var line = stdout[...]
        if line.last?.isNewline == true { line = line.dropLast() }
        // The address parser trims whatever surrounds an address, so padding and a second
        // line terminator are refused here instead: normalizing them would read output this
        // pinned Tart never printed as a valid address rather than sending it to the
        // runtime-incompatibility path.
        guard !line.contains(where: \.isWhitespace), let address = GuestIPAddress(String(line)) else { throw .notAnIPAddress }
        return address
    }
}
