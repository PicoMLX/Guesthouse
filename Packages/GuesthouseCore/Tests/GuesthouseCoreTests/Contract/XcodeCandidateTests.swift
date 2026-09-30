import Foundation
import GuesthouseCore
import Testing

@Suite struct XcodeCandidateTests {
    @Test func candidateRoundTripsWithoutPathOrReadiness() throws {
        let value = try #require(XcodeCandidate(version: SemanticVersion("26.6")!, build: "17F113", sizeEstimateBytes: UInt64.max))
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(XcodeCandidate.self, from: data) == value)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "build", "sizeEstimateBytes"])
        #expect(XcodeCandidate(version: SemanticVersion("26.6")!, build: "17F113")?.sizeEstimateBytes == nil)
    }

    @Test(arguments: ["", "bad build", "secret=value", "17F113\n", String(repeating: "1", count: 257)])
    func invalidBuildIsRefusedWithoutSanitizing(build: String) throws {
        #expect(XcodeCandidate(version: SemanticVersion("26.6")!, build: build) == nil)
        let data = try JSONSerialization.data(withJSONObject: ["version": "26.6", "build": build])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(XcodeCandidate.self, from: data) }
    }

    @Test(arguments: XcodeSelectionFailure.allCases) func selectionFailuresUseClosedMessagesAndRecovery(failure: XcodeSelectionFailure) throws {
        #expect(!failure.userMessage.isEmpty)
        #expect(failure.recoveryActions == [.reviewRequest, .cancel])
        #expect(try JSONDecoder().decode(XcodeSelectionFailure.self, from: JSONEncoder().encode(failure)) == failure)
    }
}
