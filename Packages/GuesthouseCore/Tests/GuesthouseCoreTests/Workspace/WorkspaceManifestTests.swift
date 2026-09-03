import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RemoteURLTests {
    @Test func canonicalizesEveryCommonForm() throws {
        let forms = [
            "https://github.com/PicoMLX/Guesthouse.git",
            "https://github.com/PicoMLX/Guesthouse",
            "git@github.com:PicoMLX/Guesthouse.git",
            "ssh://git@github.com/PicoMLX/Guesthouse.git",
            "https://GitHub.com/PicoMLX/Guesthouse/",
        ]
        for form in forms {
            let remote = try #require(RemoteURL(form), Comment(rawValue: form))
            #expect(remote.canonical == "https://github.com/PicoMLX/Guesthouse", Comment(rawValue: form))
            #expect(remote.owner == "PicoMLX")
            #expect(remote.name == "Guesthouse")
            #expect(remote.isSupportedHost)
        }
    }

    @Test func identityIgnoresCaseAndOtherHostsAreUnsupported() throws {
        let a = try #require(RemoteURL("https://github.com/picomlx/guesthouse"))
        let b = try #require(RemoteURL("git@github.com:PicoMLX/Guesthouse.git"))
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
        let other = try #require(RemoteURL("https://gitlab.com/group/project.git"))
        #expect(!other.isSupportedHost)
        #expect(other.canonical == "https://gitlab.com/group/project")
    }

    @Test func rejectsMalformedRemotes() {
        for bad in ["", "github.com/PicoMLX/Guesthouse", "https://github.com/PicoMLX", "https://github.com/a/b/c", "file:///tmp/repo", "https://github.com/../x", "git@github.com:Pico MLX/Guesthouse"] {
            #expect(RemoteURL(bad) == nil, Comment(rawValue: bad))
        }
    }

    @Test func encodesCanonically() throws {
        let remote = try #require(RemoteURL("git@github.com:PicoMLX/Guesthouse.git"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = try encoder.encode(remote)
        #expect(String(decoding: data, as: UTF8.self) == "\"https://github.com/PicoMLX/Guesthouse\"")
        #expect(try JSONDecoder().decode(RemoteURL.self, from: data) == remote)
    }
}

@Suite struct NameValidationTests {
    @Test func branchNamesFollowCheckRefFormat() {
        for good in ["main", "feature/123-thing", "release-2.0", "user/topic.v2", "a/b/c"] {
            #expect(BranchName(good) != nil, Comment(rawValue: good))
        }
        for bad in ["", "-x", "/x", "x/", "x.", "x.lock", "a..b", "a@{b", "a//b", "@", "with space", "tab\tx", "tilde~", "caret^", "colon:", "quest?", "star*", "brack[", "back\\", ".hidden", "a/.b", "a/b.lock"] {
            #expect(BranchName(bad) == nil, Comment(rawValue: bad))
        }
    }

    @Test func directoryNamesAreSafeSingleComponents() {
        for good in ["MyApp", "feature-123", "a.b_c", String(repeating: "x", count: 64)] {
            #expect(DirectoryName(good) != nil, Comment(rawValue: good))
        }
        for bad in ["", ".", "..", ".hidden", "a/b", "a b", "é", String(repeating: "x", count: 65), "a\nb"] {
            #expect(DirectoryName(bad) == nil, Comment(rawValue: bad))
        }
        #expect(DirectoryName("MyApp")!.identity == DirectoryName("myapp")!.identity)
    }

    @Test func commitSHAsAreFortyHexCharacters() {
        #expect(CommitSHA("1A2B3C4D5E6F7A8B9C0D1E2F3A4B5C6D7E8F9A0B")?.rawValue == "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b")
        #expect(CommitSHA("abc") == nil)
        #expect(CommitSHA("g" + String(repeating: "0", count: 39)) == nil)
    }
}

@Suite struct WorkspaceManifestTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func app() -> WorkspaceRepository {
        WorkspaceRepository(role: .app, remote: RemoteURL("https://github.com/PicoMLX/MyApp.git")!, baseBranch: BranchName("main")!, baseSHA: CommitSHA(String(repeating: "a", count: 40)), taskBranch: BranchName("feature/123")!)
    }

    func package(_ name: String = "SharedUI") -> WorkspaceRepository {
        WorkspaceRepository(role: .package, remote: RemoteURL("git@github.com:PicoMLX/\(name).git")!, baseBranch: BranchName("main")!, taskBranch: BranchName("feature/123")!)
    }

    func manifest(_ repositories: [WorkspaceRepository]) -> WorkspaceManifest {
        WorkspaceManifest(environmentID: EnvironmentID(), name: DirectoryName("feature-123")!, repositories: repositories, appProjectPath: "MyApp.xcodeproj", sharedScheme: "MyApp", testDestination: .macOS, createdAt: now, updatedAt: now)
    }

    @Test func validManifestRoundTrips() throws {
        let original = manifest([app(), package(), package("ModelKit")])
        try original.validate()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkspaceManifest.self, from: data)
        #expect(decoded == original)
        #expect(decoded.appRepository?.checkoutName.rawValue == "MyApp")
        #expect(decoded.packageRepositories.map(\.checkoutName.rawValue) == ["SharedUI", "ModelKit"])
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == SchemaVersion.current.rawValue)
    }

    @Test func exactlyOneAppRepository() {
        #expect(throws: WorkspaceValidationError.appRepositoryCount(0)) { try manifest([package()]).validate() }
        var second = app(); second.checkoutName = DirectoryName("OtherApp")!; second.remote = RemoteURL("https://github.com/PicoMLX/OtherApp")!
        #expect(throws: WorkspaceValidationError.appRepositoryCount(2)) { try manifest([app(), second]).validate() }
    }

    @Test func checkoutNamesAndRemotesMustBeUnique() {
        var clash = package(); clash.remote = RemoteURL("https://github.com/Other/SharedUI")!
        #expect(throws: WorkspaceValidationError.duplicateCheckoutName("SharedUI")) { try manifest([app(), package(), clash]).validate() }
        var sameRemote = package(); sameRemote.checkoutName = DirectoryName("SharedUI2")!; sameRemote.remote = RemoteURL("https://github.com/picomlx/sharedui")!
        #expect(throws: WorkspaceValidationError.duplicateRemote("https://github.com/picomlx/sharedui")) { try manifest([app(), package(), sameRemote]).validate() }
        var caseClash = package(); caseClash.checkoutName = DirectoryName("sharedui")!; caseClash.remote = RemoteURL("https://github.com/Other/Thing")!
        #expect(throws: WorkspaceValidationError.duplicateCheckoutName("sharedui")) { try manifest([app(), package(), caseClash]).validate() }
    }

    @Test func unsupportedHostsAndBadBranchesAreRejected() {
        var gitlab = package(); gitlab.remote = RemoteURL("https://gitlab.com/group/thing")!
        #expect(throws: WorkspaceValidationError.unsupportedHost("gitlab.com")) { try manifest([app(), gitlab]).validate() }
        var sameBranch = app(); sameBranch.taskBranch = sameBranch.baseBranch
        #expect(throws: WorkspaceValidationError.taskBranchEqualsBaseBranch("MyApp")) { try manifest([sameBranch]).validate() }
    }

    @Test func projectPathAndSchemeAreValidated() {
        for bad in ["", "/abs/MyApp.xcodeproj", "../MyApp.xcodeproj", "Apps/../MyApp.xcodeproj", "MyApp", "Apps//MyApp.xcodeproj"] {
            var m = manifest([app()]); m.appProjectPath = bad
            #expect(throws: WorkspaceValidationError.invalidAppProjectPath(bad)) { try m.validate() }
        }
        var good = manifest([app()]); good.appProjectPath = "Apps/MyApp/MyApp.xcodeproj"
        #expect(throws: Never.self) { try good.validate() }
        var noScheme = manifest([app()]); noScheme.sharedScheme = ""
        #expect(throws: WorkspaceValidationError.invalidScheme("")) { try noScheme.validate() }
    }

    @Test func layoutDerivesRelativeGuestPaths() {
        let m = manifest([app(), package()])
        let layout = WorkspaceLayout(m)
        #expect(layout.root == "Workspaces/feature-123")
        #expect(layout.manifestFile == "Workspaces/feature-123/workspace.json")
        #expect(layout.agentsGuide == "Workspaces/feature-123/AGENTS.md")
        #expect(layout.integrationWorkspace == "Workspaces/feature-123/Integration.xcworkspace")
        #expect(layout.repositoryDirectory(m.repositories[1]) == "Workspaces/feature-123/repos/SharedUI")
        #expect(layout.appProject == "Workspaces/feature-123/repos/MyApp/MyApp.xcodeproj")
        #expect(layout.repositoryPathFromRoot(m.repositories[0]) == "repos/MyApp")
        #expect(layout.artifactsDirectory == "Workspaces/feature-123/artifacts")
        #expect(!layout.root.hasPrefix("/"))
    }

    @Test func testDestinationSpecifierIsStructured() {
        #expect(TestDestination.macOS.specifier == "platform=macOS")
        #expect(TestDestination(platform: "iOS Simulator", name: "iPhone 17", os: "26.4").specifier == "platform=iOS Simulator,name=iPhone 17,OS=26.4")
    }

    @Test func decodingRejectsInvalidNamesAndSHAs() throws {
        var m = manifest([app()])
        m.repositories[0].baseSHA = nil
        var data = try JSONEncoder().encode(m)
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: "\"feature\\/123\"", with: "\"bad..branch\"")
        data = Data(text.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WorkspaceManifest.self, from: data) }
    }
}
