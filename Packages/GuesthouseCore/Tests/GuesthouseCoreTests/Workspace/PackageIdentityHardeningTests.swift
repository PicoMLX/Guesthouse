import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct PackageIdentityHardeningTests {
    let sha = CommitSHA("0123456789abcdef0123456789abcdef01234567")!

    func resolved(identity: String, location: String) -> ResolvedPackagesFile {
        ResolvedPackagesFile(version: 3, pins: [.init(identity: PackageIdentity(resolvedIdentity: identity)!, kind: .remoteSourceControl, location: location, revision: nil, version: "1.0.0", branch: nil)])
    }

    @Test func resolvedIdentitiesAreKeptVerbatim() throws {
        let file = try ResolvedPackagesFile.decode(Data(#"{"version":3,"pins":[{"identity":"mixed-repo.git","kind":"remoteSourceControl","location":"https://github.com/Org/Mixed-Repo.GIT","state":{"version":"1.0.0"}}]}"#.utf8))
        #expect(file.pins.first?.identity.rawValue == "mixed-repo.git")
        #expect(PackageIdentity(resolvedIdentity: "a/b") == nil)
        #expect(PackageIdentity(resolvedIdentity: "Ｏrg") == nil)
    }

    @Test func checkoutNamesAndOriginsMustCarryTheIdentity() {
        let remote = RemoteURL("https://github.com/Org/SharedUI")!
        let renamed = WorkspaceRepository(role: .package, remote: remote, checkoutName: DirectoryName("UI"), baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        let file = resolved(identity: "sharedui", location: "https://github.com/Org/SharedUI.git")
        #expect(LocalOverrideMatcher.match(selected: [renamed], resolved: file, observedOrigins: [renamed.checkoutName: remote]) == [.checkoutNameMismatch(identity: PackageIdentity(remote: remote), checkout: "UI")])
        let proper = WorkspaceRepository(role: .package, remote: remote, baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        let elsewhere = RemoteURL("https://github.com/Fork/SharedUI")!
        #expect(LocalOverrideMatcher.match(selected: [proper], resolved: file, observedOrigins: [proper.checkoutName: elsewhere]) == [.originMismatch(identity: PackageIdentity(remote: remote), expected: remote.canonical, observed: elsewhere.canonical)])
        #expect(LocalOverrideMatcher.match(selected: [proper], resolved: file, observedOrigins: [proper.checkoutName: remote]) == [.matched(identity: PackageIdentity(remote: remote), location: "https://github.com/Org/SharedUI.git")])
    }

    @Test func aMixedCaseGitSuffixKeepsSwiftPMsSpelling() {
        // SwiftPM strips only a lowercase `.git`, so `Mixed-Repo.GIT` is the package
        // `mixed-repo.git`, which is what it writes into `Package.resolved`.
        let remote = try? #require(RemoteURL("https://github.com/Org/Mixed-Repo.GIT"))
        #expect(remote?.name == "Mixed-Repo.GIT")
        #expect(PackageIdentity(remote: remote!).rawValue == "mixed-repo.git")
        #expect(RemoteURL(remote!.canonical) == remote, "the canonical form still parses back to the same repository")
        let package = WorkspaceRepository(role: .package, remote: remote!, baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        let file = resolved(identity: "mixed-repo.git", location: remote!.canonical)
        #expect(LocalOverrideMatcher.match(selected: [package], resolved: file, observedOrigins: [package.checkoutName: remote!]) == [.matched(identity: PackageIdentity(remote: remote!), location: remote!.canonical)])
    }

    @Test func anUnreadCheckoutIsNeverApproved() {
        let remote = RemoteURL("https://github.com/Org/SharedUI")!
        let package = WorkspaceRepository(role: .package, remote: remote, baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        let file = resolved(identity: "sharedui", location: "https://github.com/Org/SharedUI.git")
        #expect(LocalOverrideMatcher.match(selected: [package], resolved: file, observedOrigins: [:]) == [.originUnknown(identity: PackageIdentity(remote: remote), checkout: package.checkoutName.rawValue)])
    }

    @Test func aCheckoutIdentityIsDerivedTheWaySwiftPMDerivesIt() {
        // SwiftPM strips a terminal `.git` from the directory name, so `repos/foo.git` is the
        // package `foo` and cannot replace a dependency whose identity is `foo.git`.
        #expect(PackageIdentity(checkoutName: DirectoryName("foo.git")!).rawValue == "foo")
        #expect(PackageIdentity(checkoutName: DirectoryName("SharedUI")!).rawValue == "sharedui")
        // A repository whose own name ends in `.git` has no round-trippable canonical form
        // and is refused before it can reach a checkout at all.
        #expect(RemoteURL("https://github.com/Org/foo.git.git") == nil)
        // A checkout named for another package is refused whatever its spelling.
        let remote = RemoteURL("https://github.com/Org/SharedUI")!
        let file = resolved(identity: "sharedui", location: "https://github.com/Org/SharedUI.git")
        let package = WorkspaceRepository(role: .package, remote: remote, checkoutName: DirectoryName("ModelKit.git"), baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        let results = LocalOverrideMatcher.match(selected: [package], resolved: file, observedOrigins: [package.checkoutName: remote])
        #expect(results == [.checkoutNameMismatch(identity: PackageIdentity(remote: remote), checkout: "ModelKit.git")])
    }

    @Test func resolvedFileErrorsAreActionable() {
        for error in [ResolvedPackagesError.notJSON, .missingVersion, .unsupportedVersion(9), .unknownKind("x"), .malformed("pins")] {
            #expect(!error.userMessage.isEmpty)
            #expect(!error.recoveryActions.isEmpty)
            #expect(error.errorDescription == error.userMessage)
        }
    }
}
