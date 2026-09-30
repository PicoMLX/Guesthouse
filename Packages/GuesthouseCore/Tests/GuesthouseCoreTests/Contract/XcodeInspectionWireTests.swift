import Foundation
import Testing
import XPC
@testable import GuesthouseCore

@Suite struct XcodeInspectionWireTests {
    @Test func inspectionRequestUsesTheExistingBoundedHandoff() throws {
        let handoff = FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: "Xcode.app", expectedBundleIdentifier: "com.apple.dt.Xcode")
        let envelope = RuntimeRequestEnvelope(request: .inspectXcode(handoff))
        #expect(try RequestValidator.decode(JSONEncoder().encode(envelope)) == envelope)
        #expect(envelope.request.caseName == "inspectXcode")
        let invalid = RuntimeRequestEnvelope(request: .inspectXcode(.init(kind: .fileDescriptor(token: UUID()), displayName: "../Xcode.app")))
        #expect(throws: RequestValidationError.invalidDisplayName) { try RequestValidator.validate(invalid) }
        let oversized = RuntimeRequestEnvelope(request: .inspectXcode(.init(kind: .securityScopedBookmark(Data(repeating: 0, count: 16_385)), displayName: "Xcode.app")))
        #expect(throws: RequestValidationError.self) { try RequestValidator.validate(oversized) }
    }

    @Test func candidatesAndSelectionFailuresStayTypedAndOutOfDiagnostics() throws {
        let candidate = try #require(XcodeCandidate(version: SemanticVersion("26.6")!, build: "17F113"))
        let results = [XcodeSelectionResult.candidate(candidate)] + XcodeSelectionFailure.allCases.map { .rejected($0) }
        for result in results {
            let envelope = RuntimeEventEnvelope(event: .xcodeSelection(result))
            #expect(try RuntimeEventEnvelope.decode(envelope.encoded()) == envelope)
            #expect(envelope.event.diagnosticEvent == nil)
            #expect(envelope.event.caseName == "xcodeSelection")
        }
    }

    @Test func optInFrameGrammarStillRefusesUnknownOrWrongTypeGrants() throws {
        for key in ["selectedDirectory", "anotherField"] {
            var frame = try RawRuntimeFrame.encode(Data("{}".utf8), protocolVersion: 15)
            frame[key] = Int64(0)
            #expect(throws: RawRuntimeFrame.Failure.malformed) {
                try RawRuntimeFrame.payload(frame, expectedVersion: 15, allowSelectedDirectory: true)
            }
        }
        var foreign = try RawRuntimeFrame.encode(Data("unknown future bytes".utf8), protocolVersion: 14)
        foreign["selectedDirectory"] = Int64(0)
        #expect(throws: RawRuntimeFrame.Failure.protocolMismatch(received: 14)) {
            try RawRuntimeFrame.payload(foreign, expectedVersion: 15, allowSelectedDirectory: true)
        }
    }
}
