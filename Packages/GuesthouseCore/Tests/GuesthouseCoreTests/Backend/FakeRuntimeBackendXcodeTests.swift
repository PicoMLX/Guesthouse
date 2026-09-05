import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct FakeRuntimeBackendXcodeTests {
    @Test func importXcodeRepliesWithACandidateOrASelectionError() async throws {
        let backend = FakeRuntimeBackend()
        let handoff = FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: "Xcode.app")
        var names: [String] = []
        for try await event in backend.send(.importXcode(EnvironmentID(), handoff)) { names.append(event.caseName) }
        #expect(names == ["failed"])
        let candidate = XcodeCandidate(version: "26.6", build: "17F113", path: "/Applications/Xcode.app", sizeEstimateBytes: 30_000_000_000)
        await backend.setXcodeCandidate(candidate)
        var replies: [RuntimeEvent] = []
        for try await event in backend.send(.importXcode(EnvironmentID(), handoff)) { replies.append(event) }
        #expect(replies == [.xcodeCandidate(candidate)])
    }
}
