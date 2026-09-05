import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RedactedLinesDecodingTests {
    @Test(arguments: [
        ["-----BEGIN PRIVATE KEY-----", "syntheticKeyBody", "-----END PRIVATE KEY-----", "Finished"],
        ["PuTTY-User-Key-File-3: ssh-rsa", "Private-Lines: 1", "c3ludGhldGlj", "Private-MAC: " + String(repeating: "a", count: 64), "Finished"],
        ["password: \"syntheticFirst", "syntheticSecond\"", "Finished"],
    ])
    func batchesPreservePrivateKeyAndQuotedValueState(input: [String]) throws {
        let encoded = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(RedactedLines.self, from: encoded)
        #expect(decoded.lines.count == input.count)
        #expect(decoded.lines.last?.text == "Finished")
        #expect(!decoded.lines.map(\.text).joined().contains("synthetic"))
        #expect(!decoded.lines.map(\.text).joined().contains("c3ludGhldGlj"))
        #expect(try JSONDecoder().decode(RedactedLines.self, from: JSONEncoder().encode(decoded)) == decoded)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([RedactedLine].self, from: encoded) }
    }

    @Test func nestedRecordsCannotBypassTheBatchBoundary() throws {
        struct Record: Decodable { let line: RedactedLine }
        let input = #"[{"line":"-----BEGIN PRIVATE KEY-----"},{"line":"syntheticKeyBody"}]"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([Record].self, from: Data(input.utf8)) }
    }

    @Test func batchDecodingStillConcealsContextFreeDeviceCodes() throws {
        let input = ["prefix\u{1B}[31mAB12-CD34", "Finished"]
        let decoded = try JSONDecoder().decode(RedactedLines.self, from: JSONEncoder().encode(input))
        #expect(!decoded.lines[0].text.contains("AB12-CD34"))
        #expect(decoded.lines[1].text == "Finished")
    }

    @Test(arguments: ["\n", "\r", "\r\n"])
    func batchesRejectAmbiguousEmbeddedPhysicalFraming(separator: String) throws {
        let encoded = try JSONEncoder().encode(["before" + separator + "after"])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RedactedLines.self, from: encoded) }
    }

    @Test func emptyBatchesRemainEmpty() throws {
        #expect(try JSONDecoder().decode(RedactedLines.self, from: Data("[]".utf8)).lines.isEmpty)
    }
}
