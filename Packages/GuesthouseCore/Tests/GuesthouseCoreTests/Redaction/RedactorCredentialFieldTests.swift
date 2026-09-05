import Testing
@testable import GuesthouseCore

@Suite struct RedactorCredentialFieldTests {
    @Test(arguments: [
        ("databasePassword", "e", "Password"),
        ("sshPrivateKey", "h", "PrivateKey"),
        ("SSHPrivateKey", "H", "PrivateKey"),
        ("database_password", "_", "password"),
        ("ssh-private-key", "-", "private-key"),
    ], [":", "="])
    func qualifiedFieldsRetainTheirBoundary(field: (name: String, boundary: String, suffix: String), delimiter: String) throws {
        let match = try #require((field.name + delimiter + "opaqueCredential").firstMatch(of: Redactor.patterns.labeledSecret))
        #expect(match.1 == field.boundary)
        #expect(match.2 == field.suffix)
        #expect(match.3 == "opaqueCredential")
        let output = Redactor().redact(field.name + delimiter + "opaqueCredential")
        #expect(output == field.name + ": [redacted:secret]")
    }

    @Test(arguments: ["nonToken: 42", "nonToken=opaqueCredential"])
    func explicitCredentialSuffixDoesNotInferSemanticNegation(input: String) {
        #expect(Redactor().redact(input) == "nonToken: [redacted:secret]")
    }

    @Test(arguments: ["databasePassword", "sshPrivateKey"], ["\"", "'"])
    func quotedQualifiedFieldsPreserveOrdinarySiblings(name: String, quote: String) {
        let input = "{" + quote + name + quote + ":" + quote + "opaqueCredential" + quote + ",\"tokenCount\":42}"
        let output = Redactor().redact(input)
        #expect(!output.contains("opaqueCredential"))
        #expect(output.contains(name))
        #expect(output.hasSuffix(",\"tokenCount\":42}"))
    }

    @Test(arguments: ["databasePassword:", "\"databasePassword\":", "sshPrivateKey=", "'sshPrivateKey'="])
    func qualifiedBareLabelsArmTheirValue(input: String) {
        #expect(input.contains(Redactor.patterns.secretLabelOnly))
        let output = Redactor().redact(input + "\nopaqueCredential\nordinary diagnostic")
        #expect(!output.contains("opaqueCredential"))
        #expect(output.hasSuffix("ordinary diagnostic"))
    }

    @Test(arguments: [
        "run --databasePassword opaqueCredential --verbose",
        "run --ssh-private-key=opaqueCredential --verbose",
        "[\"--sshPrivateKey\",\"opaqueCredential\",\"--verbose\"]",
        "run --databasePassword\nopaqueCredential\n--verbose",
    ])
    func qualifiedOptionsShareTheSecretVocabulary(input: String) {
        let output = Redactor().redact(input)
        #expect(!output.contains("opaqueCredential"))
        #expect(output.contains("--verbose"))
    }

    @Test(arguments: ["Cookie", "Set-Cookie"], [":", "="])
    func cookieHeadersCaptureOpaqueValues(name: String, delimiter: String) throws {
        let input = name + delimiter + "session=opaqueCredential; preference=opaqueOther"
        let match = try #require(input.firstMatch(of: Redactor.patterns.authorizationHeader))
        #expect(match.1.isEmpty)
        #expect(match.2 == "session=opaqueCredential; preference=opaqueOther")
        let output = Redactor().redact(input)
        #expect(!output.contains("opaqueCredential"))
        #expect(!output.contains("opaqueOther"))
        #expect(output.contains("[redacted:authorization]"))
        #expect(output.hasPrefix(name + ": "))
    }

    @Test(arguments: ["Cookie", "Set-Cookie"])
    func cookieHeadersShareFoldedAndBareValueState(name: String) {
        let folded = Redactor().redact(name + ": SID=opaqueCredential\n next=opaqueOther\nAccept: */*")
        #expect(!folded.contains("opaqueCredential"))
        #expect(!folded.contains("opaqueOther"))
        #expect(folded.hasSuffix("Accept: */*"))
        let bare = Redactor().redact(name + ":\n\nSID=opaqueCredential\nAccept: */*")
        #expect(!bare.contains("opaqueCredential"))
        #expect(bare.hasSuffix("Accept: */*"))
        #expect(Redactor().redact(name + ":\nAccept: */*").hasSuffix("Accept: */*"))
    }

    @Test(arguments: ["Cookie", "Set-Cookie"], ["\"", "'"])
    func quotedCookieHeadersPreserveClosedSiblings(name: String, quote: String) {
        let input = "{" + quote + name + quote + ":" + quote + "SID=opaqueCredential" + quote + ",\"count\":42}"
        let output = Redactor().redact(input)
        #expect(!output.contains("opaqueCredential"))
        #expect(output.hasSuffix(",\"count\":42}"))
    }

    @Test(arguments: [
        "databasepassword=ordinary", "sshprivatekey:ordinary", "databasePasswordLength=12", "nontoken:42",
        "tokenCount=42", "errorCode:42", "secretary:available", "CookieCount=2", "notCookie:ordinary",
        "Set-Cookie-Count:2", "databasePassword is configured", "Cookies are supported",
        "run --tokenCount 42", "c15e59b83ad7fcd9a95dd5534e6bb6fdd8073787",
        "12345678-1234-1234-1234-123456789012", "2.36.0",
    ])
    func ordinaryNamesAndDiagnosticsRemainUnchanged(input: String) {
        #expect(!input.contains(Redactor.patterns.labeledSecret))
        #expect(!input.contains(Redactor.patterns.authorizationHeader))
        #expect(!input.contains(Redactor.patterns.secretLabelOnly))
        #expect(Redactor().redact(input + "\nordinary diagnostic") == input + "\nordinary diagnostic")
    }
}
