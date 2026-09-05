import Foundation

/// Splits a byte stream into records for redaction: a record ends at `\n` or `\r` (a `\r\n`
/// pair is one ending, even across two reads), or when it reaches `maximumRecordBytes`.
///
/// A forced split happens at the last ASCII separator in the record when there is one, so a
/// token (which contains no separator) is never cut in two however long it is; otherwise at a
/// UTF-8 scalar boundary, so no scalar is ever torn, and a scalar whose remaining bytes have
/// not arrived yet is held for the next read.
///
/// The separator begins the record that follows it rather than ending the one before, so a
/// value cut away from the label that introduced it still reads as an indented continuation
/// and the redactor removes it. Where the cut cannot fall on whitespace the shape alone is not
/// enough, so each record also says whether it continues the previous one and the redactor
/// carries its context across regardless of which byte the cut landed on.
struct RecordSplitter {
    static let maximumRecordBytes = 64 << 10

    /// One record, and whether it is the tail of a line too long to keep whole rather than a
    /// line of its own.
    struct Record: Hashable, Sendable {
        var bytes: Data
        var continuesPrevious: Bool

        init(_ bytes: Data, continuesPrevious: Bool = false) {
            self.bytes = bytes
            self.continuesPrevious = continuesPrevious
        }
    }

    private var pending = Data()
    private var previousWasCarriageReturn = false
    /// Whether what is pending is the tail of a record already cut once.
    private var pendingContinues = false

    /// Records completed by `data`.
    mutating func consume(_ data: Data) -> [Record] {
        pending.append(data)
        var records: [Record] = []
        var start = pending.startIndex
        var index = start
        var continues = pendingContinues
        while index < pending.endIndex {
            let byte = pending[index]
            if byte == 0x0A || byte == 0x0D {
                let emptyAfterCarriageReturn = byte == 0x0A && previousWasCarriageReturn && start == index
                if !emptyAfterCarriageReturn { records.append(Record(pending[start..<index], continuesPrevious: continues)) }
                start = index + 1
                continues = false
                previousWasCarriageReturn = byte == 0x0D
                index += 1
            } else {
                previousWasCarriageReturn = false
                if index - start + 1 >= Self.maximumRecordBytes {
                    let cut = Self.forcedCut(in: pending, from: start, through: index)
                    records.append(Record(pending[start..<cut], continuesPrevious: continues))
                    // What follows the cut is the rest of the same line, whatever byte the cut
                    // fell on: only a real line ending starts a record that stands alone.
                    continues = true
                    start = cut
                    index = cut
                } else {
                    index += 1
                }
            }
        }
        pending = Data(pending[start...])
        pendingContinues = continues
        return records
    }

    /// Whatever remains without an ending, at end of stream.
    mutating func flush() -> Record? {
        defer { pending = Data(); pendingContinues = false }
        return pending.isEmpty ? nil : Record(pending, continuesPrevious: pendingContinues)
    }

    /// The index to cut a record that reached the limit: at the last separator in the record,
    /// which then leads the next record, else at the last UTF-8 scalar boundary at or before
    /// the limit.
    static func forcedCut(in data: Data, from start: Data.Index, through last: Data.Index) -> Data.Index {
        var index = last
        while index > start {
            // The separator goes with what follows it: a header value torn from its label is
            // then still a folded continuation, and is redacted as one.
            if isSeparator(data[index]) { return index }
            index -= 1
        }
        // No separator anywhere in the record. The cut would then fall wherever the limit did,
        // which can be inside a credential: `/`, `:`, `?`, and `=` are not separators, so a
        // long URL ending in `.../ghp_…` has none, and neither half of a token cut in two
        // matches any rule — the first is too short for the pattern and the second has lost
        // the prefix that names it. The run of token characters the limit landed in is
        // therefore kept whole and leads the next record, where the start of the record is the
        // boundary every token rule needs in front of a token, and what is left ends with the
        // delimiter that introduced it, which is what arms the label rules.
        let horizon = max(start + 1, last + 1 - maximumTokenCandidateBytes)
        var candidate = last + 1
        while candidate > horizon, isTokenByte(data[candidate - 1]) { candidate -= 1 }
        // Only when the whole run fits: a run longer than a credential is not one, and cutting
        // the record down further to keep it whole would cost more than it protects. `data`
        // is ASCII at the cut, which is a scalar boundary by construction.
        if candidate <= last, candidate > horizon { return candidate }
        var boundary = last + 1
        while boundary > start + 1, boundary < data.endIndex, data[boundary] & 0xC0 == 0x80 {
            boundary -= 1
        }
        if boundary == data.endIndex {
            // The limit fell on the end of what has arrived: an unfinished scalar there is
            // kept back, so its continuation bytes in the next read complete it.
            var lead = boundary - 1
            while lead > start, data[lead] & 0xC0 == 0x80 { lead -= 1 }
            if boundary - lead < scalarLength(leadByte: data[lead]) { boundary = lead }
        }
        return max(boundary, start + 1)
    }

    static func scalarLength(leadByte: UInt8) -> Int {
        switch leadByte {
        case 0x00...0x7F: 1
        case 0xC0...0xDF: 2
        case 0xE0...0xEF: 3
        case 0xF0...0xF7: 4
        default: 1
        }
    }

    /// How far back a forced cut looks for the start of the run of token characters it landed
    /// in. Every credential the redaction layer knows is far shorter than this; a run longer
    /// than it is not one.
    static let maximumTokenCandidateBytes = 4 << 10

    /// The characters credentials are spelled with: letters, digits, and the `-`, `.`, and `_`
    /// that join a token's parts. A run of them is what a forced cut keeps whole.
    static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F: true
        default: false
        }
    }

    /// ASCII whitespace or punctuation that never occurs inside a credential token.
    static func isSeparator(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x20, 0x09, 0x2C, 0x3B, 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x22, 0x27, 0x3C, 0x3E: true
        default: false
        }
    }
}
