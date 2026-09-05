import Foundation
import Testing
@testable import GuesthouseCore

struct ObservationRedactionProvenanceTests {
    @Test func initialTruncationReplacementReportsRedaction() {
        let input = "AB12-CD34" + String(repeating: "\u{301}", count: 800)
        let result = GuesthouseError.sanitizeReporting(input, limit: 256)
        #expect(result.value == "[redacted:truncated]")
        #expect(result.redacted)
        // The observation's independent raw-window guard also rejects this input.
        #expect(ObservedTuple(codexCLIVersion: input).sanitizedForWire().codexCLIVersion == nil)
    }

    @Test(arguments: [
        "\u{1B}]AB12-CD34\u{07}", "\u{9D}AB12-CD34\u{9C}",
        "\u{1B}PAB12-CD34\u{1B}\\", "\u{90}AB12-CD34\u{9C}",
        "\u{1B}_AB12-CD34\u{1B}\\", "\u{9F}AB12-CD34\u{9C}",
        "\u{1B}^AB12-CD34\u{1B}\\", "\u{9E}AB12-CD34\u{9C}",
        "\u{1B}XAB12-CD34\u{1B}\\", "\u{98}AB12-CD34\u{9C}",
        "\u{1B}]AB12-CD34", "\u{1B}PAB12-CD34"
    ])
    func discardedControlPayloadCannotBecomeAnIdentity(sequence: String) throws {
        let input = "0.50.0 " + sequence
        let sanitized = GuesthouseError.sanitizeReporting(input, limit: 256)
        #expect(sanitized.redacted)
        #expect(!sanitized.value.contains("AB12-CD34"))
        var observation = ObservedTuple(codexCLIVersion: input)
        observation.codexCLICapabilities = ["normal", input]
        let status = EnvironmentStatus(environmentID: EnvironmentID(), vm: .stopped,
                                       readiness: .checking, observed: observation)
        #expect(status.observed.codexCLIVersion == nil)
        #expect(status.observed.codexCLICapabilities == nil)
        let wire = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        #expect(!wire.contains("AB12-CD34"))
        #expect(!wire.contains(ObservedTuple.digest(of: input)))
    }

    @Test(arguments: ["\u{1B}[31m", "\u{9B}0m", "\u{1B}(B"])
    func ordinaryTerminalStylingRetainsExactObservationIdentity(sequence: String) {
        let input = "0.50.0" + sequence
        let result = GuesthouseError.sanitizeReporting(input, limit: 256)
        #expect(result.value == "0.50.0")
        #expect(!result.redacted)
        #expect(ObservedTuple(codexCLIVersion: input).sanitizedForWire()
            .codexCLIVersion == "0.50.0 [exact:\(ObservedTuple.digest(of: input))]")
    }

    @Test func tighterIdentityDisplayBoundAlsoHonorsRedactionProvenance() {
        let input = String(repeating: "a", count: 400) + String(repeating: "\u{301}", count: 350)
        #expect(!GuesthouseError.sanitizeReporting(input, limit: 256).redacted)
        #expect(GuesthouseError.sanitizeReporting(input, limit: 256 - ObservedTuple.identitySuffixLength).redacted)
        #expect(ObservedTuple.bounded(input, limit: 256) == nil)
    }
}
