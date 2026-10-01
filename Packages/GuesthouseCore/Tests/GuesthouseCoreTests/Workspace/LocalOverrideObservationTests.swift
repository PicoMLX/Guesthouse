import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct LocalOverrideObservationTests {
    private func package(_ url: String) throws -> WorkspaceRepository {
        WorkspaceRepository(role: .package, remote: try #require(RemoteURL(url)),
            baseBranch: try #require(BranchName("main")), taskBranch: try #require(BranchName("task")))
    }
    private func resolved(_ identity: String, _ location: String) throws -> ResolvedPackagesFile {
        let data = try JSONSerialization.data(withJSONObject: ["version": 3, "pins": [[
            "identity": identity, "kind": "remoteSourceControl", "location": location,
            "state": ["revision": String(repeating: "a", count: 40)]
        ]]])
        return try ResolvedPackagesFile.decode(data)
    }

    @Test func refusesUnknownWrongOrRenamedCheckouts() throws {
        var selected = try package("https://github.com/Org/Library")
        let file = try resolved("library", "https://github.com/Org/Library.git")
        let identity = PackageIdentity(remote: selected.remote)
        #expect(LocalOverrideMatcher.match(selected: [selected], resolved: file, observedOrigins: [:]) == [.originUnknown(identity: identity, checkout: "Library")])
        let wrong = try #require(RemoteURL("https://github.com/Fork/Library"))
        #expect(LocalOverrideMatcher.match(selected: [selected], resolved: file, observedOrigins: [selected.checkoutName: wrong]) == [.originMismatch(identity: identity, expected: selected.remote.canonical, observed: wrong.canonical)])
        selected.checkoutName = try #require(DirectoryName("Other.git"))
        #expect(LocalOverrideMatcher.match(selected: [selected], resolved: file, observedOrigins: [selected.checkoutName: selected.remote]) == [.checkoutNameMismatch(identity: identity, checkout: "Other.git")])
    }

    @Test(arguments: [("company-cache", "https://github.com/Org/Library.git", "Library"), ("foo%2dbar", "https://github.com/Org/foo%2Dbar.git", "foo-bar"), ("library.git", "https://github.com/Org/Library.GIT", "Library")])
    func mirrorsEscapesAndSuffixIdentityChangesNeverApproveAnOverride(_ identity: String, _ location: String, _ repository: String) throws {
        let selected = try package("https://github.com/Org/" + repository)
        let file = try resolved(identity, location)
        let results = LocalOverrideMatcher.match(selected: [selected], resolved: file, observedOrigins: [selected.checkoutName: selected.remote])
        #expect(results == [.identityMismatch(identity: PackageIdentity(remote: selected.remote), pinned: try #require(PackageIdentity(resolvedIdentity: identity)), location: location)])
    }

    @Test func refusesUnsupportedHostAndCaseFoldedCheckoutCollisionWithApp() throws {
        let unsupported = try package("https://custom.example/Org/Library")
        let file = try resolved("library", unsupported.remote.canonical)
        #expect(LocalOverrideMatcher.match(selected: [unsupported], resolved: file, observedOrigins: [unsupported.checkoutName: unsupported.remote]) == [.unsupportedHost(identity: PackageIdentity(remote: unsupported.remote))])
        let selected = try package("https://github.com/Org/Library")
        var app = try package("https://github.com/Org/App"); app.role = .app
        app.checkoutName = try #require(DirectoryName("library"))
        #expect(LocalOverrideMatcher.match(selected: [app, selected], resolved: try resolved("library", selected.remote.canonical), observedOrigins: [selected.checkoutName: selected.remote]) == [.checkoutCollision(identity: PackageIdentity(remote: selected.remote))])
    }

    @Test func guidanceDoesNotEchoPrivateMetadata() throws {
        let identity = try #require(PackageIdentity(resolvedIdentity: "private-value"))
        let result = LocalOverrideMatcher.MatchResult.originUnknown(identity: identity, checkout: "private-value")
        #expect(!result.userMessage.contains("private-value") && !result.recoveryMessage.contains("private-value"))
        #expect(!result.recoveryActions.isEmpty)
    }
}
