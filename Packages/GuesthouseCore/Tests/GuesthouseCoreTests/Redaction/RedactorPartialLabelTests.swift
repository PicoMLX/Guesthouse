import Testing
@testable import GuesthouseCore

@Suite struct RedactorPartialLabelTests {
    @Test(arguments: [("--g", "ithub-token opaque"), ("--ve", "ndor-password opaque")])
    func unknownQualifierPrefixesKeepTheirOptionBoundary(_ first: String, _ next: String) throws {
        var state = Redactor.StreamState()
        state.pendingCredentialLabel = Redactor.partialCredentialLabel(in: first)
        let restored = try #require(Redactor.restoringCredentialLabel(in: next, state: &state))
        #expect(restored.firstMatch(of: Redactor.patterns.secretOption) != nil)
    }

    @Test(arguments: [("gh  ", "p_opaque", "ghp_opaque"),
                      ("github_pa\t", "t_opaque", "github_pat_opaque")])
    func providerPrefixesIgnoreOnlyHorizontalEndPadding(_ first: String, _ next: String, _ expected: String) {
        var state = Redactor.StreamState()
        state.pendingCredentialLabel = Redactor.partialCredentialLabel(in: first)
        #expect(Redactor.restoringCredentialLabel(in: next, state: &state) == expected)
    }

    @Test(arguments: [("Enter the cod", "e ABCD-EFGH", "enter code ABCD-EFGH"),
                      ("Enter the co", "de ABC123", "enter code ABC123"),
                      ("one-time cod", "e is opaque", "one-time code is opaque"),
                      ("one time co", "de is opaque", "one time code is opaque"),
                      ("one_time code", " is opaque", "one_time code is opaque"),
                      ("onetime c", "ode is opaque", "onetime code is opaque"),
                      ("device.co", "de: opaque", "device.code: opaque"),
                      ("Your code", " is opaque", "your code is opaque")])
    func splitPromptsRetainOnlyTheirRecognizedInstruction(_ first: String, _ next: String, _ expected: String) {
        var state = Redactor.StreamState()
        state.pendingCredentialLabel = Redactor.partialCredentialLabel(in: first)
        #expect(Redactor.restoringCredentialLabel(in: next, state: &state) == expected)
    }

    @Test(arguments: ["your", "one-time", "one time", "one_time", "onetime", "verification", "activation",
                      "confirmation", "pairing", "login", "security", "authorization", "auth", "access", "user", "device"]
        .flatMap { qualifier in (1...qualifier.count).map { (qualifier, $0) } })
    func everyQualifierSplitRestoresARecognizablePrompt(_ qualifier: String, _ split: Int) throws {
        var state = Redactor.StreamState()
        state.pendingCredentialLabel = Redactor.partialCredentialLabel(in: String(qualifier.prefix(split)))
        let prefix = try #require(state.pendingCredentialLabel)
        #expect(prefix.count <= 48 && !prefix.contains("opaque"))
        let restored = try #require(Redactor.restoringCredentialLabel(
            in: String(qualifier.dropFirst(split)) + " code is opaque", state: &state))
        #expect(restored.firstMatch(of: Redactor.patterns.declarativeCodePrompt).flatMap { $0.2.map(String.init) } == "opaque")
    }

    @Test(arguments: ["tokens", "passwords", "secrets", "api_keys", "api.key", "clientSecrets", "private_keys"])
    func pluralCredentialFieldsUseTheSharedVocabulary(_ label: String) {
        #expect((label + ": opaque").firstMatch(of: Redactor.patterns.labeledSecret).map { String($0.3) } == "opaque")
        #expect(Redactor.partialCredentialLabel(in: label) == label.lowercased())
    }

    @Test(arguments: ["https://user:part@", "url=//user:part@"])
    func aTerminalAtSignCannotProveUserinfoIsComplete(_ input: String) {
        #expect(input.firstMatch(of: Redactor.patterns.incompleteURLUserInfo) != nil)
    }

    @Test(arguments: [("private k", "ey: opaque", "private key: opaque"),
                      ("api.k", "ey: opaque", "api.key: opaque"),
                      ("request authoriz", "ation: opaque", "request authorization: opaque"),
                      ("secret access k", "ey: opaque", "secret access key: opaque"),
                      ("signing", "Secret: opaque", "signingSecret: opaque")])
    func multiwordFieldPrefixesRetainTheirWholeSensitiveName(_ first: String, _ next: String, _ expected: String) {
        var state = Redactor.StreamState()
        state.pendingCredentialLabel = Redactor.partialCredentialLabel(in: first)
        #expect(Redactor.restoringCredentialLabel(in: next, state: &state) == expected)
    }

    @Test(arguments: [(#""clientSecret""#, ": opaque"), (#"'clientSecret'"#, ": opaque"),
                      (#"\"clientSecret\""#, ": opaque"), (#"\"clientSecret\"#, #"": opaque"#)])
    func closedFieldQuotesDoNotDiscardThePendingAssignment(_ first: String, _ next: String) throws {
        var state = Redactor.StreamState()
        state.pendingCredentialLabel = Redactor.partialCredentialLabel(in: first)
        let restored = try #require(Redactor.restoringCredentialLabel(in: next, state: &state))
        #expect(restored.firstMatch(of: Redactor.patterns.labeledSecret).map { String($0.3) } == "opaque")
    }

    @Test(arguments: [#""[redacted:decoy]" syntheticOpaque"#, #"'syntheticFirst' syntheticOpaque"#])
    func aQuoteWithoutAStructuralTailCannotBoundAnAuthorizationValue(_ value: String) {
        #expect(("Authorization: " + value).firstMatch(of: Redactor.patterns.authorizationHeader).map { String($0.2) } == value)
    }

    @Test(arguments: [#""[redacted:decoy]" syntheticOpaque"#, #"'syntheticFirst' syntheticOpaque"#])
    func aQuoteWithoutAStructuralTailCannotBoundASecretValue(_ value: String) {
        #expect(("password: " + value).firstMatch(of: Redactor.patterns.labeledSecret).map { String($0.3) } == value)
    }

    @Test func canonicalOptionSuccessorsCannotAbsorbUnrelatedWords() {
        var state = Redactor.StreamState()
        state.pendingCredentialLabel = "--cl"
        #expect(Redactor.restoringCredentialLabel(in: "osed status s", state: &state) == nil)
        #expect(state.pendingCredentialLabel == nil)
    }

    @Test(arguments: ["--se", "--t"])
    func canonicalSuccessorsMustExtendTheWholeRetainedLabel(_ prefix: String) {
        var state = Redactor.StreamState()
        state.pendingCredentialLabel = prefix
        #expect(Redactor.restoringCredentialLabel(in: "Finished", state: &state) == nil)
        #expect(state.pendingCredentialLabel == nil)
    }

    @Test(arguments: [("Bas", "ic", "basic"), ("Dige", "st", "digest"),
                      ("AWS4-HMAC-S", "HA256", "aws4-hmac-sHA256"),
                      ("--cl", "ient-s", "--client-s")])
    func intermediateRecordsCanCompleteSchemesOrCanonicalizeOptions(_ first: String, _ middle: String, _ expected: String) {
        var state = Redactor.StreamState()
        state.pendingCredentialLabel = Redactor.partialCredentialLabel(in: first)
        #expect(Redactor.restoringCredentialLabel(in: middle, state: &state) == expected)
    }

    @Test(arguments: [("Bas", "ic\tdXNlcjpwYXNz", "basic\tdXNlcjpwYXNz"),
                      ("Bea", "rer\topaque", "bearer\topaque"),
                      ("AWS4-HMAC-S", "HA256 Credential=opaque", "aws4-hmac-sHA256 Credential=opaque")])
    func splitSchemesKeepTheirFullPrefixAndHorizontalWhitespace(_ first: String, _ second: String, _ expected: String) {
        var state = Redactor.StreamState()
        state.pendingCredentialLabel = Redactor.partialCredentialLabel(in: first)
        #expect(state.pendingCredentialLabel == first.lowercased())
        #expect(Redactor.restoringCredentialLabel(in: second, state: &state) == expected)
    }

    @Test(arguments: [#"["--password", opaque\, "--verbose"]"#, #"["--password", opaque\]"#, #"["--github.token", opaque\]"#, #"["--api.key", opaque\]"#])
    func serializedDelimitersCannotArmPhysicalContinuation(_ input: String) {
        var state = Redactor.StreamState()
        #expect(!Redactor.redactSerializedOptions(input, state: &state).contains("opaque"))
        #expect(!state.expectingSecretValue && !state.secretValueExplicitlyContinues)
    }

    @Test(arguments: ["Bearer [redacted:jwt] synthetic", "Bearer [redacted:jwt] [redacted:secret] synthetic"])
    func markerSeparatedBearerSpansKeepTheirInteriorWhole(_ first: String) throws {
        let result = Redactor.renderings(of: first + "\u{1B}[31mCredential")
        let span = try #require(Redactor.terminalCredentialSpans(in: result.joined).first { $0.kind == "bearer-token" })
        #expect(String(result.joined[span.range]).hasSuffix("syntheticCredential"))
        #expect(result.spliced == result.joined)
    }

    @Test(arguments: [("--cl", "ient-secret opaque", "--client-secret opaque"),
                      ("--github.to", "ken opaque", "--token opaque"),
                      ("--api.k", "ey opaque", "--api.key opaque"),
                      ("--device-co", "de opaque", "--device-code opaque"),
                      ("--access-k", "ey-secret opaque", "--access-key-secret opaque"),
                      ("cod", "e: ABCD-EFGH", "code: ABCD-EFGH"),
                      ("code", ": ABCD-EFGH", "code: ABCD-EFGH")])
    func qualifiedOptionsAndStandalonePromptsRetainTheirGrammar(_ first: String, _ second: String, _ expected: String) {
        var state = Redactor.StreamState()
        state.pendingCredentialLabel = Redactor.partialCredentialLabel(in: first)
        #expect(state.pendingCredentialLabel != nil)
        #expect(Redactor.restoringCredentialLabel(in: second, state: &state) == expected)
    }

    @Test(arguments: ["https:\\/\\", "https:\\", "/\\", "url=https:\\/\\", "url:https:/", "url:https:\\/\\"])
    func trailingSlashEscapesRemainAnIncompleteAuthority(_ input: String) {
        #expect(input.firstMatch(of: Redactor.patterns.partialURLAuthority) != nil)
    }

    @Test(arguments: [" = ", " : ", "= ", ": ", "\t=\t", "=", ":"], ["--password", "--github.token", "--api.key"])
    func spacedOptionAssignmentsConsumeTheValueNotTheDelimiter(_ separator: String, _ option: String) {
        var state = Redactor.StreamState()
        let input = "run " + option + separator + "syntheticOpaque --verbose"
        #expect(Redactor.redactSecretOptions(input, state: &state) == "run " + option + " [redacted:secret] --verbose")
        #expect(!state.expectingSecretValue && state.quotedValue == nil)
    }

    @Test(arguments: [" = ", " : "])
    func explicitAssignmentOwnsAnOptionShapedValue(_ separator: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.redactSecretOptions("--password" + separator + "--token --verbose", state: &state)
            == "--password [redacted:secret] --verbose")
        #expect(!state.expectingSecretValue)
        #expect(("--password" + separator).wholeMatch(of: Redactor.patterns.secretOptionOnly) != nil)
    }

    @Test(arguments: [
        ("clientSec", "ret: syntheticOpaque", "clientsecret: syntheticOpaque"),
        ("refreshTo", "ken: syntheticOpaque", "refreshtoken: syntheticOpaque"),
        ("sessionTo", "ken: syntheticOpaque", "sessiontoken: syntheticOpaque"),
        ("current_secret-ac", "cess_key: syntheticOpaque", "current_secret-access_key: syntheticOpaque"),
        ("sk", "-abcdefghijklmnop", "sk-abcdefghijklmnop"),
        ("s", "k-abcdefghijklmnop", "sk-abcdefghijklmnop")
    ])
    func structuralPrefixesRestoreCompleteCredentialNames(_ first: String, _ second: String, _ expected: String) {
        var state = Redactor.StreamState()
        state.pendingCredentialLabel = Redactor.partialCredentialLabel(in: first)
        #expect(state.pendingCredentialLabel != nil)
        #expect(Redactor.restoringCredentialLabel(in: second, state: &state) == expected)
        #expect(state.pendingCredentialLabel == nil)
    }

    @Test(arguments: ["risk", "casks", "filenames", "ordinary diagnostic", "vendorclientSec", "vendor-clientGuide", "public k", "private guide"])
    func genericStemPrefixesRequireTheirOwnBoundary(_ input: String) {
        #expect(Redactor.partialCredentialLabel(in: input) == nil)
    }

    @Test(arguments: [("x-access", "-token: opaque", "access-token: opaque"),
                      ("vendor-clientSec", "ret: opaque", "clientsecret: opaque"),
                      ("vendor_device-co", "de: opaque", "device-code: opaque"),
                      (String(repeating: "vendor", count: 100) + "-clientSec", "ret: opaque", "clientsecret: opaque")])
    func vendorPrefixesRetainOnlyTheirSensitiveSuffix(_ first: String, _ second: String, _ expected: String) {
        var state = Redactor.StreamState()
        state.pendingCredentialLabel = Redactor.partialCredentialLabel(in: first)
        #expect(state.pendingCredentialLabel != nil)
        #expect((state.pendingCredentialLabel?.count ?? 0) <= 48)
        #expect(Redactor.restoringCredentialLabel(in: second, state: &state) == expected)
        #expect(state.pendingCredentialLabel == nil)
    }
}
