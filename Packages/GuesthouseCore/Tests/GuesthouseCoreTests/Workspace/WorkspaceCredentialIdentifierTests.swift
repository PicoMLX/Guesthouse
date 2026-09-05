import Foundation
import Testing
@testable import GuesthouseCore

struct WorkspaceCredentialIdentifierTests {
    @Test(arguments: [
        ("https://github.com/Org/ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab", "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"),
        ("ssh://git@github.com/Org/ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab.git", "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"),
        ("git@github.com:Org/ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab.git", "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"),
        ("https://github.com/sk-abcdefghijklmnopqrst/App", "sk-abcdefghijklmnopqrst"),
    ])
    func repositoryIdentifiersCannotCarryRecognizableCredentials(remote: String, syntheticSecret: String) throws {
        let manifest = try makeManifest(remote: remote)
        let error = try #require(#expect(throws: WorkspaceValidationError.self) { try manifest.validate() })
        #expect(error == .credentialInRepositoryIdentifier)
        #expect(!error.userMessage.contains(syntheticSecret))
        #expect(!String(describing: error).contains(syntheticSecret))
        #expect(error.recoveryActions == [.openSettings, .cancel])
    }

    @Test(arguments: ["ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab", "prefix_sk-abcdefghijklmnopqrst"])
    func explicitCheckoutNamesUseTheSameCredentialRule(name: String) throws {
        var manifest = try makeManifest()
        manifest.repositories[0].checkoutName = try #require(DirectoryName(name))
        #expect(throws: WorkspaceValidationError.credentialInRepositoryIdentifier) { try manifest.validate() }
    }

    @Test(arguments: ["ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab", "prefix_sk-abcdefghijklmnopqrst"])
    func workspaceNamesUseTheSameCredentialRule(name: String) throws {
        var manifest = try makeManifest()
        manifest.name = try #require(DirectoryName(name))
        let error = try #require(#expect(throws: WorkspaceValidationError.self) { try manifest.validate() })
        #expect(error == .credentialInWorkspaceName)
        #expect(!error.userMessage.contains(name))
        #expect(!String(describing: error).contains(name))
        #expect(error.recoveryActions == [.openSettings, .cancel])
    }

    @Test func credentialsAreCheckedBeforePackageIdentityErrorsCanCarryThem() throws {
        let token = "ghp_" + String(repeating: "Ab12", count: 20)
        var manifest = try makeManifest()
        var package = manifest.repositories[0]
        package.role = .package
        package.remote = try #require(RemoteURL("https://github.com/Org/" + token))
        package.checkoutName = DirectoryName.derived(from: package.remote.name)
        manifest.repositories.append(package)
        #expect(throws: WorkspaceValidationError.credentialInRepositoryIdentifier) { try manifest.validate() }
    }

    @Test func decodedRepositoryIdentifiersStillRequireValidation() throws {
        let original = try makeManifest(remote: "https://github.com/Org/ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab")
        let decoded = try WorkspaceManifest.decode(JSONEncoder().encode(original))
        #expect(throws: WorkspaceValidationError.credentialInRepositoryIdentifier) { try decoded.validate() }
    }

    @Test(arguments: ["PROD-2024", "AB12-CD34", "release-2024"])
    func existingAmbiguousIdentifierPolicyIsUnchanged(name: String) throws {
        var manifest = try makeManifest(remote: "https://github.com/Org/" + name)
        manifest.name = try #require(DirectoryName(name))
        manifest.repositories[0].taskBranch = try #require(BranchName("feature/" + name))
        manifest.sharedScheme = name
        manifest.appProjectPath = name + "/App.xcodeproj"
        manifest.testDestination = TestDestination(platform: "iOS Simulator", name: name, os: "26.4")
        #expect(throws: Never.self) { try manifest.validate() }
    }

    private func makeManifest(remote: String = "https://github.com/Org/App") throws -> WorkspaceManifest {
        let repository = WorkspaceRepository(
            role: .app, remote: try #require(RemoteURL(remote)),
            baseBranch: try #require(BranchName("main")),
            baseSHA: CommitSHA("0123456789abcdef0123456789abcdef01234567"),
            taskBranch: try #require(BranchName("feature/task"))
        )
        return WorkspaceManifest(
            environmentID: EnvironmentID(), name: try #require(DirectoryName("workspace")),
            repositories: [repository], appProjectPath: "App.xcodeproj", sharedScheme: "App",
            testDestination: .macOS, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
