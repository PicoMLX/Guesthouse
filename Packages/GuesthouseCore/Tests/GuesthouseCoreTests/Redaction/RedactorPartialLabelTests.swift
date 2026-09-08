import Testing
@testable import GuesthouseCore

@Suite struct RedactorPartialLabelTests {
    @Test(arguments: [" = ", " : ", "= ", ": ", "\t=\t", "=", ":"])
    func spacedOptionAssignmentsConsumeTheValueNotTheDelimiter(_ separator: String) {
        var state = Redactor.StreamState()
        let input = "run --password" + separator + "syntheticOpaque --verbose"
        #expect(Redactor.redactSecretOptions(input, state: &state) == "run --password [redacted:secret] --verbose")
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

    @Test(arguments: ["risk", "casks", "filenames", "ordinary diagnostic", "vendorclientSec", "vendor-clientGuide"])
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
