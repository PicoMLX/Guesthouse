import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct ResolvedPackagesFileTests {
    private let revision = String(repeating: "a", count: 40)
    private func data(version: Int = 3, pins: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": version, "pins": pins])
    }
    private func pin(kind: String = "remoteSourceControl", state: Any? = nil) -> [String: Any] {
        ["identity": kind == "registry" ? "scope.library" : "library", "kind": kind, "location": "https://github.com/Org/Library.git",
         "state": state ?? ["revision": revision, "branch": "main"]]
    }

    @Test(arguments: [2, 3])
    func decodesEachRecordedKindWithoutEnablingAnOverride(_ version: Int) throws {
        let remote = pin()
        var local = pin(kind: "localSourceControl", state: ["revision": revision, "version": "1.2.3"])
        local["identity"] = "local"; local["location"] = "/tmp/Local"
        var registry = pin(kind: "registry", state: ["version": "2.0.0"])
        registry["identity"] = "scope.registry"; registry["location"] = ""
        let decoded = try ResolvedPackagesFile.decode(data(version: version, pins: [remote, local, registry]))
        #expect(decoded.version == version && decoded.pins.map(\.kind) == [.remoteSourceControl, .localSourceControl, .registry])
        #expect(decoded.pins[0].revision == revision && decoded.pins[0].branch == "main")
        #expect(decoded.pins[1].version == "1.2.3" && decoded.pins[2].revision == nil)
    }

    @Test func rejectsEnvelopeAndSizeFailuresWithFixedGuidance() throws {
        #expect(throws: ResolvedPackagesError.tooLarge) { try ResolvedPackagesFile.decode(Data(repeating: 0, count: 1_048_577)) }
        for text in ["not json", "[]", "null"] {
            #expect(throws: ResolvedPackagesError.notJSON) { try ResolvedPackagesFile.decode(Data(text.utf8)) }
        }
        for text in [#"{"pins":[]}"#, #"{"version":true,"pins":[]}"#, #"{"version":"private-value","pins":[]}"#] {
            #expect(throws: ResolvedPackagesError.missingVersion) { try ResolvedPackagesFile.decode(Data(text.utf8)) }
        }
        for version in [1, 4] {
            #expect(throws: ResolvedPackagesError.unsupportedVersion) { try ResolvedPackagesFile.decode(data(version: version, pins: [])) }
        }
        for failure in [ResolvedPackagesError.notJSON, .tooLarge, .unknownKind, .malformed(.location), .unsupportedVersion] {
            #expect(!failure.userMessage.isEmpty && !failure.recoveryMessage.isEmpty && !failure.recoveryActions.isEmpty)
            #expect(!failure.userMessage.contains("private-value"))
        }
    }

    @Test func rejectsMissingAndIllTypedRequiredFields() throws {
        for (key, field) in [("identity", ResolvedPackagesError.Field.identity), ("kind", .kind), ("location", .location), ("state", .state)] {
            for replacement in [nil, 17, NSNull()] as [Any?] {
                var value = pin(); value[key] = replacement
                #expect(throws: ResolvedPackagesError.malformed(field)) { try ResolvedPackagesFile.decode(data(pins: [value])) }
            }
        }
        #expect(throws: ResolvedPackagesError.malformed(.pins)) { try ResolvedPackagesFile.decode(Data(#"{"version":3,"pins":{}}"#.utf8)) }
    }

    @Test func sourceControlRequiresFullCommitAndOptionalFieldsMustBeStrings() throws {
        for invalid in ["", "main", String(repeating: "0", count: 40), "abc"] {
            #expect(throws: ResolvedPackagesError.malformed(.revision)) {
                try ResolvedPackagesFile.decode(data(pins: [pin(state: ["revision": invalid])]))
            }
        }
        for (key, field) in [("revision", ResolvedPackagesError.Field.revision), ("version", .semanticVersion), ("branch", .branch)] {
            var state: [String: Any] = ["revision": revision]; state[key] = 42
            #expect(throws: ResolvedPackagesError.malformed(field)) { try ResolvedPackagesFile.decode(data(pins: [pin(state: state)])) }
        }
        #expect(throws: ResolvedPackagesError.malformed(.semanticVersion)) {
            try ResolvedPackagesFile.decode(data(pins: [pin(kind: "registry", state: ["revision": revision])]))
        }
    }
}
