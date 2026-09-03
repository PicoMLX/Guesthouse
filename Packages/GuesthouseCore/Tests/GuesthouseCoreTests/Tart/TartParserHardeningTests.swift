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

    @Test func accessedIsPartOfThePinnedShape() throws {
        let missing = #"[{"Source":"local","Name":"x","Disk":1,"Size":1,"Running":false,"State":"stopped"}]"#
        #expect(throws: TartParseError.unexpectedShape("Accessed")) { try TartListParser.parse(Data(missing.utf8)) }
        let unparseable = #"[{"Source":"local","Name":"x","Disk":1,"Size":1,"Accessed":"yesterday","Running":false,"State":"stopped"}]"#
        #expect(try TartListParser.parse(Data(unparseable.utf8)).first?.accessed == nil)
    }
}
