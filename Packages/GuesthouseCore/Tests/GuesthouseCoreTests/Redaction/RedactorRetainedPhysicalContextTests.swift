import Testing
@testable import GuesthouseCore

@Suite struct RedactorRetainedPhysicalContextTests {
    @Test(arguments: [["Enter the cod", "e ABCD-EFGH"], ["Enter the co", "de ABC123"],
                      ["Your code", " is syntheticOpaque"],
                      ["https://user:syntheticFirst@", "syntheticSecond@example.com/path"],
                      ["https://user:syntheticFirst@", "syntheticMiddle@", "syntheticSecond@example.com/path"],
                      ["tokens: syntheticOpaque"], ["api_keys: syntheticOpaque"]])
    func promptPluralAndURLBoundariesKeepCredentialsConcealed(_ records: [String]) {
        let output = Redactor().redact(lines: records + ["Finished"]).map(\.text)
        #expect(!output.joined().contains("synthetic") && !output.joined().contains("ABC"))
        #expect(output.last == "Finished")
    }

    @Test(arguments: [["private k", "ey: syntheticOpaque"], ["secret access k", "ey: syntheticOpaque"],
                      [#""clientSecret""#, ": syntheticOpaque"], [#"\"clientSecret\"#, #"": syntheticOpaque"#],
                      ["prefix AWS4-HMAC-S", "HA256 Credential=syntheticOpaque"]])
    func fieldNameFramingSurvivesBeforeTheAssignment(_ records: [String]) {
        let output = Redactor().redact(lines: records + ["Finished"]).map(\.text)
        #expect(!output.joined().contains("syntheticOpaque"))
        #expect(output.last == "Finished")
    }

    @Test(arguments: ["password", "Authorization"])
    func quotedFieldDecoysCannotExposeTheUnframedTail(_ label: String) {
        let output = Redactor().redact(lines: [label + #": "[redacted:decoy]" syntheticOpaque"#,
            " syntheticFold", "Finished"]).map(\.text)
        #expect(!output.joined().contains("syntheticOpaque") && !output.joined().contains("syntheticFold"))
        #expect(output[2] == "Finished")
    }

    @Test func physicalAPIAlreadyRetainsAValidatedSplitJWTHeader() {
        let output = Redactor().redact(lines: ["eyJhbGciOiJIUzI1NiJ9.", "cGF5bG9hZA.c2ln", "; Finished"]).map(\.text)
        #expect(!output.joined().contains("eyJhbGciOiJIUzI1NiJ9"))
        #expect(!output.joined().contains("cGF5bG9hZA") && !output.joined().contains("c2ln"))
        #expect(output[2] == "; Finished")
    }

    @Test(arguments: [["Bas", "ic", " dXNlcjpwYXNz"], ["Dige", "st", " username=syntheticOpaque"],
                      ["--cl", "ient-s", "ecret syntheticOpaque"]])
    func intermediatePrefixRecordsRetainTheFinalCredential(_ records: [String]) {
        let output = Redactor().redact(lines: records + ["Finished"]).map(\.text)
        #expect(!output.joined().contains("dXNlcjpwYXNz") && !output.joined().contains("syntheticOpaque"))
        #expect(output.last == "Finished")
    }

    @Test(arguments: ["\u{1B}[31mret: syntheticOpaque", "\u{9B}31mret: syntheticOpaque"])
    func physicalAPIAlreadyNormalizesStyledLabelContinuations(_ second: String) {
        let output = Redactor().redact(lines: ["clientSec", second, "Finished"]).map(\.text)
        #expect(!output.joined().contains("syntheticOpaque"))
        #expect(output[2] == "Finished")
    }

    @Test(arguments: [["Authorization:", "Digest username="],
                      [#"Authorization: Digest username="closed","#, " response="]])
    func assignmentsInsideAuthorizationFoldsRetainTheFollowingValue(_ prefix: [String]) {
        let output = Redactor().redact(lines: prefix + ["syntheticOpaque", "Finished"]).map(\.text)
        #expect(!output.joined().contains("syntheticOpaque"))
        #expect(output.last == "Finished")
    }

    @Test(arguments: ["Digest username=", #"Digest username="closed", response="#,
                      "AWS4-HMAC-SHA256 Credential=", "Authorization: Digest username="])
    func terminalAuthorizationAssignmentsConcealTheNextRecord(_ input: String) {
        let output = Redactor().redact(lines: [input, "syntheticOpaque", "Finished"]).map(\.text)
        #expect(!output.joined().contains("syntheticOpaque"))
        #expect(output[2] == "Finished")
    }

    @Test(arguments: [#"Digest username="Muf"#, #"AWS4-HMAC-SHA256 Credential="Muf"#])
    func bareAuthorizationHeadersRetainParameterQuotesInTheirValue(_ value: String) {
        let output = Redactor().redact(lines: ["Authorization:", value, #"asa", response="syntheticResponse""#,
            " syntheticTail", "Finished"]).map(\.text)
        #expect(!output.joined().contains("Muf") && !output.joined().contains("asa"))
        #expect(!output.joined().contains("syntheticResponse") && !output.joined().contains("syntheticTail"))
        #expect(output[4] == "Finished")
    }

    @Test(arguments: [("Bas", "ic\tdXNlcjpwYXNz", "dXNlcjpwYXNz"),
                      ("Bea", "rer\topaque", "opaque"),
                      ("AWS4-HMAC-S", "HA256 Credential=opaque", "opaque"),
                      ("url:https:/", "/user:opaque@example.com/path", "opaque"),
                      (#"prefix "https://user:opaque\""#, "@example.com/path", "opaque")])
    func restoredSchemesAndURLFramesConcealTheirCredential(_ first: String, _ second: String, _ secret: String) {
        #expect(!Redactor().redact(lines: [first, second]).map(\.text).joined().contains(secret))
    }

    @Test func markerSeparatedBearerSurvivesTerminalRendering() {
        let text = Redactor().redact(lines: ["Bearer [redacted:jwt] synthetic\u{1B}[31mCredential"]).map(\.text).joined()
        #expect(!text.contains("synthetic") && !text.contains("Credential"))
    }

    @Test(arguments: [#"["--password", opaque\, "--verbose"]"#, #"["--password", opaque\]"#])
    func serializedDelimitersReleaseTheNextDiagnostic(_ input: String) {
        let output = Redactor().redact(lines: [input, "Finished"]).map(\.text)
        #expect(!output[0].contains("opaque"))
        #expect(output[1] == "Finished")
    }

    @Test(arguments: [#"Digest username="Muf"#, #"AWS4-HMAC-SHA256 Credential="Muf"#,
                      #"Authorization: Digest username="Muf"#])
    func openAuthorizationParameterQuotesConcealTheirEnclosingFold(_ first: String) {
        let output = Redactor().redact(lines: [first, #"asa", response="syntheticResponse""#,
            " syntheticTail", "Finished"]).map(\.text)
        #expect(!output.joined().contains("Muf") && !output.joined().contains("asa"))
        #expect(!output.joined().contains("syntheticResponse") && !output.joined().contains("syntheticTail"))
        #expect(output[3] == "Finished")
    }

    @Test(arguments: ["[https://one.example, https://two.example]", "urls=[//one.example, //two.example]",
                      #""visit https://example.com""#, #""visit https://example.com:443""#,
                      #"prefix "url=https://example.com""#, "prefix <url=https://example.com>", "{url=https://example.com}"])
    func completeURLDiagnosticsDoNotQuarantineTheNextRecord(_ input: String) {
        #expect(Redactor().redact(lines: [input, "Finished"]).map(\.text) == [input, "Finished"])
    }

    @Test(arguments: ["[https://user:sec,ret@example.com]", "[//user:sec,ret@one.example,//other:opaque@two.example]"])
    func commaUserinfoRemainsConcealedInURLLists(_ input: String) {
        let output = Redactor().redact(lines: [input, "Finished"]).map(\.text)
        #expect(!output[0].contains("sec,ret") && !output[0].contains("opaque"))
        #expect(output[1] == "Finished")
    }

    @Test(arguments: [("--cl", "ient-secret opaque"), ("--access-k", "ey-secret opaque"),
                      ("cod", "e: opaque"), ("code", ": opaque")])
    func restoredOptionModifiersAndCodePromptsProtectValues(_ first: String, _ second: String) {
        let output = Redactor().redact(lines: [first, second, "Finished"]).map(\.text)
        #expect(!output.joined().contains("opaque"))
        #expect(output[2] == "Finished")
    }

    @Test(arguments: [1, 2, 16, 256])
    func authorityEscapesCanSplitBeforeTheSecondSlash(_ depth: Int) {
        let escape = String(repeating: "\\", count: depth)
        let output = Redactor().redact(lines: ["https:" + escape + "/" + escape,
            "/user:syntheticOpaque@example.com/path", "Finished"]).map(\.text)
        #expect(!output.joined().contains("syntheticOpaque"))
        #expect(output[1].contains("@example.com/path"))
        #expect(output[2] == "Finished")
    }

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
