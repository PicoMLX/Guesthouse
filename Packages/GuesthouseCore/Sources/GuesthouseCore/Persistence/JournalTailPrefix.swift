import Foundation

/// Recognizes prefixes of closed journal encoder shapes, not arbitrary broken JSON.
/// Framing proves neither write origin nor mutation outcome. Unknown tails remain evidence.
struct JournalTailPrefix {
    private enum Identity: Hashable, Sendable { case operation, environment }
    private indirect enum Shape: Sendable {
        case object([String: Shape]), choice([Shape]), literal([UInt8]), uuid(Identity?), unsigned, signed, date

        /// Upper bound for compact encoder output, including every delimiter. Keys in
        /// this closed schema are unescaped ASCII; UUIDs include their two quotes.
        var maximumByteCount: Int {
            switch self {
            case .object(let fields):
                return 2 + max(0, fields.count - 1) + fields.reduce(0) {
                    $0 + $1.key.utf8.count + 3 + $1.value.maximumByteCount
                }
            case .choice(let choices): return choices.map(\.maximumByteCount).max() ?? 0
            case .literal(let bytes): return bytes.count
            case .uuid: return 38
            case .unsigned, .signed: return 20 // UInt64.max and Int64.min
            case .date: return 32 // conservative bound for finite binary64's shortest spelling
            }
        }

        var minimumByteCount: Int {
            switch self {
            case .object(let fields):
                return 2 + max(0, fields.count - 1) + fields.reduce(0) {
                    $0 + $1.key.utf8.count + 3 + $1.value.minimumByteCount
                }
            case .choice(let choices): return choices.map(\.minimumByteCount).min() ?? 0
            case .literal(let bytes): return bytes.count
            case .uuid: return 38
            case .unsigned, .signed, .date: return 1
            }
        }
    }
    private enum Stop: Error { case incomplete(additionalBytes: Int), invalid }
    /// One recognition call owns this memo. Parser copies and history candidates share
    /// only token-derived witnesses, never identities, history or capacity decisions.
    private final class DateCompletions {
        private enum Witness { case missing, found(Int) }
        private var witnesses: [String: Witness] = [:]
        private(set) var searches = 0

        func additionalBytes(_ token: String) -> Int? {
            if let witness = witnesses[token] {
                if case .found(let bytes) = witness { return bytes }
                return nil
            }
            searches += 1
            let additional = JournalTailPrefix.dateCompletionBytes(token)
            witnesses[token] = additional.map(Witness.found) ?? .missing
            return additional
        }
    }
    private static let shape: Shape? = try? makeShape()
    private static let maximumRecordByteCount = shape?.maximumByteCount
    private static let startShape: Shape? = try? makeShape(starting: true)
    private static let continuationShapes = Dictionary(uniqueKeysWithValues: JournalOperation.allCases.map {
        ($0, try? makeShape(operation: $0, starting: false))
    })
    private let bytes: [UInt8]
    private var index = 0
    private var identities: [Identity: [UInt8]] = [:]
    private var excluded: [Identity: Set<[UInt8]>] = [:]
    private let dateCompletions: DateCompletions

    static func accepts(_ data: Data) -> Bool {
        guard let bytes = boundedBytes(data) else { return false }
        return accepts(bytes, shape: shape)
    }

    /// A tail must have some completion that the already-staged history could append.
    /// New starts exclude all used operation IDs and currently occupied environments;
    /// continuations bind every identity and the operation to an unresolved record.
    static func accepts(_ data: Data, following history: JournalHistory,
                        maximumRecordBytes: Int = .max) -> Bool {
        evaluate(data, following: history, maximumRecordBytes: maximumRecordBytes).accepted
    }

    /// Internal work-count evidence avoids elapsed-time assertions on busy CI workers.
    static func evaluate(_ data: Data, following history: JournalHistory,
                         maximumRecordBytes: Int = .max) -> (accepted: Bool, dateCompletionSearches: Int) {
        let memo = DateCompletions()
        let accepted = accepts(data, following: history, maximumRecordBytes: maximumRecordBytes,
                               dateCompletions: memo)
        return (accepted, memo.searches)
    }

    private static func accepts(_ data: Data, following history: JournalHistory,
                                maximumRecordBytes: Int, dateCompletions: DateCompletions) -> Bool {
        // Reject impossible lengths before enumerating history. ASCII validation and
        // materialization happen once, not once per unresolved operation. Candidate
        // matching may still scale with history, but never with an arbitrary file-sized tail.
        guard let input = boundedBytes(data) else { return false }
        func bytes<T: Encodable>(_ value: T) -> [UInt8] {
            Array((try? JSONEncoder().encode(value)) ?? Data())
        }
        if accepts(input, shape: startShape, maximumRecordBytes: maximumRecordBytes, excluded: [
            .operation: Set(history.records.map { bytes($0.id) }),
            .environment: Set(history.inFlight.values.map { bytes($0.environmentID) })
        ], dateCompletions: dateCompletions) { return true }
        for record in history.inFlight.values {
            if accepts(input, shape: continuationShapes[record.operation] ?? nil,
                       maximumRecordBytes: maximumRecordBytes, identities: [
                .operation: bytes(record.id), .environment: bytes(record.environmentID)
            ], dateCompletions: dateCompletions) { return true }
        }
        return false
    }

    private static func boundedBytes(_ data: Data) -> [UInt8]? {
        guard let maximumRecordByteCount, data.count <= maximumRecordByteCount,
              data.first == 123, data.allSatisfy({ $0 < 128 && $0 != 0 }) else { return nil }
        return Array(data)
    }

    private static func accepts(_ bytes: [UInt8], shape: Shape?,
                                maximumRecordBytes: Int = .max,
                                identities: [Identity: [UInt8]] = [:],
                                excluded: [Identity: Set<[UInt8]>] = [:],
                                dateCompletions: DateCompletions = DateCompletions()) -> Bool {
        guard let shape else { return false }
        var parser = Self(bytes: bytes, identities: identities, excluded: excluded,
                          dateCompletions: dateCompletions)
        do { try parser.value(shape); return false }
        catch Stop.incomplete(let additional) {
            return maximumRecordBytes >= bytes.count && additional <= maximumRecordBytes - bytes.count
        }
        catch { return false }
    }

    private mutating func peek() throws -> UInt8 {
        // The journal uses compact JSONEncoder output. Whitespace is not an omitted
        // delimiter: preserving it as corruption avoids erasing a damaged final record.
        guard index < bytes.count else { throw Stop.incomplete(additionalBytes: 1) }
        return bytes[index]
    }

    private mutating func take(_ byte: UInt8) throws {
        guard try peek() == byte else { throw Stop.invalid }
        index += 1
    }

    private mutating func literal(_ expected: [UInt8]) throws {
        for (offset, byte) in expected.enumerated() {
            guard index < bytes.count else { throw Stop.incomplete(additionalBytes: expected.count - offset) }
            guard bytes[index] == byte else { throw Stop.invalid }
            index += 1
        }
    }

    private mutating func value(_ shape: Shape) throws {
        guard index < bytes.count else { throw Stop.incomplete(additionalBytes: shape.minimumByteCount) }
        switch shape {
        case .object(let fields):
            try take(123)
            var remaining = fields
            if remaining.isEmpty { try take(125); return }
            while true {
                // Encoder keys are closed ASCII. Validate interrupted keys as well as full keys.
                var matched: String?
                var missing: Int?
                for key in remaining.keys {
                    var candidate = self
                    do {
                        try candidate.literal(Array(("\"" + key + "\"").utf8))
                        matched = key
                        index = candidate.index
                        break
                    } catch Stop.incomplete(let additional) {
                        var afterKey = remaining
                        let field = afterKey.removeValue(forKey: key)!
                        let completion = additional + 1 + field.minimumByteCount + Self.objectRemainder(afterKey)
                        missing = min(missing ?? completion, completion)
                    }
                    catch {}
                }
                guard let key = matched, let field = remaining.removeValue(forKey: key) else {
                    if let missing { throw Stop.incomplete(additionalBytes: missing) }
                    throw Stop.invalid
                }
                do { try take(58) }
                catch Stop.incomplete(let additional) {
                    throw Stop.incomplete(additionalBytes: additional + field.minimumByteCount + Self.objectRemainder(remaining))
                }
                do { try value(field) }
                catch Stop.incomplete(let additional) {
                    throw Stop.incomplete(additionalBytes: additional + Self.objectRemainder(remaining))
                }
                guard index < bytes.count else {
                    throw Stop.incomplete(additionalBytes: Self.objectRemainder(remaining))
                }
                let separator = try peek()
                index += 1
                if separator == 125 {
                    guard remaining.isEmpty else { throw Stop.invalid }
                    return
                }
                guard separator == 44, !remaining.isEmpty else { throw Stop.invalid }
            }
        case .choice(let choices):
            var missing: Int?
            for choice in choices {
                var candidate = self
                do { try candidate.value(choice); self = candidate; return }
                catch Stop.incomplete(let additional) { missing = min(missing ?? additional, additional) }
                catch {}
            }
            if let missing { throw Stop.incomplete(additionalBytes: missing) }
            throw Stop.invalid
        case .literal(let expected): try literal(expected)
        case .uuid(let identity):
            _ = try peek()
            let start = index
            if let identity, let forbidden = excluded[identity] {
                // Even a cut UUID can have exhausted all of its possible completions.
                let prefix = Array(bytes[start..<min(bytes.count, start + 38)])
                let matches = forbidden.filter { $0.starts(with: prefix) }.count
                var possibilities = 1
                for position in prefix.count..<38 where position != 0 && position != 37
                    && ![9, 14, 19, 24].contains(position) {
                    if possibilities > matches { break }
                    possibilities *= 16 // bounded by the finite forbidden-set size
                }
                guard matches < possibilities else { throw Stop.invalid }
            }
            for position in 0..<38 {
                guard index < bytes.count else { throw Stop.incomplete(additionalBytes: 38 - position) }
                let byte = bytes[index]
                if let identity, let previous = identities[identity] {
                    guard byte == previous[position] else { throw Stop.invalid }
                }
                if position == 0 || position == 37 {
                    guard byte == 34 else { throw Stop.invalid }
                } else if [9, 14, 19, 24].contains(position) {
                    guard byte == 45 else { throw Stop.invalid }
                } else {
                    guard (48...57).contains(byte) || (65...70).contains(byte) else { throw Stop.invalid }
                }
                index += 1
            }
            if let identity { identities[identity] = Array(bytes[start..<index]) }
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
                if token == "-", index == bytes.count { throw Stop.incomplete(additionalBytes: 1) }
                guard token.range(of: integer, options: .regularExpression) != nil,
                      let number = Int(token), String(number) == token else { throw Stop.invalid }
            default:
                if Self.canonicalDate(token) != token {
                    guard index == bytes.count, let additional = dateCompletions.additionalBytes(token) else { throw Stop.invalid }
                    throw Stop.incomplete(additionalBytes: additional)
                }
            }
        }
    }

    /// Closing brace plus each still-unwritten member and its leading comma.
    private static func objectRemainder(_ fields: [String: Shape]) -> Int {
        1 + fields.reduce(0) { $0 + $1.key.utf8.count + 4 + $1.value.minimumByteCount }
    }

    private static func canonicalDate(_ token: String) -> String? {
        guard let number = Double(token), number.isFinite,
              let data = try? JSONEncoder().encode(Date(timeIntervalSinceReferenceDate: number)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func dateCompletionBytes(_ token: String) -> Int? {
        // An EOF token may end inside a number: 1.00 is a real prefix of 1.001.
        // Require an encoder-produced witness, not just a permissive decimal regex.
        // Binary64's shortest finite spelling fits within 32 ASCII bytes.
        guard token.utf8.count < 32 else { return nil }
        var shortest: Int?
        func consider(_ candidate: String) {
            guard let encoded = canonicalDate(candidate), encoded.hasPrefix(token) else { return }
            let additional = encoded.utf8.count - token.utf8.count
            shortest = min(shortest ?? additional, additional)
        }
        for digit in 0...9 {
            consider(token + String(digit))
            if shortest == 1 { return shortest }
        }
        // Rounding can require a further mantissa digit AND an exponent. Checking either
        // extension alone misses genuine prefixes of e.g. 4.6728494007670807e+303.
        if let marker = token.firstIndex(of: "e") {
            // Enumerate whole exponents, not integer suffixes: after e+3 the
            // completion of e+303 is "03", which String(3) cannot produce.
            let mantissa = String(token[...marker])
            for exponent in 0...324 {
                for sign in ["", "-", "+"] {
                    consider(mantissa + sign + String(exponent))
                    if shortest == 1 { return shortest }
                }
            }
            return shortest
        }
        let markers = ["e"] + (0...9).map { String($0) + "e" }
        for marker in markers {
            for exponent in 0...324 {
                for sign in ["", "-", "+"] {
                    consider(token + marker + sign + String(exponent))
                    if shortest == 1 { return shortest }
                }
            }
        }
        return shortest
    }

    /// Derive enum keys/associated labels from Codable, without a second wire-format schema.
    /// Numeric and UUID leaves vary; every other token must match an encoded sample.
    private static func encodedShape<T: Encodable>(_ value: T, identity: Identity? = nil) throws -> Shape {
        func shape(_ object: Any) throws -> Shape {
            if let fields = object as? [String: Any] { return .object(try fields.mapValues { try shape($0) }) }
            if let string = object as? String {
                if UUID(uuidString: string) != nil { return .uuid(identity) }
                return .literal(Array(try JSONEncoder().encode(string)))
            }
            if let number = object as? NSNumber { return number.int64Value < 0 ? .signed : .unsigned }
            throw Stop.invalid
        }
        return try shape(JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed))
    }

    private static func makeShape(operation: JournalOperation? = nil, starting: Bool? = nil) throws -> Shape {
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
        var outcomes: [JournalRecord.Outcome] = [.started, .completed, .unknown, .notApplied]
            + errors.map { .failed($0) }
        if starting == true { outcomes = [.started] }
        if starting == false { outcomes.removeFirst() }
        func record(operation: Shape, outcome: Shape) -> Shape {
            .object([
                "format": .literal(Array(String(JournalRecord.currentFormat).utf8)),
                "id": .uuid(.operation), "environmentID": .uuid(.environment), "timestamp": .date,
                "operation": operation, "outcome": outcome
            ])
        }
        let ordinary = record(
            operation: .choice(try (operation.map { [$0] } ?? JournalOperation.allCases).map { try encodedShape($0) }),
            outcome: .choice(try outcomes.map { outcome in
                let identity: Identity?
                switch outcome {
                case .failed(.operationOutcomeUnknown): identity = .operation
                case .failed(.guestNotReachable), .failed(.hostKeyChanged): identity = .environment
                default: identity = nil
                }
                return try encodedShape(outcome, identity: identity)
            })
        )
        // A possible encoder continuation must also satisfy JournalRecord's cross-field
        // contract. Checkpoints bind both stages; error identities bind byte-for-byte in
        // either field order, including an interruption inside the second UUID.
        let stages = ProvisioningStage.allCases.filter {
            starting != true && (operation == nil || operation == .provision(stage: $0))
        }
        let checkpoints = try stages.map { stage in
            record(operation: try encodedShape(JournalOperation.provision(stage: stage)),
                   outcome: try encodedShape(JournalRecord.Outcome.checkpoint(stage)))
        }
        return .choice([ordinary] + checkpoints)
    }
}
