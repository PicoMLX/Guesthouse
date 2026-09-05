import Foundation
import Testing
@testable import GuesthouseCore

/// MVP-PLAN.md §6 seeds the wrapper from the whole canonical lockfile, so an
/// invalid unselected pin must block decoding just as an invalid selected pin does.
@Suite struct ResolvedPackagesGrammarTests {
    private func pin(
        identity: String = "unselected",
        kind: String = "remoteSourceControl",
        location: String = "https://github.com/Org/Unselected.git",
        version: String = "1.2.3"
    ) -> [String: Any] {
        ["identity": identity, "kind": kind, "location": location,
         "state": ["revision": "0123456789abcdef0123456789abcdef01234567", "version": version]]
    }

    private func lockfile(
        format: Int,
        pins: [[String: Any]],
        originHashJSON: String? = nil
    ) throws -> Data {
        var root: [String: Any] = ["version": format, "pins": pins]
        if let originHashJSON {
            root["originHash"] = try JSONSerialization.jsonObject(
                with: Data(originHashJSON.utf8), options: .fragmentsAllowed
            )
        }
        return try JSONSerialization.data(withJSONObject: root, options: .sortedKeys)
    }

    @Test(arguments: [2, 3], [
        "1.2.3-", "1.2.3+", "1.2.3-+", "1.2.3-alpha..beta", "1.2.3+build..meta",
        "1.2.3-..", "1.2.3+..", "1.2.3--", "01.002.0003", "\(Int.max).0.0",
    ])
    func acceptsSwiftPMVersionSpellingsWithoutChangingThem(_ format: Int, version: String) throws {
        let data = try lockfile(format: format, pins: [pin(version: version)])
        #expect(try ResolvedPackagesFile.decode(data).pins.first?.version == version)
    }

    @Test(arguments: [2, 3], [
        "1.2", "1.2.3.4", "1..3", "1.2.3-rc_1", "1.2.3+meta+more", "1.2.3-β",
        "1.2.3+méta", "1.2.3 ", "-1.2.3", "\(Int.max)0.0.0", "0.\(Int.max)0.0",
    ])
    func rejectsVersionsSwiftPMCannotParse(_ format: Int, version: String) throws {
        let data = try lockfile(format: format, pins: [pin(version: version)])
        #expect(throws: ResolvedPackagesError.malformed("state.version")) {
            try ResolvedPackagesFile.decode(data)
        }
    }

    @Test(arguments: ["123", "true", "[]", "{}"])
    func version3RejectsNonStringOriginHashes(_ originHashJSON: String) throws {
        let data = try lockfile(format: 3, pins: [pin()], originHashJSON: originHashJSON)
        #expect(throws: ResolvedPackagesError.malformed("originHash")) {
            try ResolvedPackagesFile.decode(data)
        }
    }

    @Test(arguments: [nil, "null", #""""#, #""a-swiftpm-origin-hash""#] as [String?])
    func version3AcceptsAbsentNullAndStringOriginHashes(_ originHashJSON: String?) throws {
        let data = try lockfile(format: 3, pins: [pin()], originHashJSON: originHashJSON)
        #expect(try ResolvedPackagesFile.decode(data).pins.count == 1)
    }

    @Test func version2DoesNotInterpretTheVersion3OriginHashField() throws {
        let data = try lockfile(format: 2, pins: [pin()], originHashJSON: "123")
        #expect(try ResolvedPackagesFile.decode(data).pins.count == 1)
    }

    @Test(arguments: [2, 3], ["fileSystem", "futureKind"])
    func rejectsKindsThatAreNotRecordedAsResolvedPins(_ format: Int, kind: String) throws {
        let data = try lockfile(format: format, pins: [pin(kind: kind)])
        #expect(throws: ResolvedPackagesError.unknownKind(kind)) {
            try ResolvedPackagesFile.decode(data)
        }
    }

    @Test(arguments: [2, 3], ["", ".", "../LocalKit", "LocalKit", "~/LocalKit", "file:///LocalKit"])
    func localSourceControlRequiresAnAbsolutePath(_ format: Int, location: String) throws {
        let data = try lockfile(format: format, pins: [pin(kind: "localSourceControl", location: location)])
        #expect(throws: ResolvedPackagesError.malformed("location")) {
            try ResolvedPackagesFile.decode(data)
        }
    }

    @Test(arguments: [2, 3], ["/", "/Users/dev/ Local Kit ", "/Users/dev/CaféKit", "/Users/dev/../LocalKit"])
    func localSourceControlKeepsAcceptedAbsolutePathSpellings(_ format: Int, location: String) throws {
        let data = try lockfile(format: format, pins: [pin(kind: "localSourceControl", location: location)])
        let decoded = try ResolvedPackagesFile.decode(data)
        #expect(decoded.pins.first?.location == location)
        #expect(decoded.pins.first?.kind == .localSourceControl)
    }

    @Test(arguments: [2, 3], ["unselected", "Unselected"])
    func duplicateUnselectedIdentitiesRejectTheWholeLockfile(_ format: Int, duplicateIdentity: String) throws {
        let data = try lockfile(format: format, pins: [
            pin(identity: "selected", location: "https://github.com/Org/Selected.git"),
            pin(),
            pin(identity: duplicateIdentity, kind: "localSourceControl", location: "/Users/dev/Unselected"),
        ])
        #expect(throws: ResolvedPackagesError.malformed("pins.identity (duplicate)")) {
            try ResolvedPackagesFile.decode(data)
        }
    }

    @Test(arguments: [2, 3])
    func validUnselectedPinsDoNotHideAnUnknownSelectedOrigin(_ format: Int) throws {
        let remote = try #require(RemoteURL("https://github.com/Org/Selected"))
        let selected = WorkspaceRepository(
            role: .package, remote: remote,
            baseBranch: try #require(BranchName("main")), taskBranch: try #require(BranchName("task"))
        )
        let data = try lockfile(format: format, pins: [
            pin(identity: "selected", location: "https://github.com/Org/Selected.git"),
            pin(kind: "localSourceControl", location: "/Users/dev/Unselected"),
            pin(identity: "registrykit", kind: "registry", location: ""),
        ])
        let decoded = try ResolvedPackagesFile.decode(data)
        #expect(LocalOverrideMatcher.match(selected: [selected], resolved: decoded, observedOrigins: [:]) == [
            .originUnknown(identity: PackageIdentity(remote: remote), checkout: selected.checkoutName.rawValue),
        ])
    }
}
