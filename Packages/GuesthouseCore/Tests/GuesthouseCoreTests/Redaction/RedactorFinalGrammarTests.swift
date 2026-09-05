import Testing
@testable import GuesthouseCore

@Suite struct RedactorFinalGrammarTests {
    @Test(arguments: ["Enter the code shown below:", "Paste this code displayed below:", "Your device code is:", "Your user code is ="])
    func instructionsKeepTheNextOpaqueCodeSensitive(prompt: String) {
        let lines = [prompt, "", "abcd", "done"]
        let output = Redactor().redact(lines: lines).map(\.text)
        #expect(output == [prompt, "", "[redacted:device-code]", "done"])
        #expect(Redactor().redact(lines.joined(separator: "\n")) == output.joined(separator: "\n"))
    }

    @Test(arguments: ["Your device code is: ", "Your user code is=", "device code equals:", "user code reads = "])
    func delimitedDeclarationsRemoveOpaqueCodes(prompt: String) {
        let output = Redactor().redact(prompt + "abcd")
        #expect(!output.contains("abcd"))
        #expect(output.contains("[redacted:device-code]"))
    }

    @Test(arguments: ["--remote=", "run -r=", "run --remote = "])
    func optionAssignedNetworkPathsRemoveOnlyUserinfo(prefix: String) {
        #expect(Redactor().redact(prefix + "//sample:synthetic@example.com/path") == prefix + "//[redacted:userinfo]@example.com/path")
    }

    @Test(arguments: ["https://example.com?--remote=//folder@archive", "https://example.com/path/-r=//folder@archive",
                      "Enter the code shown below", "device code island", "user code arguably valid"])
    func nearbyOrdinaryTextDoesNotConsumeTheNextLine(input: String) {
        let lines = [input, "ordinary status"]
        #expect(Redactor().redact(lines: lines).map(\.text) == lines)
    }
}
