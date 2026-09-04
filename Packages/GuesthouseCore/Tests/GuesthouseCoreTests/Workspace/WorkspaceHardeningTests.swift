import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct WorkspaceHardeningTests {
    let sha = CommitSHA("0123456789abcdef0123456789abcdef01234567")!

    func manifest(repositories: [WorkspaceRepository], destination: TestDestination = .macOS, scheme: String = "App", project: String = "App.xcodeproj", schema: SchemaVersion = .current) -> WorkspaceManifest {
        WorkspaceManifest(schemaVersion: schema, environmentID: EnvironmentID(), name: DirectoryName("ws")!, repositories: repositories, appProjectPath: project, sharedScheme: scheme, testDestination: destination, createdAt: Date(), updatedAt: Date())
    }

    func app(base: String = "main", task: String = "task/one", sha: CommitSHA? = nil, pullRequest: PullRequestReference? = nil) -> WorkspaceRepository {
        WorkspaceRepository(role: .app, remote: RemoteURL("https://github.com/Org/App")!, baseBranch: BranchName(base)!, baseSHA: sha, taskBranch: BranchName(task)!, draftPullRequest: pullRequest)
    }

    @Test func remotesCarryNoMetadataAndOnlyDocumentedSchemes() {
        for bad in ["https://github.com:444/Org/Repo", "https://github.com/Org/Repo?ref=x", "https://github.com/Org/Repo#frag", "http://github.com/Org/Repo", "git://github.com/Org/Repo", "ssh://someone@github.com/Org/Repo", "https://github.com/Ｏrg/Repo"] {
            #expect(RemoteURL(bad) == nil, "\(bad)")
        }
        #expect(RemoteURL("ssh://git@github.com/Org/Repo.git")?.canonical == "https://github.com/Org/Repo")
    }

    @Test func sshRemotesNeedTheGitUserAndBranchesRefuseDisplayControls() throws {
        #expect(RemoteURL("ssh://github.com/Org/Repo") == nil)
        #expect(RemoteURL("ssh://git@github.com/Org/Repo") != nil)
        #expect(BranchName("main\u{202E}") == nil)
        #expect(BranchName("feature\u{2028}x") == nil)
        // A package name the deriver has to shorten cannot keep SwiftPM's identity, so the
        // workspace refuses it rather than checking it out under a name that means another
        // package. An app repository has no such constraint.
        let long = String(repeating: "r", count: 65)
        let package = WorkspaceRepository(role: .package, remote: RemoteURL("https://github.com/Org/\(long)")!, baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        #expect(package.checkoutName.rawValue.count == 64)
        #expect(throws: WorkspaceValidationError.checkoutNameDoesNotMatchRepository(checkout: package.checkoutName.rawValue, repository: long)) {
            try manifest(repositories: [app(sha: sha), package]).validate()
        }
        let usable = WorkspaceRepository(role: .package, remote: RemoteURL("https://github.com/Org/SharedUI")!, baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        #expect(throws: Never.self) { try manifest(repositories: [app(sha: sha), usable]).validate() }
    }

    @Test func branchNamesRejectHEADAndOverlongComponents() {
        #expect(BranchName("HEAD") == nil)
        #expect(BranchName("feature/HEAD") != nil)
        #expect(BranchName(String(repeating: "a", count: 250)) != nil)
        #expect(BranchName(String(repeating: "a", count: 251)) == nil)
        #expect(BranchName("ok/" + String(repeating: "é", count: 126)) == nil, "bytes, not characters")
    }

    @Test func commitSHAsAreASCIIOnly() {
        #expect(CommitSHA(String(repeating: "Ｆ", count: 40)) == nil)
        #expect(CommitSHA(String(repeating: "f", count: 40)) != nil)
    }

    @Test func derivedCheckoutNamesAreDeterministicNotAConstant() {
        let long = String(repeating: "r", count: 65)
        let derived = DirectoryName.derived(from: long)
        #expect(derived.rawValue == String(repeating: "r", count: 64))
        #expect(DirectoryName.derived(from: ".github").rawValue == "github")
        let repository = WorkspaceRepository(role: .app, remote: RemoteURL("https://github.com/Org/\(long)")!, baseBranch: BranchName("main")!, taskBranch: BranchName("t")!)
        #expect(repository.checkoutName == derived)
        #expect(DirectoryName.derived(from: "...").rawValue.hasPrefix("repo-"))
        #expect(DirectoryName.derived(from: "...") == DirectoryName.derived(from: "..."))
    }

    @Test func schemaVersionsBaseSHAsAndPullRequestsAreValidated() {
        #expect(throws: WorkspaceValidationError.unsupportedSchemaVersion(99)) { try manifest(repositories: [app(sha: sha)], schema: SchemaVersion(99)).validate() }
        #expect(throws: WorkspaceValidationError.missingBaseSHA("App")) { try manifest(repositories: [app()]).validate() }
        #expect(throws: Never.self) { try manifest(repositories: [app()]).validate(stage: .setup) }
        #expect(throws: Never.self) { try manifest(repositories: [app(sha: sha)]).validate() }
        let elsewhere = PullRequestReference(number: 7, url: URL(string: "https://github.com/Other/Repo/pull/7"))
        #expect(throws: WorkspaceValidationError.invalidPullRequestReference("App")) { try manifest(repositories: [app(sha: sha, pullRequest: elsewhere)]).validate() }
        #expect(throws: WorkspaceValidationError.invalidPullRequestReference("App")) { try manifest(repositories: [app(sha: sha, pullRequest: PullRequestReference(number: 0))]).validate() }
        let own = PullRequestReference(number: 7, url: URL(string: "https://github.com/org/app/pull/7"))
        #expect(throws: Never.self) { try manifest(repositories: [app(sha: sha, pullRequest: own)]).validate() }
    }

    @Test func branchCollisionsAreRejected() {
        #expect(throws: WorkspaceValidationError.taskBranchCollidesWithBaseBranch("App")) { try manifest(repositories: [app(base: "main", task: "MAIN", sha: sha)]).validate() }
        #expect(throws: WorkspaceValidationError.taskBranchCollidesWithBaseBranch("App")) { try manifest(repositories: [app(base: "release", task: "release/feature", sha: sha)]).validate() }
        #expect(throws: WorkspaceValidationError.taskBranchCollidesWithBaseBranch("App")) { try manifest(repositories: [app(base: "release/feature", task: "release", sha: sha)]).validate() }
        #expect(throws: Never.self) { try manifest(repositories: [app(base: "release", task: "released", sha: sha)]).validate() }
    }

    @Test func schemesPathsAndDestinationsRejectControlCharactersAndDelimiters() {
        #expect(throws: WorkspaceValidationError.invalidScheme("App\u{0}Other")) { try manifest(repositories: [app(sha: sha)], scheme: "App\u{0}Other").validate() }
        #expect(throws: WorkspaceValidationError.invalidAppProjectPath("Real.xcodeproj\u{0}ignored.xcodeproj")) { try manifest(repositories: [app(sha: sha)], project: "Real.xcodeproj\u{0}ignored.xcodeproj").validate() }
        let injected = TestDestination(platform: "iOS Simulator", name: "Phone,OS=1")
        #expect(throws: WorkspaceValidationError.invalidTestDestination(injected.specifier)) { try manifest(repositories: [app(sha: sha)], destination: injected).validate() }
        #expect(throws: WorkspaceValidationError.invalidTestDestination("platform=")) { try manifest(repositories: [app(sha: sha)], destination: TestDestination(platform: "")).validate() }
        #expect(throws: Never.self) { try manifest(repositories: [app(sha: sha)], destination: TestDestination(platform: "iOS Simulator", name: "iPhone 17", os: "26.4")).validate() }
    }

    @Test func scpRemotesNeedTheGitUserAndRepositoryNamesMayNotEndInGit() {
        #expect(RemoteURL("someone@github.com:Org/Repo") == nil, "SSH operations need GitHub's git account")
        #expect(RemoteURL("git@github.com:Org/Repo")?.canonical == "https://github.com/Org/Repo")
        // `Repo.git.git` would canonicalize to a URL that parses back as `Repo`.
        #expect(RemoteURL("https://github.com/Org/Repo.git.git") == nil)
        let round = RemoteURL("https://github.com/Org/Repo.git")
        #expect(round?.canonical == "https://github.com/Org/Repo")
        #expect(RemoteURL(round?.canonical ?? "") == round, "the canonical form parses back to the same repository")
    }

    @Test func aBranchPathIsBoundedAsAWhole() {
        let component = String(repeating: "a", count: 250)
        let long = [component, component, component].joined(separator: "/")
        #expect(BranchName(long) == nil, "a ref whose lock path would exceed the pathname limit is refused")
        #expect(BranchName([component, component].joined(separator: "/")) != nil)
    }

    @Test func manifestTextRejectsLineSeparators() throws {
        for bad in ["Scheme\u{2028}", "Scheme\u{2029}", "Scheme\u{FFFE}"] {
            #expect(throws: WorkspaceValidationError.invalidScheme(bad), "\(bad.unicodeScalars.map(\.value))") {
                try manifest(repositories: [app(sha: sha)], scheme: bad).validate()
            }
        }
    }

    @Test func ownersFollowGitHubAccountRules() {
        for bad in ["https://github.com/_/Repo", "https://github.com/my.org/Repo", "https://github.com/-org/Repo", "https://github.com/org-/Repo", "https://github.com/\(String(repeating: "o", count: 40))/Repo"] {
            #expect(RemoteURL(bad) == nil, Comment(rawValue: bad))
        }
        #expect(RemoteURL("https://github.com/Org-Name/repo_name.v2") != nil)
        #expect(RemoteURL("https://github.com/\(String(repeating: "o", count: 39))/Repo") != nil)
    }

    @Test func remotePathsRejectEmptyComponents() {
        for bad in ["git@github.com:/Org/Repo", "git@github.com:Org//Repo", "https://github.com/Org//Repo", "https://github.com//Org/Repo", "https://github.com/Org/Repo//"] {
            #expect(RemoteURL(bad) == nil, Comment(rawValue: bad))
        }
        #expect(RemoteURL("https://github.com/Org/Repo/")?.canonical == "https://github.com/Org/Repo")
        #expect(RemoteURL("git@github.com:Org/Repo/") == nil, "an SCP path has no documented trailing separator")
    }

    @Test func remotesRejectSurroundingWhitespace() {
        for bad in ["https://github.com/Org/Repo ", " https://github.com/Org/Repo", "https://github.com/Org/Repo\n", "git@github.com:Org/Repo\t"] {
            #expect(RemoteURL(bad) == nil, Comment(rawValue: bad.unicodeScalars.map(\.value).description))
        }
    }

    @Test func theNullObjectIDIsNotACommit() {
        #expect(CommitSHA(String(repeating: "0", count: 40)) == nil)
        #expect(CommitSHA(String(repeating: "0", count: 39) + "1") != nil)
    }

    @Test func lockSuffixesAreRejectedWhateverTheirCase() {
        for bad in ["main.LOCK", "main.Lock", "feature/x.lOcK"] {
            #expect(BranchName(bad) == nil, Comment(rawValue: bad))
        }
        #expect(BranchName("main.locked") != nil)
    }

    @Test func branchIdentitiesFoldUnicodeComposition() throws {
        let composed = try #require(BranchName("caf\u{E9}"))
        let decomposed = try #require(BranchName("cafe\u{301}"))
        #expect(composed.identity == decomposed.identity)
        #expect(composed.collides(with: decomposed), "one loose-ref path cannot hold two branches")
        #expect(throws: WorkspaceValidationError.taskBranchCollidesWithBaseBranch("App")) {
            try manifest(repositories: [app(base: "caf\u{E9}", task: "cafe\u{301}", sha: sha)]).validate()
        }
    }

    @Test func everyNoncharacterIsRejected() {
        // Swift's own literals refuse most of these, so they are built from their scalar values.
        for value: UInt32 in [0xFDD0, 0xFDEF, 0x1FFFE, 0x10FFFF] {
            let bad = "Scheme" + String(Unicode.Scalar(value)!)
            #expect(throws: WorkspaceValidationError.invalidScheme(bad), Comment(rawValue: String(value, radix: 16))) {
                try manifest(repositories: [app(sha: sha)], scheme: bad).validate()
            }
        }
    }

    @Test func projectPathComponentsAreBounded() {
        let overlong = String(repeating: "d", count: 256)
        #expect(throws: WorkspaceValidationError.invalidAppProjectPath("\(overlong)/App.xcodeproj")) {
            try manifest(repositories: [app(sha: sha)], project: "\(overlong)/App.xcodeproj").validate()
        }
        let deep = Array(repeating: String(repeating: "d", count: 60), count: 9).joined(separator: "/") + "/App.xcodeproj"
        #expect(throws: WorkspaceValidationError.invalidAppProjectPath(deep)) {
            try manifest(repositories: [app(sha: sha)], project: deep).validate()
        }
        #expect(throws: Never.self) {
            try manifest(repositories: [app(sha: sha)], project: "\(String(repeating: "d", count: 255))/App.xcodeproj").validate()
        }
    }

    @Test func twoPackagesOfOneNameAreAnIdentityConflictNotAFolderConflict() {
        let a = WorkspaceRepository(role: .package, remote: RemoteURL("https://github.com/OrgA/Common")!, baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        let b = WorkspaceRepository(role: .package, remote: RemoteURL("https://github.com/OrgB/Common")!, baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        // Both checkouts must keep the repository's own name, so "rename one folder" is not a
        // recovery the user can perform.
        #expect(throws: WorkspaceValidationError.duplicatePackageIdentity("common")) {
            try manifest(repositories: [app(sha: sha), a, b]).validate()
        }
    }

    @Test func aMalformedManifestIsAnActionableError() {
        let error = #expect(throws: WorkspaceValidationError.self) { try WorkspaceManifest.decode(Data("not json".utf8)) }
        guard case .malformed? = error else { Issue.record("expected malformed, got \(String(describing: error))"); return }
        #expect(error?.recoveryActions.first == .inspectState)
        // Rebuilding the workspace file is not one of the targeted repairs, so offering tool
        // repair would give the user a button that cannot do what the message promises.
        #expect(error?.recoveryActions.contains(.repair(.tools)) == false)
        #expect(error?.recoveryActions.contains(.openSettings) == true)
        #expect(error?.userMessage.isEmpty == false)
        let missingField = #expect(throws: WorkspaceValidationError.self) { try WorkspaceManifest.decode(Data("{}".utf8)) }
        guard case .malformed? = missingField else { Issue.record("expected malformed for a missing field"); return }
    }

    @Test func aMissingBaseSHAIsNeverRetriedBlindly() {
        let error = WorkspaceValidationError.missingBaseSHA("Repo")
        #expect(!error.recoveryActions.contains(.retry))
        #expect(error.recoveryActions.first == .inspectState)
        // The clone may have finished with only the manifest update lost, so the message must
        // not reach the opposite conclusion before the development Mac has been inspected.
        #expect(!error.userMessage.contains("not been cloned"))
        #expect(error.userMessage.contains("unknown"))
    }

    @Test func aWorkspaceIsAnchoredToItsDirectoryAndEnvironment() throws {
        let loaded = manifest(repositories: [app(sha: sha)])
        let elsewhere = try #require(DirectoryName("other-workspace"))
        #expect(throws: WorkspaceValidationError.nameDoesNotMatchDirectory(manifest: "ws", directory: "other-workspace")) {
            _ = try WorkspaceLayout(loaded, loadedFrom: elsewhere)
        }
        let here = try #require(DirectoryName("ws"))
        #expect(try WorkspaceLayout(loaded, loadedFrom: here).root == "Workspaces/ws")
        #expect(throws: WorkspaceValidationError.environmentMismatch) { try loaded.validate(in: EnvironmentID()) }
        #expect(throws: Never.self) { try loaded.validate(in: loaded.environmentID) }
    }

    @Test func validationErrorsAreActionable() {
        let errors: [WorkspaceValidationError] = [
            .unsupportedSchemaVersion(2), .appRepositoryCount(0), .duplicateCheckoutName("a"), .duplicateRemote("r"), .unsupportedHost("h"),
            .taskBranchCollidesWithBaseBranch("a"), .missingBaseSHA("a"), .invalidPullRequestReference("a"), .invalidAppProjectPath("p"),
            .invalidScheme("s"), .invalidTestDestination("d"), .checkoutNameDoesNotMatchRepository(checkout: "a", repository: "b"), .duplicatePackageIdentity("i"),
            .environmentMismatch, .nameDoesNotMatchDirectory(manifest: "a", directory: "b"),
        ]
        for error in errors {
            #expect(!error.userMessage.isEmpty)
            #expect(!error.recoveryActions.isEmpty)
            #expect(error.errorDescription == error.userMessage)
        }
    }
}
