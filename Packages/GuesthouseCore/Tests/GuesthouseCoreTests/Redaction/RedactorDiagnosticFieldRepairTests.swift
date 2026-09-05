import Testing
@testable import GuesthouseCore

@Suite struct RedactorDiagnosticFieldRepairTests {
    @Test(arguments: ["Cookie", "setCookie", "requestCookie", "set_cookie", "request-cookie", "cookies", "setCookies", "requestCookies"], ["", "\""])
    func serializedCookieAliasesConcealOpaqueSessionValues(name: String, quote: String) {
        let input = quote + name + quote + ": SID=syntheticSession"
        #expect(!Redactor().redact(input).contains("syntheticSession"))
        let output = Redactor().redact(lines: [quote + name + quote + ":", "syntheticSession", "Finished"]).map(\.text)
        #expect(!output.joined().contains("syntheticSession"))
        #expect(output[2] == "Finished")
    }

    @Test(arguments: ["CookieCount: 42", "setCookieCount=42", "requestCookiePolicy: required", "CookiesCount: 42", "setCookiesPolicy: required"])
    func longerOrdinaryCookiePropertyNamesRemainVisible(input: String) {
        #expect(Redactor().redact(input) == input)
    }

    @Test(arguments: ["tcp(db:3306)", "tcp6([::1]:3306)", "unix(/tmp/mysql.sock)", "unix(/tmp/mysql(test).sock)", "unix(/tmp/(nested(test)).sock)", "tcp", "",
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

    @Test(arguments: ["$alice", "alice+admin", "alice@example", "用户", "alice=admin", "first last", "alice'quoted", "[alice]", ""])
    func usernamePunctuationCannotPreventPasswordConcealment(username: String) {
        #expect(!Redactor().redact("dsn=" + username + ":syntheticPassword@tcp(db:3306)/app").contains("syntheticPassword"))
    }

    @Test(arguments: ["ws", "wss", "WS", "WSS", "smb", "SMB"])
    func webSocketPathsAreNotDatabaseCredentials(scheme: String) {
        let input = scheme + "://example.com/users/alice@room/events"
        #expect(Redactor().redact(input) == input)
    }

    @Test(arguments: ["password", "passphrase", "Authorization", "device_code"])
    func aDSNInsideAQuotedFieldKeepsPhysicalContinuation(label: String) {
        let lines = [label + ": \"syntheticFirst alice:p@tcp/db", "syntheticSecond\"", "Finished"]
        let output = Redactor().redact(lines: lines).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[2] == "Finished")
    }

    @Test(arguments: ["apiToken", "oauthToken", "githubToken"])
    func qualifiedCamelCaseTokenFieldsUseTheSharedBoundaryRule(label: String) {
        #expect(!Redactor().redact(label + ": syntheticCredential").contains("syntheticCredential"))
    }

    @Test(arguments: ["\u{1B}[", "\u{9B}", "\u{1B}[31"])
    func sameLineCodeContextParticipatesInTerminalRecovery(control: String) {
        let output = Redactor().redact(lines: ["received device_code AB12-" + control + "DC34", "Finished"]).map(\.text)
        #expect(!output[0].contains("AB12"))
        #expect(!output[0].contains("C34"))
        #expect(output[1] == "Finished")
    }
}
