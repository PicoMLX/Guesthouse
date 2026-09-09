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
                // Complete invalid JSON values are evidence, not torn encoder writes.
                guard (try? JSONSerialization.jsonObject(with: unterminated, options: .fragmentsAllowed)) == nil else {
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
}
