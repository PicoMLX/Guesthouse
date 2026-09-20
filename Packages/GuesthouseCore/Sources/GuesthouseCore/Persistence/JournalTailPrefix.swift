import Foundation

/// Recognizes prefixes of closed journal encoder shapes, not arbitrary broken JSON.
/// Framing proves neither write origin nor mutation outcome. Unknown tails remain evidence.
struct JournalTailPrefix {
    private indirect enum Shape: Sendable {
        case object([String: Shape]), choice([Shape]), literal([UInt8]), uuid, unsigned, signed, date
    }
    private enum Stop: Error { case incomplete, invalid }
    private static let shape: Shape? = try? makeShape()
    private let bytes: [UInt8]
    private var index = 0

    static func accepts(_ data: Data) -> Bool {
        // These closed types emit ASCII; invalid/partial UTF-8 and NUL are not encoder tails.
        guard data.first == 123, data.allSatisfy({ $0 < 128 && $0 != 0 }),
              let shape else { return false }
        var parser = Self(bytes: Array(data))
        do { try parser.value(shape); return false }
        catch Stop.incomplete { return true }
        catch { return false }
    }

    private mutating func peek() throws -> UInt8 {
        // The journal uses compact JSONEncoder output. Whitespace is not an omitted
        // delimiter: preserving it as corruption avoids erasing a damaged final record.
        guard index < bytes.count else { throw Stop.incomplete }
        return bytes[index]
    }

    private mutating func take(_ byte: UInt8) throws {
        guard try peek() == byte else { throw Stop.invalid }
        index += 1
    }

    private mutating func literal(_ expected: [UInt8]) throws {
        _ = try peek()
        for byte in expected {
            guard index < bytes.count else { throw Stop.incomplete }
            guard bytes[index] == byte else { throw Stop.invalid }
            index += 1
        }
    }

    private mutating func value(_ shape: Shape) throws {
        switch shape {
        case .object(let fields):
            try take(123)
            var remaining = fields
            if remaining.isEmpty { try take(125); return }
            while true {
                // Encoder keys are closed ASCII. Validate interrupted keys as well as full keys.
                _ = try peek()
                var matched: String?
                var possible = false
                for key in remaining.keys {
                    var candidate = self
                    do {
                        try candidate.literal(Array(("\"" + key + "\"").utf8))
                        matched = key
                        index = candidate.index
                        break
                    } catch Stop.incomplete { possible = true }
                    catch {}
                }
                guard let key = matched, let field = remaining.removeValue(forKey: key) else {
                    if possible { throw Stop.incomplete }
                    throw Stop.invalid
                }
                try take(58)
                try value(field)
                let separator = try peek()
                index += 1
                if separator == 125 {
                    guard remaining.isEmpty else { throw Stop.invalid }
                    return
                }
                guard separator == 44, !remaining.isEmpty else { throw Stop.invalid }
            }
        case .choice(let choices):
            var possible = false
            for choice in choices {
                var candidate = self
                do { try candidate.value(choice); index = candidate.index; return }
                catch Stop.incomplete { possible = true }
                catch {}
            }
            if possible { throw Stop.incomplete }
            throw Stop.invalid
        case .literal(let expected): try literal(expected)
        case .uuid:
            _ = try peek()
            for position in 0..<38 {
                guard index < bytes.count else { throw Stop.incomplete }
                let byte = bytes[index]
                if position == 0 || position == 37 {
                    guard byte == 34 else { throw Stop.invalid }
                } else if [9, 14, 19, 24].contains(position) {
                    guard byte == 45 else { throw Stop.invalid }
                } else {
                    guard (48...57).contains(byte) || (65...70).contains(byte) else { throw Stop.invalid }
                }
                index += 1
            }
        case .unsigned, .signed, .date:
            _ = try peek()
            let start = index
            while index < bytes.count, ![9, 10, 13, 32, 44, 125].contains(bytes[index]) { index += 1 }
            let token = String(decoding: bytes[start..<index], as: UTF8.self)
            let integer = #"^-?(0|[1-9][0-9]*)$"#
            switch shape {
            case .unsigned:
                guard token.range(of: #"^(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil,
                      UInt64(token) != nil else { throw Stop.invalid }
            case .signed:
                if token == "-", index == bytes.count { throw Stop.incomplete }
                guard token.range(of: integer, options: .regularExpression) != nil,
                      let number = Int(token), String(number) == token else { throw Stop.invalid }
            default:
                guard Self.canonicalDate(token) == token ||
                      (index == bytes.count && Self.hasDateCompletion(token)) else { throw Stop.invalid }
            }
        }
    }

    private static func canonicalDate(_ token: String) -> String? {
        guard let number = Double(token), number.isFinite,
              let data = try? JSONEncoder().encode(Date(timeIntervalSinceReferenceDate: number)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func hasDateCompletion(_ token: String) -> Bool {
        // An EOF token may end inside a number: 1.00 is a real prefix of 1.001.
        // Require an encoder-produced witness, not just a permissive decimal regex.
        // Binary64's shortest finite spelling fits within 32 ASCII bytes.
        guard token.utf8.count < 32 else { return false }
        for suffix in ["0", "1"] {
            if canonicalDate(token + suffix)?.hasPrefix(token) == true { return true }
        }
        if token.contains("e") {
            for exponent in 0...324 {
                for sign in ["", "-", "+"] {
                    if canonicalDate(token + sign + String(exponent))?.hasPrefix(token) == true { return true }
                }
            }
        }
        return false
    }

    /// Derive enum keys/associated labels from Codable, without a second wire-format schema.
    /// Numeric and UUID leaves vary; every other token must match an encoded sample.
    private static func encodedShape<T: Encodable>(_ value: T) throws -> Shape {
        func shape(_ object: Any) throws -> Shape {
            if let fields = object as? [String: Any] { return .object(try fields.mapValues { try shape($0) }) }
            if let string = object as? String {
                if UUID(uuidString: string) != nil { return .uuid }
                return .literal(Array(try JSONEncoder().encode(string)))
            }
            if let number = object as? NSNumber { return number.int64Value < 0 ? .signed : .unsigned }
            throw Stop.invalid
        }
        return try shape(JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed))
    }

    private static func makeShape() throws -> Shape {
        let errors: [GuesthouseError] = [
            .unsupportedHost(.notAppleSilicon), .unsupportedHost(.unknownArchitecture),
            .unsupportedHost(.macOSTooOld), .unsupportedHost(.insufficientMemory(foundBytes: 0, minimumBytes: 0)),
            .insufficientDisk(requiredBytes: 0, availableBytes: 0),
            .downloadVerificationFailed(check: .digest), .downloadVerificationFailed(check: .signature),
            .downloadVerificationFailed(check: .size), .runtimeMissing, .runtimeIncompatible,
            .guestNotReachable(EnvironmentID()), .hostKeyChanged(EnvironmentID()),
            .credentialsLocked(.hostKeychain), .credentialsLocked(.guestKeychain),
            .loginExpired(.github), .loginExpired(.codex), .xcodeComponentsIncomplete,
            .vmSlotUnavailable(maximum: -1), .operationOutcomeUnknown(OperationID()), .unauthorizedCaller,
            .protocolMismatch(client: -1, service: -1), .canceled,
            .invalidRuntimeReply(.malformed), .invalidRuntimeReply(.oversized)
        ] + GuesthouseError.Tool.allCases.map { .toolMismatch(tool: $0) }
          + GuesthouseError.InvalidRequestReason.allCases.map { .invalidRequest($0) }
        let outcomes: [JournalRecord.Outcome] = [.started, .completed, .unknown, .notApplied]
            + ProvisioningStage.allCases.map { .checkpoint($0) } + errors.map { .failed($0) }
        return .object([
            "format": .literal(Array(String(JournalRecord.currentFormat).utf8)),
            "id": .uuid, "environmentID": .uuid, "timestamp": .date,
            "operation": .choice(try JournalOperation.allCases.map { try encodedShape($0) }),
            "outcome": .choice(try outcomes.map { try encodedShape($0) })
        ])
    }
}
