import Testing
@testable import GuesthouseCore

@Suite struct RedactorRetainedPhysicalContextTests {
    @Test func splitSchemeAfterALiteralMarkerStillProtectsThePayload() {
        let output = Redactor().redact(lines: ["Bearer [redacted:decoy] Be", "arer syntheticOpaque", "Finished"]).map(\.text)
        #expect(!output.joined().contains("syntheticOpaque"))
        #expect(output[2] == "Finished")
    }

    @Test(arguments: [" = ", " : ", "= ", ": ", "\t=\t"])
    func optionAssignmentsKeepOnlyTheLaterPublicArgument(_ separator: String) {
        let output = Redactor().redact(lines: ["run --password" + separator + "syntheticOpaque --verbose", "Finished"]).map(\.text)
        #expect(output == ["run --password [redacted:secret] --verbose", "Finished"])
    }

    @Test(arguments: ["Basic", "Bearer", "Digest", "NTLM", "Negotiate", "AWS4-HMAC-SHA256"])
    func completeSchemesAlreadyOwnTheirNextPhysicalValue(_ scheme: String) {
        let output = Redactor().redact(lines: [scheme, "opaqueCredential", "Finished"]).map(\.text)
        #expect(output[1] == "[redacted:authorization]")
        #expect(output[2] == "Finished")
    }

    @Test(arguments: [("Basic dXNl", "cjpwYXNz"), ("Basic dXNlcj", "pwYXNz")])
    func partialBasicPayloadsBeforeTheDecodedColonStayConcealed(_ first: String, _ second: String) {
        let output = Redactor().redact(lines: [first, second, "Finished"]).map(\.text)
        #expect(output[0] == "Basic [redacted:authorization]")
        #expect(output[1] == "[redacted:authorization]")
        #expect(output[2] == "Finished")
    }

    @Test(arguments: [("x-access", "-token: opaque"), ("x-", "api-key: opaque"),
                      ("vendor-clientSec", "ret: opaque"), ("vendor_device-co", "de: opaque")])
    func vendorFieldSuffixesConcealTheirOpaqueValue(_ first: String, _ second: String) {
        let output = Redactor().redact(lines: [first, second, "Finished"]).map(\.text)
        #expect(!output.joined().contains("opaque"))
        #expect(output[2] == "Finished")
    }

    @Test(arguments: ["x\u{1B}Authorization: opaque", "x\u{1B}password: opaque",
                      "x\u{1B}[--password opaque", "x\u{1B}device_code: opaque",
                      "☃x\u{1B}pass\u{1B}word: opaque"])
    func recoveredFieldBoundariesConcealTheirOpaqueValues(_ input: String) {
        let output = Redactor().redact(lines: [input, "Finished"]).map(\.text)
        #expect(!output[0].contains("opaque"))
        #expect(output[1] == "Finished")
    }

    @Test(arguments: [("clientSec", "ret: syntheticOpaque"), ("refreshTo", "ken: syntheticOpaque"),
                      ("sessionTo", "ken: syntheticOpaque"), ("current_secret-ac", "cess_key: syntheticOpaque")])
    func qualifiedFieldPrefixesProtectTheFollowingValue(_ first: String, _ second: String) {
        let output = Redactor().redact(lines: [first, second, "Finished"]).map(\.text)
        #expect(!output.joined().contains("syntheticOpaque"))
        #expect(output[2] == "Finished")
    }

    @Test(arguments: [("sk", "-abcdefghijklmnop"), ("s", "k-abcdefghijklmnop")])
    func partialGenericStemsProtectAllWrappedPayload(_ first: String, _ second: String) {
        let output = Redactor().redact(lines: [first, second, "qrstuvwxyz", ";", "Finished"]).map(\.text)
        #expect(!output.joined().contains("abcdefghijklmnop"))
        #expect(!output.joined().contains("qrstuvwxyz"))
        #expect(output[4] == "Finished")
    }

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
