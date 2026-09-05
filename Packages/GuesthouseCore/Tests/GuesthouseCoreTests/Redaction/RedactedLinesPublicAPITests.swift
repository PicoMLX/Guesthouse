import Foundation
import GuesthouseCore
import Testing

@Test func outgoingBatchesCanBeConstructedAndRoundTrippedWithoutTestableImport() throws {
    let batch = try RedactedLines(redacting: ["password:", "syntheticValue", "Finished", "AB12-CD34"])
    let encoded = try JSONEncoder().encode(batch)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("synthetic"))
    #expect(batch.lines.last?.text == "[redacted:device-code]")
    #expect(try JSONDecoder().decode(RedactedLines.self, from: encoded) == batch)
    #expect(try RedactedLines(redacting: []).lines.isEmpty)
}

@Test(arguments: ["\n", "\r", "\r\n"])
func outgoingBatchesRejectEmbeddedPhysicalLineBoundaries(separator: String) {
    #expect(throws: RedactedLines.ValidationError.embeddedLineTerminator) {
        try RedactedLines(redacting: ["password:" + separator + "syntheticValue"])
    }
}

@Test(arguments: [2, 3, 4])
func outgoingBatchesKeepJWEContinuationWhenDotStartsNextRecord(count: Int) throws {
    let segments = ["eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0", "wrappedKey", "iv", "syntheticCiphertext", "syntheticTag"]
    let batch = try RedactedLines(redacting: [segments.prefix(count).joined(separator: "."),
        "." + segments.dropFirst(count).joined(separator: "."), "[status] Finished"])
    #expect(!batch.lines.map(\.text).joined().contains("synthetic"))
    #expect(batch.lines.last?.text == "[status] Finished")
}

@Test func decodedLineBatchesAreAvailableWithoutTestableImport() throws {
    let input = Data(#"["password:","syntheticValue","Finished"]"#.utf8)
    let batch = try JSONDecoder().decode(RedactedLines.self, from: input)
    #expect(batch.lines.map(\.text) == ["password: [redacted:secret]", "[redacted:secret]", "Finished"])
}
