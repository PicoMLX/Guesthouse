import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

/// The host-side half of workspace generation: what actually lands on disk, and what is
/// refused before it does.
@Suite struct IntegrationWorkspaceWriterTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000.5)

    func manifest() -> WorkspaceManifest {
        WorkspaceManifest(
            environmentID: EnvironmentID(uuid: UUID(uuidString: "1A2B3C4D-0000-4000-8000-000000000000")!),
            name: DirectoryName("feature-123")!,
            repositories: [
                WorkspaceRepository(role: .package, remote: RemoteURL("https://github.com/PicoMLX/SharedUI")!, baseBranch: BranchName("main")!, taskBranch: BranchName("feature/123")!),
                WorkspaceRepository(role: .app, remote: RemoteURL("https://github.com/PicoMLX/MyApp")!, baseBranch: BranchName("main")!, taskBranch: BranchName("feature/123")!),
                WorkspaceRepository(role: .package, remote: RemoteURL("https://github.com/PicoMLX/ModelKit")!, baseBranch: BranchName("main")!, taskBranch: BranchName("feature/123")!),
            ],
            appProjectPath: "MyApp.xcodeproj",
            sharedScheme: "MyApp",
            testDestination: .macOS,
            createdAt: now,
            updatedAt: now
        )
    }

    func file(_ files: [GeneratedFile], _ path: String) throws -> String {
        let f = try #require(files.first { $0.relativePath == path }, Comment(rawValue: path))
        return String(decoding: f.contents, as: UTF8.self)
    }

    @Test func aLinkedWorkspaceRootIsRefused() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "Root-\(UUID().uuidString)")
        let real = base.appending(path: "repos/MyApp")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let root = base.appending(path: "workspace")
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: real)
        #expect(throws: GeneratedFileError.self) {
            try IntegrationWorkspaceWriter.write([GeneratedFile(relativePath: "AGENTS.md", text: "x")], to: root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty, "nothing was written through the root link")
    }

    @Test func caseFoldedSpellingsOfReposAreRefused() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for spelling in ["repos", "REPOS", "Repos", "repo\u{017F}"] {
            #expect(throws: GeneratedFileError.self, "\(spelling)") {
                try IntegrationWorkspaceWriter.write([GeneratedFile(relativePath: "\(spelling)/MyApp/file", text: "x")], to: root)
            }
        }
    }

    @Test func aLinkedDestinationComponentIsRefused() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Generated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repos = root.appending(path: "repos"); try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: WorkspaceLayout.integrationWorkspaceName), withDestinationURL: repos)
        #expect(throws: GeneratedFileError.self) {
            try IntegrationWorkspaceWriter.write([GeneratedFile(relativePath: "\(WorkspaceLayout.integrationWorkspaceName)/contents.xcworkspacedata", text: "x")], to: root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: repos.path).isEmpty, "nothing was written through the link")
    }

    @Test func writeFailuresAreActionable() throws {
        let files = try IntegrationWorkspaceGenerator.generate(manifest())
        #expect(throws: GeneratedFileError.self) { try IntegrationWorkspaceWriter.write(files, to: URL(fileURLWithPath: "/dev/null/workspace")) }
        for error in [GeneratedFileError.invalidPath("x"), .pathOutsideWorkspace("x"), .unwritable(path: "x", reason: "full")] {
            #expect(!error.userMessage.isEmpty)
            #expect(!error.recoveryActions.isEmpty)
        }
    }

    @Test func writingNeverTouchesTheRepositories() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "workspace-\(UUID().uuidString)")
        let project = root.appending(path: "repos/MyApp/MyApp.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let pbxproj = project.appending(path: "project.pbxproj")
        try Data("original".utf8).write(to: pbxproj)
        let resolved = root.appending(path: "repos/MyApp/MyApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("pins".utf8).write(to: resolved)
        let before = try snapshot(of: root.appending(path: "repos"))

        let files = try IntegrationWorkspaceGenerator.generate(manifest(), appResolvedPackages: Data(contentsOf: resolved))
        try IntegrationWorkspaceWriter.write(files, to: root)

        #expect(try snapshot(of: root.appending(path: "repos")) == before)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Integration.xcworkspace/contents.xcworkspacedata").path))
        #expect(try Data(contentsOf: root.appending(path: IntegrationWorkspaceGenerator.resolvedPackagesRelativePath)) == Data("pins".utf8))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "AGENTS.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "workspace.json").path))
    }

    @Test func writingRejectsPathsThatEscapeOrEnterRepositories() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "repos"), withIntermediateDirectories: true)
        for bad in ["./repos/MyApp/file", "repos", "REPOS/MyApp/file", "Repos", "a/../repos/x", "../outside", "/abs/file", "a//b", ""] {
            #expect(throws: GeneratedFileError.self, Comment(rawValue: bad)) {
                try IntegrationWorkspaceWriter.write([GeneratedFile(relativePath: bad, text: "x")], to: root)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "repos").path).isEmpty)
        try IntegrationWorkspaceWriter.write([GeneratedFile(relativePath: "artifacts/notes/readme.txt", text: "ok")], to: root)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "artifacts/notes/readme.txt").path))
    }

    @Test func regenerationWithoutResolvedPackagesRemovesTheStaleCopy() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "workspace-\(UUID().uuidString)")
        try IntegrationWorkspaceWriter.write(try IntegrationWorkspaceGenerator.generate(manifest(), appResolvedPackages: Data("pins".utf8)), to: root)
        let resolved = root.appending(path: IntegrationWorkspaceGenerator.resolvedPackagesRelativePath)
        #expect(FileManager.default.fileExists(atPath: resolved.path))
        try IntegrationWorkspaceWriter.write(try IntegrationWorkspaceGenerator.generate(manifest()), to: root)
        #expect(!FileManager.default.fileExists(atPath: resolved.path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Integration.xcworkspace/contents.xcworkspacedata").path))
    }

    func snapshot(of directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[url.path] = try Data(contentsOf: url)
        }
        return result
    }
}
