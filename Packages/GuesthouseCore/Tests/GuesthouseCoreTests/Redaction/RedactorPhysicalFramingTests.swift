import Testing
@testable import GuesthouseCore

@Suite struct RedactorPhysicalFramingTests {
    @Test(arguments: ["PRIVATE KEY", "RSA PRIVATE KEY", "ACME-PRIVATE KEY", "X9.42 DH PARAMETERS"])
    func completePEMBlocksPreserveOnlyTheSurroundingDiagnostic(_ label: String) {
        var pending: String?
        let input = "before -----BEGIN " + label + "-----syntheticBody-----END " + label + "----- after"
        #expect(Redactor.redactPEMBlocks(input, label: &pending) == "before [redacted:private-key] after")
        #expect(pending == nil)
    }

    @Test func PEMStateCarriesTheLabelButNeverTheBody() {
        var pending: String?
        #expect(Redactor.redactPEMBlocks("-----BEGIN PRIVATE KEY-----syntheticFirst", label: &pending) == "[redacted:private-key]")
        #expect(pending == "PRIVATE KEY")
        #expect(Redactor.redactPEMBlocks("syntheticSecond", label: &pending) == "[redacted:private-key]")
        #expect(Redactor.redactPEMBlocks("-----END RSA PRIVATE KEY-----", label: &pending) == "[redacted:private-key]")
        #expect(pending == "PRIVATE KEY")
        #expect(Redactor.redactPEMBlocks("-----END PRIVATE KEY----- done", label: &pending) == "[redacted:private-key] done")
        #expect(pending == nil)
    }

    @Test func AClosedPEMBlockCanBeFollowedByAnotherOpener() {
        var pending: String? = "PRIVATE KEY"
        let line = "-----END PRIVATE KEY----- middle -----BEGIN RSA PRIVATE KEY-----synthetic"
        #expect(Redactor.redactPEMBlocks(line, label: &pending) == "[redacted:private-key] middle [redacted:private-key]")
        #expect(pending == "RSA PRIVATE KEY")
    }

    @Test(arguments: ["eyJhbGciOiJIUzI1NiJ9", "eyJhbGciOiJIUzI1NiJ9.cGF5bG9hZA", "eyJhbGciOiJIUzI1NiJ9.cGF5bG9hZA."])
    func IncompleteJOSECandidatesKeepTheirOriginalStart(_ token: String) throws {
        let input = "prefix " + token + " \t"
        let start = try #require(Redactor.incompleteJWTStartAtLineEnd(in: input))
        #expect(String(input[start...]) == token + " \t")
    }

    @Test(arguments: ["Finished", "prefix e30.payload", "eyJhbGciOiJIUzI1NiJ9.payload; status=ok"])
    func OrdinaryOrTerminatedRecordsDoNotBecomeIncompleteJOSEHeaders(_ input: String) {
        #expect(Redactor.incompleteJWTStartAtLineEnd(in: input) == nil)
    }
}
