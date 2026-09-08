import Testing
@testable import GuesthouseCore

@Suite struct TerminalCredentialProjectionTests {

    @Test(arguments: ["\u{1B}[12345678m", "\u{9B}12345678m"])
    func numericPrefixesCannotHideAnAcceptedJWT(_ command: String) {
        let input = "eyJ4Ijo" + command + "LCJwYWRkaW5nIjoiIn0.cGF5bG9hZA.c2ln"
        let result = Redactor.recoveredCredentialRanges(in: input, joined: TerminalControlGrammar.normalize(input), priorPrefixes: [])
        #expect(result.ranges.contains { $0.kind == "jwt" || $0.kind == "terminal-ambiguity" })
    }

    @Test(arguments: ["\u{1B}[:;//m", "\u{9B}:;//m"])
    func mixedGrammarClassesRestoreURLUserInfo(_ command: String) throws {
        let input = "https" + command + "user:syntheticOpaque@host"
        let readings = try #require(TerminalControlEvidence.projections(in: input))
        #expect(readings.contains { $0.text == "https://user:syntheticOpaque@host" })
        let result = Redactor.recoveredCredentialRanges(in: input, joined: TerminalControlGrammar.normalize(input), priorPrefixes: [])
        #expect(result.ranges.contains { $0.kind == "userinfo" })
    }

    @Test(arguments: ["\u{1B}[12345672m", "\u{9B}12345672m", "\u{1B}[12;12345672m"])
    func numericComponentSuffixesRemainCredentialEvidence(_ command: String) {
        let input = "The login code was rejected; retry AB1" + command + "-CD34."
        let result = Redactor.recoveredCredentialRanges(in: input, joined: TerminalControlGrammar.normalize(input), priorPrefixes: [])
        #expect(result.ranges.contains { $0.kind == "device-code" || $0.kind == "terminal-ambiguity" })
    }

    @Test(arguments: [#"['--password synthetic\'secretTail']"#, #"args=['run --password synthetic\'secretTail']"#])
    func diagnosticCommandApostrophesRespectEscaping(_ input: String) {
        var state = Redactor.StreamState()
        let output = Redactor.redactSecretOptions(input, state: &state)
        #expect(!output.contains("synthetic") && !output.contains("secretTail"))
        #expect(output.hasSuffix("']"))
        #expect(state.quotedValue == nil)
    }

    @Test(arguments: ["\u{1B}[", "\u{9B}"])
    func ambiguousLongNumericComponentsFailClosed(_ introducer: String) {
        let input = "The login code was rejected; retry " + introducer + "912345678-ABCDEFGH"
        var pending: TerminalControlEvidence.Continuation?
        #expect(TerminalControlEvidence.prepare(input, continuation: &pending).text == "[redacted:terminal-ambiguity]")
        #expect(pending?.quarantined == true)
        #expect(TerminalControlEvidence.prepare("syntheticNext", continuation: &pending).text == "[redacted:terminal-ambiguity]")
    }
    @Test(arguments: ["\u{1B}[31/-m", "\u{9B}31/-m", "\u{1B}/-m"])
    func individualIntermediateBytesRecoverAPIKeyPrefixes(_ command: String) {
        let input = "sk" + command + "abcdefghijklmnopq"
        let result = Redactor.recoveredCredentialRanges(in: input, joined: TerminalControlGrammar.normalize(input), priorPrefixes: [])
        #expect(result.ranges.contains { $0.kind == "api-key" })
    }

    @Test(arguments: ["\u{1B}[2:3@", "\u{9B}2;3@", "\u{1B}[?2:3@", "\u{9B}2:3/m"])
    func individualCSIComponentsRemainScanEvidence(_ command: String) throws {
        let readings = try #require(TerminalControlEvidence.projections(in: command))
        #expect(readings.contains { $0.text == "2" })
        #expect(readings.contains { $0.text == "3" })
        let input = "The login code was rejected; retry AB1" + command + "-CD34."
        let result = Redactor.recoveredCredentialRanges(in: input, joined: TerminalControlGrammar.normalize(input), priorPrefixes: [])
        #expect(result.ranges.contains { $0.kind == "device-code" })
    }

    @Test(arguments: ["\u{1B}[2m", "\u{9B}2m", "\u{1B}[2/m", "\u{9B}2/m"])
    func parameterOnlyReadingsRecoverNumericCodeCharacters(_ command: String) {
        let input = "The login code is AB1" + command + "-CD34."
        let result = Redactor.recoveredCredentialRanges(in: input, joined: TerminalControlGrammar.normalize(input), priorPrefixes: [])
        #expect(result.ranges.contains { $0.kind == "device-code" })
    }

    @Test(arguments: ["password", "Authorization", "device_code"], [":", "="])
    func delimiterOnlyReadingsKeepBareFieldsPending(_ label: String, _ delimiter: String) {
        let input = label + "\u{1B}[31" + delimiter + "m"
        let result = Redactor.recoveredCredentialRanges(in: input, joined: TerminalControlGrammar.normalize(input), priorPrefixes: [])
        #expect(result.contexts.contains(label + delimiter))
    }

    @Test(arguments: ["password: synthetic\u{1B}[31mValue", "password: \"synthetic\u{1B}[31mValue\"",
                      "password: \u{1B}\"syntheticValue\""])
    func stylingOrCompletedQuotesDoNotArmAQuotedContinuation(_ input: String) {
        let result = Redactor.recoveredCredentialRanges(in: input, joined: TerminalControlGrammar.normalize(input), priorPrefixes: [])
        #expect(result.contexts.isEmpty)
    }

    @Test(arguments: ["\r", "\n", "\r\n"])
    func bareRecoveredOptionsExcludePhysicalFraming(_ terminator: String) {
        let input = "\u{1B}--pass\u{1B}[31word" + terminator
        let recovery = Redactor.recoveredCredentialRanges(in: input, joined: TerminalControlGrammar.normalize(input), priorPrefixes: [])
        #expect(recovery.contexts.contains("--password"))
    }

    @Test(arguments: ["\u{1B}[", "\u{9B}"], [":", "="])
    func parameterDelimitersCanRestoreCredentialFields(_ control: String, _ delimiter: String) {
        let input = "password" + control + "31" + delimiter + "msyntheticOpaque"
        let recovery = Redactor.recoveredCredentialRanges(in: input, joined: TerminalControlGrammar.normalize(input), priorPrefixes: [])
        #expect(recovery.contexts.contains("password" + delimiter + "msyntheticOpaque"))
    }

    @Test(arguments: [257, 8_000])
    func excessiveControlDensityQuarantinesBeforeRegexExpansion(_ count: Int) {
        let input = String(repeating: "a\u{0}", count: count)
        #expect(TerminalControlEvidence.projections(in: input)?.count == nil)
        var state: TerminalControlEvidence.Continuation?
        _ = TerminalControlEvidence.prepare(input, continuation: &state)
        #expect(state?.quarantined == true)
        #expect(TerminalControlEvidence.prepare("syntheticNext", continuation: &state).text == "[redacted:terminal-ambiguity]")
    }

    @Test(arguments: ["\r", "\n", "\r\n"], ["\u{1B}[31p", "\u{9B}31p", "\u{1B}p"])
    func recoveredWrappedPrefixesExcludeRecordFraming(_ terminator: String, _ command: String) {
        let input = "gh" + command + "_" + terminator
        let result = Redactor.recoveredCredentialRanges(in: input, joined: TerminalControlGrammar.normalize(input), priorPrefixes: [])
        #expect(result.contexts.contains("ghp_"))
    }

    @Test(arguments: ["(--password syntheticOpaque", "(--token syntheticOpaque", "(--password"])
    func genericCommandFramingPreservesOptions(_ body: String) {
        let input = "\u{1B}" + body
        let result = Redactor.recoveredCredentialRanges(in: input, joined: TerminalControlGrammar.normalize(input), priorPrefixes: [])
        #expect(result.contexts.contains(body))
    }

    @Test(arguments: ["ghp_synthetic", "--password opaque", "remote=//user:opaque@host",
                      "Authorization: opaque", "device_code: opaque", "-----BEGIN PRIVATE KEY-----"])
    func independentCredentialOpenersRemainRecognizable(_ suffix: String) {
        #expect(Redactor.terminalHasCredentialOpener(suffix[...]))
    }

    @Test(arguments: [60, 70, 256], ["\u{1B}[31", "\u{9B}31", "\u{1B}"])
    func longPendingPEMEvidenceIsQuarantined(_ length: Int, _ command: String) {
        var continuation: TerminalControlEvidence.Continuation?
        let result = TerminalControlEvidence.prepare(
            "-----BEGIN " + String(repeating: "X", count: length) + " PRIVATE" + command,
            continuation: &continuation)
        #expect(result.text == "[redacted:terminal-ambiguity]")
        #expect(continuation?.quarantined == true)
        #expect(continuation?.prefixes.isEmpty == true)
    }

    @Test(arguments: ["\u{1B}[@", "\u{9B}@", "\u{1B}@"],
          ["The login code is ", "The login code was rejected; retry "])
    func restoredTrailingBoundariesProtectContextualCodes(_ command: String, _ context: String) throws {
        let input = context + "AB12-CD34" + command + "filename"
        let joined = TerminalControlGrammar.normalize(input)
        let span = try #require(Redactor.recoveredCredentialRanges(in: input, joined: joined, priorPrefixes: [])
            .ranges.first(where: { $0.kind == "device-code" }))
        #expect(String(decoding: Array(joined.utf8)[span.range], as: UTF8.self) == "AB12-CD34")
    }

    @Test(arguments: ["\u{1B}[31@", "\u{9B}31@", "\u{1B}@"],
          ["sk-abcdefghijklmnopq", "Bearer syntheticToken", "Basic dXNlcjpwYXNz"])
    func restoredLeadingBoundariesAreCredentialEvidence(_ escape: String, _ token: String) {
        let input = "filename" + escape + token
        let joined = TerminalControlGrammar.normalize(input)
        let ranges = Redactor.recoveredCredentialRanges(in: input, joined: joined, priorPrefixes: []).ranges
        #expect(ranges.contains(where: {
            String(decoding: Array(joined.utf8)[$0.range], as: UTF8.self) == token
        }))
    }

    @Test(arguments: ["\u{1B}", "\u{1B}[31", "\u{9B}31"])
    func restoredCodeContextProtectsAnUnmodifiedValue(_ escape: String) throws {
        let input = "The login co" + escape + "de was rejected; retry AB12-CD34."
        let joined = TerminalControlGrammar.normalize(input)
        let span = try #require(Redactor.recoveredCredentialRanges(in: input, joined: joined, priorPrefixes: [])
            .ranges.first(where: { $0.kind == "device-code" }))
        #expect(String(decoding: Array(joined.utf8)[span.range], as: UTF8.self) == "AB12-CD34")
    }

    @Test(arguments: ["\u{1B}[31", "\u{9B}31"])
    func ordinaryCoverageRequiresAnActualCredentialBoundary(_ escape: String) throws {
        let input = "filename" + escape + "@sk-" + escape + "abcdefghijklmnopq done"
        let joined = TerminalControlGrammar.normalize(input)
        let span = try #require(Redactor.recoveredCredentialRanges(in: input, joined: joined, priorPrefixes: [])
            .ranges.first(where: { $0.kind == "api-key" }))
        #expect(String(decoding: Array(joined.utf8)[span.range], as: UTF8.self) == "sk-bcdefghijklmnopq")
    }

    @Test(arguments: ["\u{1B}--pass\u{1B}[31word syntheticOpaque",
                      "\u{1B}--passw\u{1B}[31ord syntheticOpaque"])
    func mixedOptionsProduceScanOnlyContexts(_ input: String) {
        let result = Redactor.recoveredCredentialRanges(in: input, joined: TerminalControlGrammar.normalize(input), priorPrefixes: [])
        #expect(result.contexts.contains("--password syntheticOpaque"))
    }

    @Test func deviceCodeOffsetsCoverOnlySurvivingValueBytes() throws {
        let input = "The login code was rejected; retry AB12-\u{1B}CD34."
        let joined = TerminalControlGrammar.normalize(input)
        let span = try #require(Redactor.recoveredCredentialRanges(in: input, joined: joined, priorPrefixes: []).ranges.first)
        #expect(span.kind == "device-code")
        #expect(String(decoding: Array(joined.utf8)[span.range], as: UTF8.self) == "AB12-D34")
    }

    @Test func priorPrefixEvidenceProjectsOntoOnlyTheCurrentRecord() throws {
        let input = "\u{1B}[31k-abcdefghijklmnop"
        let joined = TerminalControlGrammar.normalize(input)
        let span = try #require(Redactor.recoveredCredentialRanges(in: input, joined: joined, priorPrefixes: [.init(text: "s")]).ranges.first)
        #expect(span.kind == "api-key")
        #expect(span.range == 0..<joined.utf8.count)
    }

    @Test func opaquePayloadCannotBecomeCredentialEvidence() {
        let input = "before\u{1B}]password: syntheticOpaque\u{7}after"
        let result = Redactor.recoveredCredentialRanges(in: input, joined: "beforeafter", priorPrefixes: [])
        #expect(result.ranges.isEmpty)
        #expect(result.contexts.isEmpty)
    }

    @Test func overBudgetAlternativesConcealTheCurrentVisibleRecord() {
        let input = String(repeating: "\u{1B}[31m", count: 8) + "opaque"
        let result = Redactor.recoveredCredentialRanges(in: input, joined: "opaque", priorPrefixes: [])
        #expect(result.ranges.map(\.range) == [0..<6])
        #expect(result.ranges.map(\.kind) == ["terminal-ambiguity"])
    }
}
