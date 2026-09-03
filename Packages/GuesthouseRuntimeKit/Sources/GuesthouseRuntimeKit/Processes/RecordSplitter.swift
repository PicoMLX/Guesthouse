import Foundation

/// Splits a byte stream into records for redaction: a record ends at `\n` or `\r` (a `\r\n`
/// pair is one ending, even across two reads), or when it reaches `maximumRecordBytes`.
///
/// A forced split happens at the last ASCII separator inside the final `splitSearchBytes` of
/// the record when there is one, so a token (which contains no separator) is never cut in
/// two; otherwise at a UTF-8 scalar boundary, so no scalar is ever torn.
struct RecordSplitter {
    static let maximumRecordBytes = 64 << 10
    static let splitSearchBytes = 1 << 10

    private var pending = Data()
    private var previousWasCarriageReturn = false

    /// Records completed by `data`.
    mutating func consume(_ data: Data) -> [Data] {
        pending.append(data)
        var records: [Data] = []
        var start = pending.startIndex
        var index = start
        while index < pending.endIndex {
            let byte = pending[index]
            if byte == 0x0A || byte == 0x0D {
                let emptyAfterCarriageReturn = byte == 0x0A && previousWasCarriageReturn && start == index
                if !emptyAfterCarriageReturn { records.append(pending[start..<index]) }
                start = index + 1
                previousWasCarriageReturn = byte == 0x0D
                index += 1
            } else {
                previousWasCarriageReturn = false
                if index - start + 1 >= Self.maximumRecordBytes {
                    let cut = Self.forcedCut(in: pending, from: start, through: index)
                    records.append(pending[start..<cut])
                    start = cut
                    index = cut
                } else {
                    index += 1
                }
            }
        }
        pending = Data(pending[start...])
        return records
    }

    /// Whatever remains without an ending, at end of stream.
    mutating func flush() -> Data? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : pending
    }

    /// The index to cut a record that reached the limit: after the last separator in the search
    /// window, else at the last UTF-8 scalar boundary at or before the limit.
    static func forcedCut(in data: Data, from start: Data.Index, through last: Data.Index) -> Data.Index {
        let windowStart = max(start + 1, last - splitSearchBytes)
        var index = last
        while index >= windowStart {
            if isSeparator(data[index]) { return index + 1 }
            index -= 1
        }
        var boundary = last + 1
        while boundary > start + 1, boundary < data.endIndex, data[boundary] & 0xC0 == 0x80 {
            boundary -= 1
        }
        return boundary
    }

    /// ASCII whitespace or punctuation that never occurs inside a credential token.
    static func isSeparator(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x20, 0x09, 0x2C, 0x3B, 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x22, 0x27, 0x3C, 0x3E: true
        default: false
        }
    }
}
