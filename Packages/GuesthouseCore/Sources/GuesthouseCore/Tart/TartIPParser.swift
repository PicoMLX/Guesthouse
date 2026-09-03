import Darwin
import Foundation

/// An IP address printed by `tart ip`, validated with `inet_pton`.
public struct GuestIPAddress: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Family: String, Codable, Hashable, Sendable {
        case ipv4, ipv6
    }

    public let rawValue: String
    public let family: Family

    public init?(_ string: String) {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
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

public enum TartIPParser {
    /// `tart ip` prints exactly one address on success. Anything else, including several lines
    /// or a message, is a failure; the caller classifies stderr separately.
    public static func parse(_ stdout: String) throws(TartParseError) -> GuestIPAddress {
        let lines = stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count == 1, let address = GuestIPAddress(lines[0]) else { throw .notAnIPAddress }
        return address
    }
}
