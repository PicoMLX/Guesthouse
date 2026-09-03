import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct TartParserTests {
    func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/tart-2.36.0"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func parsesListFixture() throws {
        let vms = try TartListParser.parse(fixture("list.json"))
        #expect(vms.count == 3)
        #expect(vms[0].source == .local)
        #expect(vms[0].name == "guesthouse-1a2b3c4d-0000-4000-8000-000000000001")
        #expect(vms[0].diskGigabytes == 160)
        #expect(vms[0].sizeGigabytes == 42)
        #expect(vms[0].running)
        #expect(vms[0].state == .running)
        #expect(vms[0].accessed == Date(timeIntervalSince1970: 1_788_418_800))
        #expect(vms[1].source == .oci)
        #expect(vms[1].state == .stopped)
        #expect(vms[2].state == .suspended)
        #expect(vms[2].accessed == nil, "non-ISO access dates are tolerated as unknown")
    }

    @Test func rejectsMalformedLists() throws {
        #expect(throws: TartParseError.notJSON) { try TartListParser.parse("not json") }
        #expect(throws: TartParseError.unexpectedShape("expected an array of objects")) { try TartListParser.parse("{\"Name\": \"x\"}") }
        #expect(throws: TartParseError.unexpectedShape("Disk")) { try TartListParser.parse("[{\"Source\":\"local\",\"Name\":\"x\",\"Disk\":\"160 GB\",\"Size\":1,\"Accessed\":\"2026-01-01T00:00:00Z\",\"Running\":false,\"State\":\"stopped\"}]") }
        #expect(throws: TartParseError.unknownValue(field: "State", value: "hibernating")) { try TartListParser.parse("[{\"Source\":\"local\",\"Name\":\"x\",\"Disk\":1,\"Size\":1,\"Accessed\":\"2026-01-01T00:00:00Z\",\"Running\":false,\"State\":\"hibernating\"}]") }
        #expect(throws: TartParseError.unknownValue(field: "Source", value: "cloud")) { try TartListParser.parse("[{\"Source\":\"cloud\",\"Name\":\"x\",\"Disk\":1,\"Size\":1,\"Accessed\":\"2026-01-01T00:00:00Z\",\"Running\":false,\"State\":\"stopped\"}]") }
        #expect(try TartListParser.parse("[]").isEmpty)
        #expect(try TartListParser.parse(fixture("list-empty.json")).isEmpty, "real capture of an empty store")
        #expect(throws: TartParseError.unknownValue(field: "Disk", value: "-1")) { try TartListParser.parse("[{\"Source\":\"local\",\"Name\":\"x\",\"Disk\":-1,\"Size\":1,\"Accessed\":\"2026-01-01T00:00:00Z\",\"Running\":false,\"State\":\"stopped\"}]") }
        #expect(throws: TartParseError.unexpectedShape("Disk")) { try TartListParser.parse("[{\"Source\":\"local\",\"Name\":\"x\",\"Disk\":true,\"Size\":1,\"Accessed\":\"2026-01-01T00:00:00Z\",\"Running\":false,\"State\":\"stopped\"}]") }
        #expect(throws: TartParseError.unexpectedShape("Running")) { try TartListParser.parse("[{\"Source\":\"local\",\"Name\":\"x\",\"Disk\":1,\"Size\":1,\"Accessed\":\"2026-01-01T00:00:00Z\",\"Running\":1,\"State\":\"stopped\"}]") }
    }

    @Test func parsesVersionsAndComparesWithThePin() throws {
        #expect(try TartVersion(parsing: fixture("version.txt")) == TartPin.version)
        #expect(TartVersion(parsing: "v2.36.0")?.matchesPin == true)
        #expect(TartVersion(parsing: "tart 2.36.0\n")?.matchesPin == true)
        #expect(TartVersion(parsing: "2.36.1")! > TartPin.version)
        #expect(TartVersion(parsing: "2.35.9")! < TartPin.version)
        #expect(TartVersion(parsing: "") == nil)
        #expect(TartVersion(parsing: "tart: command not found") == nil)
        #expect(TartVersion(parsing: "2.36.0-beta") == nil)
        #expect(TartVersion(parsing: "2.36") == nil, "two components are not the pinned form")
        #expect(TartVersion(parsing: "2.36.0\nwarning: something") == nil, "extra lines are not a version")
        #expect(TartVersion(parsing: "2.36.0 extra") == nil)
        #expect(TartVersion(parsing: TartPin.releaseTag) == TartPin.version)
        #expect(TartPin.version.description == "2.36.0", "the patch component is preserved for exact comparisons")
    }

    @Test func parsesExactlyOneIPAddress() throws {
        let v4 = try TartIPParser.parse(fixture("ip.txt"))
        #expect(v4.rawValue == "192.168.64.5")
        #expect(v4.family == .ipv4)
        let v6 = try TartIPParser.parse("fd12:3456::1\n")
        #expect(v6.family == .ipv6)
        #expect(throws: TartParseError.notAnIPAddress) { try TartIPParser.parse("") }
        #expect(throws: TartParseError.notAnIPAddress) { try TartIPParser.parse("192.168.64.5\n192.168.64.6\n") }
        #expect(throws: TartParseError.notAnIPAddress) { try TartIPParser.parse("999.1.1.1") }
        #expect(throws: TartParseError.notAnIPAddress) { try TartIPParser.parse(fixture("ip-error.txt")) }
        #expect(GuestIPAddress("192.168.64.5 extra") == nil)
        #expect(GuestIPAddress("192.168.64.5\u{0}junk") == nil)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(GuestIPAddress.self, from: Data("\"192.168.64.5\\u0000junk\"".utf8)) }
        let encoded = try JSONEncoder().encode(v4)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"192.168.64.5\"")
        #expect(try JSONDecoder().decode(GuestIPAddress.self, from: encoded) == v4)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(GuestIPAddress.self, from: Data("\"not-an-ip\"".utf8)) }
    }

    @Test func classifiesKnownFailures() throws {
        let cases: [(String, TartFailure)] = [
            ("Error: the specified VM \"guesthouse-x\" does not exist", .vmNotFound),
            (try fixture("vm-does-not-exist.txt"), .vmNotFound),
            ("VM \"guesthouse-x\" is already running!", .alreadyRunning),
            ("VM \"guesthouse-x\" is not running", .notRunning),
            (try fixture("ip-error.txt"), .noIPAddress),
            ("failed to lock /Users/dev/.tart/vms/x/lock: Resource temporarily unavailable", .lockHeld),
            ("VM directory is already initialized, preventing overwrite", .directoryAlreadyInitialized),
            ("VM \"guesthouse-x\" must be stopped before resizing its disk", .requiresStoppedVM),
            ("VM \"guesthouse-x\" is running", .requiresStoppedVM),
            ("The number of VMs exceeds the system limit (other running VMs: a, b)", .virtualMachineLimitExceeded),
        ]
        for (stderr, expected) in cases {
            #expect(TartErrorClassifier.classify(stderr: stderr, exitStatus: 1) == expected, Comment(rawValue: stderr))
        }
    }

    @Test func lookalikePhrasesStayUnknown() {
        for stderr in ["manifest ghcr.io/x/y:latest does not exist", "failed to open lock file /x/lock: Permission denied", "registry rate limit exceeded, retry later", "OCI cache is already initialized"] {
            guard case .unknown = TartErrorClassifier.classify(stderr: stderr, exitStatus: 1) else { Issue.record("misclassified: \(stderr)"); continue }
        }
    }

    @Test func unknownFailuresAreKeptOnlyInRedactedForm() {
        let failure = TartErrorClassifier.classify(stderr: "something odd with token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab\nsecond line", exitStatus: 3)
        guard case .unknown(let line) = failure else { Issue.record("expected unknown"); return }
        #expect(line.text == "something odd with token [redacted:github-token]")
        #expect(TartErrorClassifier.classify(stderr: "", exitStatus: 7) == .unknown(RedactedLine(literal: "exit status 7")))
    }
}
