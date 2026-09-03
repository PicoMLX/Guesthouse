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
        #expect(LocalOverrideMatcher.match(selected: [renamed], resolved: file) == [.checkoutNameMismatch(identity: PackageIdentity(remote: remote), checkout: "UI")])
        let proper = WorkspaceRepository(role: .package, remote: remote, baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        let elsewhere = RemoteURL("https://github.com/Fork/SharedUI")!
        #expect(LocalOverrideMatcher.match(selected: [proper], resolved: file, observedOrigins: [proper.checkoutName: elsewhere]) == [.originMismatch(identity: PackageIdentity(remote: remote), expected: remote.canonical, observed: elsewhere.canonical)])
        #expect(LocalOverrideMatcher.match(selected: [proper], resolved: file, observedOrigins: [proper.checkoutName: remote]) == [.matched(identity: PackageIdentity(remote: remote), location: "https://github.com/Org/SharedUI.git")])
    }

    @Test func resolvedFileErrorsAreActionable() {
        for error in [ResolvedPackagesError.notJSON, .missingVersion, .unsupportedVersion(9), .unknownKind("x"), .malformed("pins")] {
            #expect(!error.userMessage.isEmpty)
            #expect(!error.recoveryActions.isEmpty)
            #expect(error.errorDescription == error.userMessage)
        }
    }
}
