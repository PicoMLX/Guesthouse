import Foundation
import Testing
@testable import GuesthouseCore

struct SanitizedTextPolicyTests {
    @Test func standaloneValueClampsAndSanitizesBeforeEncoding() throws {
        let value = SanitizedText("password: opaqueValue", limit: .max)
        #expect(!value.value.contains("opaqueValue"))
        #expect(!String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains("opaqueValue"))
        #expect(SanitizedText("hello", limit: .min).value == "h…")
        #expect(SanitizedText(String(repeating: "x", count: 5_000), limit: .max).value.unicodeScalars.count == SanitizedText.maximumLimit + 1)
    }

    @Test func standaloneDecodeReappliesTheSamePolicy() throws {
        let input = Data("\"password: opaqueValue\"".utf8)
        let decoded = try JSONDecoder().decode(SanitizedText.self, from: input)
        #expect(decoded == SanitizedText("password: opaqueValue", limit: .max))
        #expect(!decoded.value.contains("opaqueValue"))
    }
}
