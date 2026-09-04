import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct TartParserHardeningTests {
    let token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"

    @Test func versionDecodingAppliesTheStrictParse() throws {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TartVersion.self, from: Data(#""2.36""#.utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TartVersion.self, from: Data(#"{"semantic":"2.36"}"#.utf8)) }
        let decoded = try JSONDecoder().decode(TartVersion.self, from: Data(#""2.36.0""#.utf8))
        #expect(decoded.matchesPin)
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(encoded == #""2.36.0""#, "\(encoded)")
    }

    @Test func leadingZerosAndBareDeviceCodesDoNotSlipThrough() {
        #expect(TartVersion(parsing: "02.036.000") == nil)
        #expect(TartVersion(parsing: "2.36.00") == nil)
        #expect(TartVersion(parsing: "0.36.0") != nil)
        guard case .unknown(let line) = TartErrorClassifier.classify(stderr: "ABCD-EFGH\u{1B}[0m " + String(repeating: "x", count: 500), exitStatus: 1) else { Issue.record("expected unknown"); return }
        #expect(line.text.hasPrefix("[redacted:device-code]"))
        #expect(!line.text.contains("\u{1B}"))
        #expect(line.text.unicodeScalars.count <= 201)
    }

    @Test func prefixesAreMutuallyExclusive() {
        #expect(TartVersion(parsing: "tart v2.36.0") == nil)
        #expect(TartVersion(parsing: "vv2.36.0") == nil)
        #expect(TartVersion(parsing: "tart 2.36.0")?.matchesPin == true)
        #expect(TartVersion(parsing: "Tart 2.36.0")?.matchesPin == true)
        #expect(TartVersion(parsing: "v2.36.0")?.matchesPin == true)
        #expect(TartVersion(parsing: "V2.36.0") == nil)
    }

    @Test func classifierMatchesTartsOwnPhrasesOnly() {
        #expect(TartErrorClassifier.classify(stderr: #"Error: VM "guesthouse-x" is already running!"#, exitStatus: 1) == .alreadyRunning)
        if case .alreadyRunning = TartErrorClassifier.classify(stderr: "Error: registry mirror is already running", exitStatus: 1) {
            Issue.record("an unrelated component being already running is not the VM")
        }
        #expect(TartErrorClassifier.classify(stderr: "Error: disk.img seems to be already in use, unmount it first in Finder", exitStatus: 1) == .diskInUse)
        #expect(TartErrorClassifier.classify(stderr: #"Error: already in use, try umounting it via "diskutil unmountDisk""#, exitStatus: 1) == .diskInUse)
        if case .diskInUse = TartErrorClassifier.classify(stderr: "Error: disk cache is in use by another download", exitStatus: 1) {
            Issue.record("a cache being in use is not the VM disk image")
        }
    }

    @Test func stateClassificationsAreAnchoredToTheVMPhrases() {
        #expect(TartErrorClassifier.classify(stderr: #"Error: VM "guesthouse-x" is not running"#, exitStatus: 1) == .notRunning)
        #expect(TartErrorClassifier.classify(stderr: #"Error: VM "guesthouse-x" is running"#, exitStatus: 1) == .requiresStoppedVM)
        for unrelated in ["registry mirror is not running", "registry mirror is running", "the cache must be stopped"] {
            if case .unknown = TartErrorClassifier.classify(stderr: unrelated, exitStatus: 1) {} else {
                Issue.record("\(unrelated) should stay unknown")
            }
        }
    }

    @Test func onlyThePinnedSourceSpellingsAreAccepted() throws {
        func entry(_ source: String) -> Data {
            Data(#"[{"Source":"\#(source)","Name":"x","Disk":1,"Size":1,"Accessed":"2026-01-01T00:00:00Z","Running":false,"State":"stopped"}]"#.utf8)
        }
        #expect(try TartListParser.parse(entry("local")).first?.source == .local)
        #expect(try TartListParser.parse(entry("OCI")).first?.source == .oci)
        for bad in ["LOCAL", "Local", "oci"] {
            #expect(throws: TartParseError.unknownValue(field: "Source", value: bad)) { try TartListParser.parse(entry(bad)) }
        }
    }

    @Test func versionsAlwaysHaveThreeComponentsAndRoundTrip() throws {
        let short = TartVersion(SemanticVersion([2, 36]))
        #expect(short.description == "2.36.0")
        #expect(short.matchesPin)
        let decoded = try JSONDecoder().decode(TartVersion.self, from: try JSONEncoder().encode(short))
        #expect(decoded == short)
    }

    @Test func parserErrorsCarryNoRawValues() {
        let unknownSource = #"[{"Source":"\#(token)","Name":"x","Disk":1,"Size":1,"Accessed":"2026-01-01T00:00:00Z","Running":false,"State":"stopped"}]"#
        let parseError = #expect(throws: TartParseError.self) { try TartListParser.parse(Data(unknownSource.utf8)) }
        guard case .unknownValue(let field, let value)? = parseError else { Issue.record("expected unknownValue, got \(String(describing: parseError))"); return }
        #expect(field == "Source")
        #expect(!value.contains(token))
        #expect(value.contains("[redacted:github-token]"))

        let decodingError = #expect(throws: DecodingError.self) { try JSONDecoder().decode(GuestIPAddress.self, from: Data(#""\#(token)""#.utf8)) }
        guard case .dataCorrupted(let context)? = decodingError else { Issue.record("expected dataCorrupted"); return }
        #expect(!context.debugDescription.contains(token))
    }

    @Test func fragmentsOfUnrelatedDiagnosticsStayUnknown() {
        for stderr in ["Error: no IP address found in registry metadata", "failed to inspect the specified VM\nOCI manifest does not exist"] {
            if case .unknown = TartErrorClassifier.classify(stderr: stderr, exitStatus: 1) {} else {
                Issue.record("\(stderr) should stay unknown")
            }
        }
        #expect(TartErrorClassifier.classify(stderr: "Error: no IP address found, is your VM running?", exitStatus: 1) == .noIPAddress)
        #expect(TartErrorClassifier.classify(stderr: #"Error: the specified VM "guesthouse-x" does not exist"#, exitStatus: 1) == .vmNotFound)
    }

    @Test func anEntryWhoseRunningFlagContradictsItsStateIsRejected() throws {
        func entry(_ running: String, _ state: String) -> Data {
            Data(#"[{"Source":"local","Name":"x","Disk":1,"Size":1,"Accessed":"2026-01-01T00:00:00Z","Running":\#(running),"State":"\#(state)"}]"#.utf8)
        }
        #expect(throws: TartParseError.unknownValue(field: "Running", value: "true")) { try TartListParser.parse(entry("true", "stopped")) }
        #expect(throws: TartParseError.unknownValue(field: "Running", value: "true")) { try TartListParser.parse(entry("true", "suspended")) }
        #expect(throws: TartParseError.unknownValue(field: "Running", value: "false")) { try TartListParser.parse(entry("false", "running")) }
        #expect(try TartListParser.parse(entry("false", "suspended")).first?.state == .suspended)
        #expect(try TartListParser.parse(entry("true", "running")).first?.running == true)
    }

    @Test(arguments: [TartParseError.notJSON, .unexpectedShape("Accessed"), .unknownValue(field: "State", value: "hibernating"), .notAnIPAddress, .notAVersion])
    func everyParseFailureBecomesAnActionableError(error: TartParseError) {
        let surfaced = error.guesthouseError
        #expect(!surfaced.userMessage.isEmpty)
        #expect(surfaced.userMessage.contains(TartPin.releaseTag))
        #expect(surfaced.recoveryActions.contains(.repair(.runtime)))
    }

    @Test func aParseFailureCarriesNoRawValueIntoItsMessage() {
        let message = TartParseError.unknownValue(field: "Source", value: token).guesthouseError.userMessage
        #expect(!message.contains(token))
        #expect(message.contains("[redacted:github-token]"))
    }

    @Test func theVersionKeepsAllThreeComponents() {
        #expect(TartPin.version.components == [2, 36, 0])
        #expect(TartVersion(SemanticVersion([2, 36])).components == [2, 36, 0])
        #expect(TartVersion(parsing: "2.36.0")?.components == [2, 36, 0])
        #expect(TartPin.version.semantic == SemanticVersion([2, 36]), "the comparable form drops trailing zeros, and says so")
    }

    @Test func thePublicTartNamespacesAreSendable() {
        func requiringSendable<T: Sendable>(_ type: T.Type) {}
        requiringSendable(TartPin.self)
        requiringSendable(TartListParser.self)
        requiringSendable(TartIPParser.self)
        requiringSendable(TartErrorClassifier.self)
    }

    @Test func accessedIsPartOfThePinnedShape() throws {
        let missing = #"[{"Source":"local","Name":"x","Disk":1,"Size":1,"Running":false,"State":"stopped"}]"#
        #expect(throws: TartParseError.unexpectedShape("Accessed")) { try TartListParser.parse(Data(missing.utf8)) }
        let unparseable = #"[{"Source":"local","Name":"x","Disk":1,"Size":1,"Accessed":"yesterday","Running":false,"State":"stopped"}]"#
        #expect(try TartListParser.parse(Data(unparseable.utf8)).first?.accessed == nil)
    }
}
