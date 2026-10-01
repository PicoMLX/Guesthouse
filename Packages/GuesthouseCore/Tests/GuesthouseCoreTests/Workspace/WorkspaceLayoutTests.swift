import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct WorkspaceLayoutTests {
    private func fixture() throws -> WorkspaceManifest {
        let repository = WorkspaceRepository(role: .app, remote: try #require(RemoteURL("https://github.com/Org/App")),
            baseBranch: try #require(BranchName("main")), baseSHA: CommitSHA(String(repeating: "a", count: 40)),
            taskBranch: try #require(BranchName("task/change")))
        return WorkspaceManifest(environmentID: EnvironmentID(), name: try #require(DirectoryName("feature-123")),
            repositories: [repository], appProjectPath: "Apps/App.xcodeproj", sharedScheme: "App", testDestination: .macOS,
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
    }

    @Test func derivesOnlyRelativePathsForTheValidatedSnapshot() throws {
        var manifest = try fixture()
        let layout = try WorkspaceLayout(manifest, in: manifest.environmentID, loadedFrom: manifest.name)
        #expect(layout.root == "Workspaces/feature-123")
        #expect(layout.manifestFile == "Workspaces/feature-123/workspace.json")
        #expect(layout.agentsGuide == "Workspaces/feature-123/AGENTS.md")
        #expect(layout.integrationWorkspace == "Workspaces/feature-123/Integration.xcworkspace")
        #expect(layout.artifactsDirectory == "Workspaces/feature-123/artifacts")
        #expect(layout.repositoriesDirectory == "Workspaces/feature-123/repos")
        #expect(layout.repositoryDirectory(manifest.repositories[0]) == "Workspaces/feature-123/repos/App")
        #expect(layout.repositoryPathFromRoot(manifest.repositories[0]) == "repos/App")
        #expect(layout.appProject == "Workspaces/feature-123/repos/App/Apps/App.xcodeproj")
        manifest.appProjectPath = "../Other.xcodeproj"
        manifest.repositories[0].remote = try #require(RemoteURL("https://github.com/Other/App"))
        #expect(layout.manifest.appProjectPath == "Apps/App.xcodeproj")
        #expect(layout.repositoryDirectory(manifest.repositories[0]) == nil)
    }

    @Test func refusesUnboundOrInvalidLoadedMetadataAndSupportsExplicitProposal() throws {
        var manifest = try fixture()
        let other = try #require(DirectoryName("other"))
        #expect(throws: WorkspaceValidationError.environmentMismatch) { try WorkspaceLayout(manifest, in: EnvironmentID(), loadedFrom: manifest.name) }
        #expect(throws: WorkspaceValidationError.directoryMismatch) { try WorkspaceLayout(manifest, in: manifest.environmentID, loadedFrom: other) }
        manifest.repositories[0].baseSHA = nil
        #expect(throws: WorkspaceValidationError.missingBaseSHA) { try WorkspaceLayout(manifest, in: manifest.environmentID, loadedFrom: manifest.name) }
        #expect(try WorkspaceLayout(proposed: manifest).root == "Workspaces/feature-123")
        manifest.appProjectPath = "../Other.xcodeproj"
        #expect(throws: WorkspaceValidationError.invalidProjectPath) { try WorkspaceLayout(proposed: manifest) }
    }
}
