import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct PackageIdentityTests {
    func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/swiftpm"))
        return try Data(contentsOf: url)
    }

    func package(_ remote: String) -> WorkspaceRepository {
        WorkspaceRepository(role: .package, remote: RemoteURL(remote)!, baseBranch: BranchName("main")!, taskBranch: BranchName("feature/1")!)
    }

    @Test func identityFollowsSwiftPMRules() {
        #expect(PackageIdentity(location: "https://github.com/PicoMLX/SharedUI.git")?.rawValue == "sharedui")
        #expect(PackageIdentity(location: "https://github.com/PicoMLX/SharedUI")?.rawValue == "sharedui")
        #expect(PackageIdentity(location: "git@github.com:PicoMLX/Shared-UI.GIT")?.rawValue == "shared-ui")
        #expect(PackageIdentity(location: "https://github.com/PicoMLX/SharedUI/")?.rawValue == "sharedui")
        #expect(PackageIdentity(location: "sharedui")?.rawValue == "sharedui")
        #expect(PackageIdentity(location: "") == nil)
        #expect(PackageIdentity(location: ".git") == nil)
        #expect(PackageIdentity(remote: RemoteURL("https://github.com/PicoMLX/ModelKit")!).rawValue == "modelkit")
    }

    @Test func decodesVersion3AndVersion2() throws {
        let v3 = try ResolvedPackagesFile.decode(fixture("Package.resolved.v3"))
        #expect(v3.version == 3)
        #expect(v3.pins.map(\.identity.rawValue) == ["sharedui", "modelkit", "swift-collections", "registrykit"])
        #expect(v3.pins[0].version == "1.4.0")
        #expect(v3.pins[1].branch == "main")
        #expect(v3.pins[3].kind == .registry)

        let v2 = try ResolvedPackagesFile.decode(fixture("Package.resolved.v2"))
        #expect(v2.version == 2)
        #expect(v2.pins[1].kind == .localSourceControl)
    }

    @Test func rejectsUnsupportedOrMalformedFiles() {
        #expect(throws: ResolvedPackagesError.notJSON) { try ResolvedPackagesFile.decode(Data("nope".utf8)) }
        #expect(throws: ResolvedPackagesError.missingVersion) { try ResolvedPackagesFile.decode(Data("{\"pins\":[]}".utf8)) }
        #expect(throws: ResolvedPackagesError.unsupportedVersion(1)) { try ResolvedPackagesFile.decode(Data("{\"version\":1,\"object\":{}}".utf8)) }
        #expect(throws: ResolvedPackagesError.unknownKind("mystery")) { try ResolvedPackagesFile.decode(Data("{\"version\":3,\"pins\":[{\"identity\":\"x\",\"kind\":\"mystery\",\"location\":\"y\"}]}".utf8)) }
        #expect(throws: ResolvedPackagesError.malformed("location")) { try ResolvedPackagesFile.decode(Data("{\"version\":3,\"pins\":[{\"identity\":\"x\",\"kind\":\"registry\"}]}".utf8)) }
    }

    @Test func matchesDirectAndTransitiveDependenciesByIdentityAndRemote() throws {
        let resolved = try ResolvedPackagesFile.decode(fixture("Package.resolved.v3"))
        let results = LocalOverrideMatcher.match(selected: [
            package("git@github.com:PicoMLX/SharedUI.git"),
            package("https://github.com/picomlx/modelkit"),
            package("https://github.com/apple/swift-collections"),
        ], resolved: resolved)
        #expect(results == [
            .matched(identity: PackageIdentity(location: "sharedui")!, location: "https://github.com/PicoMLX/SharedUI.git"),
            .matched(identity: PackageIdentity(location: "modelkit")!, location: "https://github.com/PicoMLX/ModelKit"),
            .matched(identity: PackageIdentity(location: "swift-collections")!, location: "https://github.com/apple/swift-collections.git"),
        ])
    }

    @Test func detectsWrongRemoteNotADependencyAndUnsupportedKinds() throws {
        let resolved = try ResolvedPackagesFile.decode(fixture("Package.resolved.v3"))
        let results = LocalOverrideMatcher.match(selected: [
            package("https://github.com/Fork/SharedUI"),
            package("https://github.com/PicoMLX/Unrelated"),
            package("https://github.com/PicoMLX/RegistryKit"),
        ], resolved: resolved)
        #expect(results == [
            .remoteMismatch(identity: PackageIdentity(location: "sharedui")!, expected: "https://github.com/PicoMLX/SharedUI.git", selected: "https://github.com/Fork/SharedUI"),
            .notADependency(identity: PackageIdentity(location: "unrelated")!),
            .unsupportedKind(identity: PackageIdentity(location: "registrykit")!, kind: .registry),
        ])
        let local = try ResolvedPackagesFile.decode(fixture("Package.resolved.v2"))
        #expect(LocalOverrideMatcher.match(selected: [package("https://github.com/PicoMLX/LocalKit")], resolved: local)
            == [.unsupportedKind(identity: PackageIdentity(location: "localkit")!, kind: .localSourceControl)])
    }

    @Test func identityCollisionsAreRefused() throws {
        var resolved = try ResolvedPackagesFile.decode(fixture("Package.resolved.v3"))
        resolved = ResolvedPackagesFile(version: 3, pins: resolved.pins + [
            .init(identity: PackageIdentity(location: "sharedui")!, kind: .remoteSourceControl, location: "https://github.com/Other/SharedUI.git", revision: nil, version: "0.1.0", branch: nil),
        ])
        #expect(LocalOverrideMatcher.match(selected: [package("https://github.com/PicoMLX/SharedUI")], resolved: resolved)
            == [.collision(identity: PackageIdentity(location: "sharedui")!, locations: ["https://github.com/Other/SharedUI.git", "https://github.com/PicoMLX/SharedUI.git"])])

        let clean = try ResolvedPackagesFile.decode(fixture("Package.resolved.v3"))
        let twoSelected = LocalOverrideMatcher.match(selected: [package("https://github.com/PicoMLX/SharedUI"), package("https://github.com/Fork/SharedUI")], resolved: clean)
        #expect(twoSelected.allSatisfy { if case .collision = $0 { true } else { false } })
    }

    @Test func appRepositoryIsIgnoredByTheMatcher() throws {
        let resolved = try ResolvedPackagesFile.decode(fixture("Package.resolved.v3"))
        let app = WorkspaceRepository(role: .app, remote: RemoteURL("https://github.com/PicoMLX/MyApp")!, baseBranch: BranchName("main")!, taskBranch: BranchName("feature/1")!)
        #expect(LocalOverrideMatcher.match(selected: [app], resolved: resolved).isEmpty)
    }
}
