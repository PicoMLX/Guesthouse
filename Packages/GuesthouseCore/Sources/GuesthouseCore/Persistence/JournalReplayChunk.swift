import Foundation

/// Validates newly read journal bytes using the retained StateStore rules (MVP-PLAN.md §3).
/// This value performs no file IO, truncation, cache validation or durability work.
///
/// Input starts at a record boundary and extends through the observed end of the file,
/// not an arbitrary network/stream fragment. `following` contains only the previously
/// validated prefix. A subsequent read must supply any torn tail again from its first byte.
/// The runtime owns the file lock, version/identity checks, absolute offset and cache reset.
/// A failed construction exposes no partial result and never changes the supplied history.
public struct JournalReplayChunk: Sendable {
    public let history: JournalHistory
    /// Validated bytes in this input only, excluding torn bytes. A complete record without
    /// a newline counts its actual bytes, not an implied separator. Add this to the runtime's offset.
    public let validatedByteCount: Int
    public let truncatedTail: Bool
    /// A valid final record has no newline. Its next append needs the missing separator.
    public let unterminatedRecord: Bool

    public init(_ data: Data, following prefix: JournalHistory = JournalHistory()) throws(StateStoreError) {
        var history = prefix
        var byteCount = 0
        var truncatedTail = false
        var unterminatedRecord = false
        let decoder = JSONDecoder()
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var unterminated: Data.SubSequence?
        if let last = lines.last, last.isEmpty {
            lines.removeLast()
        } else if !lines.isEmpty {
            unterminated = lines.removeLast()
        }
        for line in lines {
            let number = history.records.count + 1
            // Empty lines mean missing record bytes, never ignorable whitespace.
            guard !line.isEmpty, let record = try Self.decode(line, number: number, using: decoder) else {
                throw .corruptJournal(line: number)
            }
            try Self.adopt(record, into: &history, number: number)
            byteCount += line.count + 1
        }
        if let unterminated {
            let number = history.records.count + 1
            if let record = try Self.decode(unterminated, number: number, using: decoder) {
                try Self.adopt(record, into: &history, number: number)
                byteCount += unterminated.count
                unterminatedRecord = true
            } else {
                // Only a prefix of the closed encoder shapes can authorize tail repair.
                // Malformed or complete-invalid bytes remain evidence, not missing bytes.
                guard JournalTailPrefix.accepts(unterminated) else {
                    throw .corruptJournal(line: number)
                }
                truncatedTail = true
            }
        }
        self.history = history
        validatedByteCount = byteCount
        self.truncatedTail = truncatedTail
        self.unterminatedRecord = unterminatedRecord
    }

    private static func adopt(_ record: JournalRecord, into history: inout JournalHistory, number: Int) throws(StateStoreError) {
        do { try history.append(record) }
        catch { throw .corruptJournal(line: number) }
    }

    private static func decode(_ line: Data.SubSequence, number: Int, using decoder: JSONDecoder) throws(StateStoreError) -> JournalRecord? {
        // Complete JSON with ambiguous envelope keys is evidence, never a torn write.
        // Validate grammar first so a genuinely incomplete final line retains tail handling.
        if (try? JSONSerialization.jsonObject(with: line, options: .fragmentsAllowed)) != nil {
            try requireUnambiguousMembers(in: line, number: number, using: decoder)
        }
        if let declared = try? decoder.decode(RecordFormat.self, from: line), !JournalRecord.canRead(declared.format) {
            // Positive but unsupported includes prototype format 1, not only newer releases.
            // Neither is safe to skip or truncate, even when this final line has no newline.
            guard declared.format > 0 else { throw .corruptJournal(line: number) }
            throw .unsupportedJournalFormat(line: number, format: declared.format)
        }
        return try? decoder.decode(JournalRecord.self, from: line)
    }

    private struct RecordFormat: Decodable {
        let format: Int
    }

    /// Foundation collapses duplicate members. Inspect original UTF-8 top-level keys,
    /// including escaped spellings, before either decoder can select a format value.
    private static func requireUnambiguousMembers(in data: Data, number: Int,
                                                using decoder: JSONDecoder) throws(StateStoreError) {
        guard String(data: data, encoding: .utf8) != nil, !data.contains(0) else {
            throw .corruptJournal(line: number)
        }
        let bytes = Array(data)
        var index = 0, depth = 0
        var keys: Set<String> = []
        while index < bytes.count {
            switch bytes[index] {
            case 123, 91: depth += 1
            case 125, 93: depth -= 1
            case 34:
                let start = index
                index += 1
                while index < bytes.count && bytes[index] != 34 {
                    if bytes[index] == 92 { index += 1 }
                    index += 1
                }
                guard index < bytes.count else { throw .corruptJournal(line: number) }
                if depth == 1 {
                    var next = index + 1
                    while next < bytes.count && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                    if next < bytes.count && bytes[next] == 58 {
                        guard let key = try? decoder.decode(String.self, from: Data(bytes[start...index])) else {
                            throw .corruptJournal(line: number)
                        }
                        guard keys.insert(key).inserted else { throw .corruptJournal(line: number) }
                    }
                }
            default: break
            }
            index += 1
        }
    }
}
