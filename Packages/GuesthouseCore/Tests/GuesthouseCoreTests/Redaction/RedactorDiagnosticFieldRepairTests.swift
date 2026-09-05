import Testing
@testable import GuesthouseCore

@Suite struct RedactorDiagnosticFieldRepairTests {
    @Test(arguments: ["Cookie", "setCookie", "requestCookie", "set_cookie", "request-cookie"], ["", "\""])
    func serializedCookieAliasesConcealOpaqueSessionValues(name: String, quote: String) {
        let input = quote + name + quote + ": SID=syntheticSession"
        #expect(!Redactor().redact(input).contains("syntheticSession"))
        let output = Redactor().redact(lines: [quote + name + quote + ":", "syntheticSession", "Finished"]).map(\.text)
        #expect(!output.joined().contains("syntheticSession"))
        #expect(output[2] == "Finished")
    }

    @Test(arguments: ["CookieCount: 42", "setCookieCount=42", "requestCookiePolicy: required"])
    func longerOrdinaryCookiePropertyNamesRemainVisible(input: String) {
        #expect(Redactor().redact(input) == input)
    }

    @Test(arguments: ["tcp(db:3306)", "tcp6([::1]:3306)", "unix(/tmp/mysql.sock)", "tcp", "",
                      "cloudsql(project:region:instance)", "custom+net(address)", "registered_transport"],
          ["syntheticPassword", "synthetic@part/with: spaces", "synthetic\"quoted'value", "//synthetic/part"])
    func conventionalSchemelessDSNsConcealAllUserinfo(protocolAndAddress: String, password: String) {
        let input = "dsn=alice:" + password + "@" + protocolAndAddress + "/app"
        let output = Redactor().redact(input)
        #expect(!output.contains("synthetic"))
        #expect(output == "dsn=[redacted:userinfo]@" + protocolAndAddress + "/app")
    }

    @Test(arguments: ["contact: alice@example.com", "tcp(db:3306)/app", "unix(/tmp/mysql.sock)/app",
                      "https://example.com?email=alice@example.org", "HTTPS://example.com/a@b/c", "ssh://example.com/a@b/c"])
    func addressesAndEmailWithoutAPasswordDoNotBecomeDSNs(input: String) {
        #expect(Redactor().redact(input) == input)
    }

    @Test func aTerminalConsumedProtocolCharacterDoesNotHideADSNCredential() {
        #expect(!Redactor().redact("alice:syntheticPassword@\u{1B}[tcp(db:3306)/app").contains("syntheticPassword"))
    }

    @Test(arguments: ["https://alice:syntheticPassword@example.com/app", "//alice:syntheticPassword@example.com/app",
                      "alice:syntheticPassword@cloudsql(instance)/app", "https:\\/\\/alice:syntheticPassword@example.com/app"])
    func sanitizedUserinfoSurvivesASecondRedactionPass(input: String) {
        let first = Redactor().redact(input)
        #expect(!first.contains("syntheticPassword"))
        #expect(Redactor().redact(first) == first)
    }

    @Test func anEncodedURLRetainsItsSchemeAndEscapedDelimiters() {
        let input = #"https:\/\/alice:syntheticPassword@example.com/app"#
        #expect(Redactor().redact(input) == #"https:\/\/[redacted:userinfo]@example.com/app"#)
    }

    @Test func aPreviousMarkerCannotHideALaterDSN() {
        let input = "[redacted:userinfo]@tcp(host)/app alice:syntheticPassword@cloudsql(instance)/app"
        #expect(!Redactor().redact(input).contains("syntheticPassword"))
    }
}
