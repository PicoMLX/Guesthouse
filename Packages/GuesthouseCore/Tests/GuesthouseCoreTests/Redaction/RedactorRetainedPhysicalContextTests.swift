import Testing
@testable import GuesthouseCore

@Suite struct RedactorRetainedPhysicalContextTests {
    @Test func recoveredTokenRetainsAnEmptyPasswordLabel() {
        let output = Redactor().redact(lines: [
            "eyJhbGciOiJIUzI1NiIsI\u{1B}[mtpZCI6Im5hYmMifQ.payload.-password:",
            "syntheticOpaque", "Finished"
        ]).map(\.text)
        #expect(!output.joined().contains("payload"))
        #expect(!output.joined().contains("syntheticOpaque"))
        #expect(output[2] == "Finished")
    }

    @Test(arguments: ["filename", "☃filename"])
    func retainedBoundaryProtectsTheWholeWrappedKey(_ prefix: String) {
        let output = Redactor().redact(lines: [
            prefix + "\u{0}s\u{1B}[31", "mk-abcdefghijklmnop",
            "qrstuvwxyz", ";", "Finished"
        ]).map(\.text)
        #expect(!output.joined().contains("abcdefghijklmnop"))
        #expect(!output.joined().contains("qrstuvwxyz"))
        #expect(output[4] == "Finished")
    }
}
