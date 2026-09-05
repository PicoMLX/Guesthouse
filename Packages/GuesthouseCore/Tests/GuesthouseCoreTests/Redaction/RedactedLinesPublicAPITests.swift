import Foundation
import GuesthouseCore
import Testing

@Test(arguments: ["\n", "\r\n", "\r"], ["run --password", "Authorization:", "password:", "Your code is:"])
func publicTypedLinesKeepContextAcrossRetainedTerminators(separator: String, label: String) {
    let redactor = Redactor()
    var state = Redactor.StreamState()
    _ = redactor.redact(line: label + separator, state: &state)
    #expect(!redactor.redact(line: "syntheticValue", state: &state).text.contains("syntheticValue"))
    let input = [label + separator, "syntheticValue" + separator, "[status] Finished"]
    #expect(!redactor.redact(lines: input).map(\.text).joined().contains("syntheticValue"))
    #expect(redactor.redact(lines: input).last?.text == "[status] Finished")
}

@Test(arguments: ["\n", "\r\n", "\r"])
func publicTypedRecordsSplitEmbeddedLinesWithoutInventingTrailingRecords(separator: String) {
    let redactor = Redactor()
    var state = Redactor.StreamState()
    #expect(redactor.redact(line: "before" + separator + "run --password" + separator, state: &state).text
        == "before" + separator + "run --password" + separator)
    #expect(redactor.redact(line: "syntheticValue", state: &state).text == "[redacted:secret]")
    state = .init()
    let key = ["PuTTY-User-Key-File-3: ssh-ed25519", "Private-Lines: 2", "AAAA", "BBBB",
        "Private-MAC: " + String(repeating: "a", count: 64)]
    for line in key {
        #expect(redactor.redact(line: line + separator, state: &state).text == "[redacted:private-key]" + separator)
    }
    #expect(redactor.redact(line: "Finished", state: &state).text == "Finished")
}

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
