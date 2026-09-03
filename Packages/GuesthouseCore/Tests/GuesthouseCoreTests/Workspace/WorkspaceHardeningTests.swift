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

    @Test func aMalformedManifestIsAnActionableError() {
        let error = #expect(throws: WorkspaceValidationError.self) { try WorkspaceManifest.decode(Data("not json".utf8)) }
        guard case .malformed? = error else { Issue.record("expected malformed, got \(String(describing: error))"); return }
        #expect(error?.recoveryActions.first == .inspectState)
        #expect(error?.userMessage.isEmpty == false)
        let missingField = #expect(throws: WorkspaceValidationError.self) { try WorkspaceManifest.decode(Data("{}".utf8)) }
        guard case .malformed? = missingField else { Issue.record("expected malformed for a missing field"); return }
    }

    @Test func aMissingBaseSHAIsNeverRetriedBlindly() {
        #expect(!WorkspaceValidationError.missingBaseSHA("Repo").recoveryActions.contains(.retry))
        #expect(WorkspaceValidationError.missingBaseSHA("Repo").recoveryActions.first == .inspectState)
    }

    @Test func validationErrorsAreActionable() {
        let errors: [WorkspaceValidationError] = [
            .unsupportedSchemaVersion(2), .appRepositoryCount(0), .duplicateCheckoutName("a"), .duplicateRemote("r"), .unsupportedHost("h"),
            .taskBranchCollidesWithBaseBranch("a"), .missingBaseSHA("a"), .invalidPullRequestReference("a"), .invalidAppProjectPath("p"),
            .invalidScheme("s"), .invalidTestDestination("d"), .checkoutNameDoesNotMatchRepository(checkout: "a", repository: "b"), .duplicatePackageIdentity("i"),
        ]
        for error in errors {
            #expect(!error.userMessage.isEmpty)
            #expect(!error.recoveryActions.isEmpty)
            #expect(error.errorDescription == error.userMessage)
        }
    }
}
