import Testing
@testable import GuesthouseCore

@Suite struct RedactorPartialLabelTests {
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

    @Test(arguments: ["risk", "casks", "filenames", "ordinary diagnostic"])
    func genericStemPrefixesRequireTheirOwnBoundary(_ input: String) {
        #expect(Redactor.partialCredentialLabel(in: input) == nil)
    }
}
