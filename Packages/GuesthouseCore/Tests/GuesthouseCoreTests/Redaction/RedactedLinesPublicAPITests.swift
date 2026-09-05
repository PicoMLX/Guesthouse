import Foundation
import GuesthouseCore
import Testing

@Test func decodedLineBatchesAreAvailableWithoutTestableImport() throws {
    let input = Data(#"["password:","syntheticValue","Finished"]"#.utf8)
    let batch = try JSONDecoder().decode(RedactedLines.self, from: input)
    #expect(batch.lines.map(\.text) == ["password: [redacted:secret]", "[redacted:secret]", "Finished"])
}
