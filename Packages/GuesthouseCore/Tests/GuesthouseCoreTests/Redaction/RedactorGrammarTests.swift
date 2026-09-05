import Foundation
import Testing
@testable import GuesthouseCore

/// Synthetic examples exercise recognition before a public sanitizer is introduced.
@Suite struct RedactorGrammarTests {
    @Test(arguments: [
        ("Enter the code: ABC123", "Enter the code:"),
        ("Enter this code: abcdef", "Enter this code:"),
        ("Paste a code= tiny", "Paste a code="),
        ("Copy your code: \"synthetic value\"", "Copy your code:"),
    ])
    func delimitedImperativePromptsCaptureTheCompleteValue(input: String, prompt: String) throws {
        let match = try #require(input.firstMatch(of: Redactor.patterns.codePrompt))
        #expect(match.1 == prompt)
        #expect(match.range.upperBound == input.endIndex)
        #expect(prompt.contains(Redactor.patterns.codePromptOnly))
    }

    @Test(arguments: [
        ("payload.accessToken=grammarValue", "accessToken", "grammarValue"),
        (#"{"clientSecret":"grammar value"}"#, "clientSecret", #""grammar value""#),
        ("private_key: grammar value", "private_key", "grammar value"),
        ("previous-password: grammarValue", "previous-password", "grammarValue"),
    ])
    func secretFieldsCaptureTheCompleteValue(input: String, label: String, value: String) throws {
        let match = try #require(input.firstMatch(of: Redactor.patterns.labeledSecret))
        #expect(match.2 == label)
        #expect(match.3 == value)
    }

    @Test(arguments: ["password:", #""refresh_token": "#, "payload.privateKey= "])
    func bareSecretLabelsRemainDistinctFromInlineValues(input: String) {
        #expect(input.contains(Redactor.patterns.secretLabelOnly))
        #expect(!input.contains(Redactor.patterns.labeledSecret))
    }

    @Test(arguments: [
        ("run --github-token grammarValue --verbose", "--github-token"),
        ("run --private-key=grammarValue", "--private-key"),
        ("run -password grammarValue", "-password"),
    ])
    func commandOptionsCaptureOnlyTheOptionPrefix(input: String, option: String) throws {
        let match = try #require(input.firstMatch(of: Redactor.patterns.secretOption))
        #expect(match.2 == option)
        #expect(input[match.range.upperBound...].hasPrefix("grammarValue"))
    }

    @Test(arguments: ["run --password", "run --client-secret= "])
    func missingCommandValuesAreRecognized(input: String) {
        #expect(input.contains(Redactor.patterns.secretOptionOnly))
        #expect(!input.contains(Redactor.patterns.secretOption))
    }

    @Test(arguments: [
        ("payload.Authorization: Custom grammarValue", "Custom grammarValue"),
        ("Proxy-Authorization=Digest username=sample, response=synthetic", "Digest username=sample, response=synthetic"),
        (#"{"request_authorization":"Custom grammarValue"}"#, #""Custom grammarValue""#),
    ])
    func authorizationFieldsCaptureOpaqueAndMultipartValues(input: String, value: String) throws {
        let match = try #require(input.firstMatch(of: Redactor.patterns.authorizationHeader))
        #expect(match.2 == value)
    }

    @Test(arguments: [
        "process exited with code 1", "Enter the code shown below",
        "the login code was rejected", "error code: 42",
    ])
    func diagnosticProseDoesNotBecomeACodePrompt(input: String) {
        #expect(!input.contains(Redactor.patterns.codePrompt))
        #expect(!input.contains(Redactor.patterns.codePromptOnly))
        #expect(!input.contains(Redactor.patterns.codePromptWithoutDelimiter))
        #expect(!input.contains(Redactor.patterns.declarativeCodePrompt))
    }

    @Test(arguments: [
        "tokenizer: ready", "secretary: available", "passwordLength=12",
        "run --token-count 42", "run --output report.json",
    ])
    func ordinaryNamesDoNotMatchCredentialFieldsOrOptions(input: String) {
        #expect(!input.contains(Redactor.patterns.labeledSecret))
        #expect(!input.contains(Redactor.patterns.secretOption))
        #expect(!input.contains(Redactor.patterns.secretOptionOnly))
    }

    @Test(arguments: ["ABCD-EFGH.example.com", "12345678-1234-1234-1234-123456789012"])
    func longerIdentifiersDoNotBecomeDeviceCodes(input: String) {
        #expect(!input.contains(Redactor.patterns.deviceCode))
    }

    @Test(arguments: ["Digest authentication supported", "Negotiate", "AWS4-HMAC-SHA256 supported"])
    func authenticationSchemesWithoutCredentialValuesRemainUnmatched(input: String) {
        #expect(!input.contains(Redactor.patterns.digestAuthorization))
        #expect(!input.contains(Redactor.patterns.specializedAuthorization))
    }
}
