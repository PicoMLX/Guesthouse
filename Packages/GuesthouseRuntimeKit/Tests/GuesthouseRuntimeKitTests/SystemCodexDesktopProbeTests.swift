import CoreServices
import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

struct SystemCodexDesktopProbeTests {
    @Test(arguments: [
        (nil as String?, nil as Int?, SystemCodexDesktopProbe.Candidate.unavailable),
        (NSOSStatusErrorDomain, Int(kLSApplicationNotFoundErr), .notFound),
        (NSOSStatusErrorDomain, Int(kLSUnknownErr), .unavailable),
        ("different-domain", Int(kLSApplicationNotFoundErr), .unavailable),
        (nil, Int(kLSApplicationNotFoundErr), .unavailable), (NSOSStatusErrorDomain, nil, .unavailable),
    ])
    func onlyExplicitApplicationAbsenceBecomesNotFound(_ values: (String?, Int?, SystemCodexDesktopProbe.Candidate)) {
        #expect(SystemCodexDesktopProbe.candidate(urls: nil, errorDomain: values.0, errorCode: values.1) == values.2)
    }

    @Test func lookupKeepsPreferredOrderAndRefusesContradictionsOrExcess() {
        let first = URL(fileURLWithPath: "/Applications/Renamed Desktop.app")
        let second = URL(fileURLWithPath: "/Applications/Another Copy.app")
        #expect(SystemCodexDesktopProbe.candidate(urls: [first, second], errorDomain: nil, errorCode: nil) == .preferred(first))
        #expect(SystemCodexDesktopProbe.candidate(urls: Array(repeating: first, count: 32),
                                                 errorDomain: nil, errorCode: nil) == .preferred(first))
        #expect(SystemCodexDesktopProbe.candidate(urls: [], errorDomain: nil, errorCode: nil) == .unavailable)
        #expect(SystemCodexDesktopProbe.candidate(urls: [first], errorDomain: NSOSStatusErrorDomain,
                                                 errorCode: Int(kLSApplicationNotFoundErr)) == .unavailable)
        #expect(SystemCodexDesktopProbe.candidate(urls: Array(repeating: first, count: 33),
                                                 errorDomain: nil, errorCode: nil) == .unavailable)
    }

    @Test(arguments: [
        (SystemCodexDesktopProbe.Candidate.notFound, CodexDesktopObservation.notFound),
        (.unavailable, .unavailable),
    ])
    func anUnselectedApplicationNeverReadsMetadata(_ values: (SystemCodexDesktopProbe.Candidate, CodexDesktopObservation)) {
        let probe = SystemCodexDesktopProbe(lookup: { values.0 }, metadata: { _ in
            Issue.record("No application was selected; metadata must not be read."); return nil
        })
        #expect(probe.observe() == values.1)
    }

    @Test func unreadableRegisteredApplicationIsUnavailableNotAbsent() {
        let probe = SystemCodexDesktopProbe(
            lookup: { .preferred(URL(fileURLWithPath: "/Applications/Fixture.app")) }, metadata: { _ in nil }
        )
        #expect(probe.observe() == .unavailable)
    }

    @Test func identifiedBundleKeepsVersionsWithoutUsingItsDisplayName() throws {
        let data = try plist(["CFBundleIdentifier": "com.openai.codex", "CFBundleName": "ChatGPT",
                              "CFBundleShortVersionString": "26.4.1", "CFBundleVersion": "456"])
        #expect(SystemCodexDesktopProbe.decodeMetadata(data) == .installed(version: SemanticVersion([26, 4, 1]),
                                                                           build: SemanticVersion([456])))
    }

    @Test(arguments: ["com.openai.chat", "com.example.Codex", "COM.OPENAI.CODEX", ""])
    func anotherBundleIDCannotBeAcceptedBecauseOfItsName(identifier: String) throws {
        let data = try plist(["CFBundleIdentifier": identifier, "CFBundleName": "Codex"])
        #expect(SystemCodexDesktopProbe.decodeMetadata(data) == .unavailable)
    }

    @Test func missingIdentityCannotBeReplacedByVersionMetadata() throws {
        let data = try plist(["CFBundleName": "Codex", "CFBundleShortVersionString": "1.2"])
        #expect(SystemCodexDesktopProbe.decodeMetadata(data) == .unavailable)
    }

    @Test func missingOrWrongTypeVersionMetadataDoesNotEraseAnIdentifiedApp() throws {
        let absent = try plist(["CFBundleIdentifier": "com.openai.codex"])
        let wrongType = try plist(["CFBundleIdentifier": "com.openai.codex", "CFBundleShortVersionString": 123,
                                   "CFBundleVersion": ["opaque": true]])
        #expect(SystemCodexDesktopProbe.decodeMetadata(absent) == .installed(version: nil, build: nil))
        #expect(SystemCodexDesktopProbe.decodeMetadata(wrongType) == .installed(version: nil, build: nil))
    }

    @Test(arguments: ["", "1.2\n.3", "Bearer synthetic-value", String(repeating: "1", count: 257)])
    func nonconformingVersionIsUnknownWhileTheBuildRemainsKnown(version: String) throws {
        let data = try plist(["CFBundleIdentifier": "com.openai.codex", "CFBundleShortVersionString": version,
                              "CFBundleVersion": "456", "opaqueExtra": "untrusted metadata"])
        let observation = SystemCodexDesktopProbe.decodeMetadata(data)
        #expect(observation == .installed(version: nil, build: SemanticVersion([456])))
        #expect(!String(decoding: try JSONEncoder().encode(observation), as: UTF8.self).contains("untrusted"))
    }

    @Test func malformedOversizedAndNonDictionaryPlistsAreUnavailable() throws {
        #expect(SystemCodexDesktopProbe.decodeMetadata(nil) == .unavailable)
        #expect(SystemCodexDesktopProbe.decodeMetadata(Data("not a plist".utf8)) == .unavailable)
        let array = try PropertyListSerialization.data(fromPropertyList: ["not a dictionary"], format: .binary, options: 0)
        #expect(SystemCodexDesktopProbe.decodeMetadata(array) == .unavailable)
        #expect(SystemCodexDesktopProbe.decodeMetadata(Data(repeating: 32, count: 131_073)) == .unavailable)
    }

    @Test func regularMetadataAtTheLimitCanBeReadWithoutANameAssumption() throws {
        try withApplication { application, info in
            var data = try plist(["CFBundleIdentifier": "com.openai.codex"])
            try #require(data.count < 131_072)
            data.append(Data(repeating: 32, count: 131_072 - data.count))
            try data.write(to: info)
            let read = try #require(SystemCodexDesktopProbe.readMetadata(at: application))
            #expect(read == data)
            #expect(SystemCodexDesktopProbe.decodeMetadata(read) == .installed(version: nil, build: nil))
            let probe = SystemCodexDesktopProbe(lookup: { .preferred(application) },
                                                metadata: { SystemCodexDesktopProbe.readMetadata(at: $0) })
            #expect(probe.observe() == .installed(version: nil, build: nil))
        }
    }

    @Test func oversizedMetadataIsRefusedBeforeParsing() throws {
        try withApplication { application, info in
            try Data(repeating: 32, count: 131_073).write(to: info)
            #expect(SystemCodexDesktopProbe.readMetadata(at: application) == nil)
        }
    }

    @Test func missingAndDirectoryMetadataAreUnavailable() throws {
        try withApplication { application, info in
            #expect(SystemCodexDesktopProbe.readMetadata(at: application) == nil)
            try FileManager.default.createDirectory(at: info, withIntermediateDirectories: false)
            #expect(SystemCodexDesktopProbe.readMetadata(at: application) == nil)
        }
    }

    @Test func finalMetadataSymlinkIsNotFollowed() throws {
        try withApplication { application, info in
            let target = application.appendingPathComponent("Other.plist")
            try plist(["CFBundleIdentifier": "com.openai.codex"]).write(to: target)
            try FileManager.default.createSymbolicLink(at: info, withDestinationURL: target)
            #expect(SystemCodexDesktopProbe.readMetadata(at: application) == nil)
        }
    }

    @Test func fifoMetadataIsRefusedWithoutWaitingForAWriter() throws {
        try withApplication { application, info in
            try #require(mkfifo(info.path, 0o600) == 0)
            #expect(SystemCodexDesktopProbe.readMetadata(at: application) == nil)
        }
    }

    @Test(arguments: [
        "https://example.invalid/Fixture.app", "file://remote-host/Fixture.app",
        "file:///tmp/Fixture.app?query=1", "file:///tmp/Fixture.app#fragment", "file:///tmp/Bad%00.app",
    ])
    func nonLocalOrMalformedLocationsAreNotRead(value: String) throws {
        let url = try #require(URL(string: value))
        #expect(SystemCodexDesktopProbe.readMetadata(at: url) == nil)
    }

    @Test func nativeDiscoveryReturnsOnlyABoundedTypedObservation() throws {
        // Read-only OS lookup; no app is opened, signed or authenticated and no installed
        // application is assumed. This does not prove desktop/SSH connection compatibility.
        let observation = SystemCodexDesktopProbe().observe()
        #expect(try JSONEncoder().encode(observation).count < 1024)
    }

    private func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    private func withApplication(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GuesthouseCodexProbe-" + UUID().uuidString)
        let application = root.appendingPathComponent("Renamed Desktop.app", isDirectory: true)
        let contents = application.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(application, contents.appendingPathComponent("Info.plist"))
    }
}
