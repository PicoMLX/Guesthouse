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

    /// The guest shares this file system and changes it while the write runs, so a directory
    /// that was checked can be a link by the time the next file is written.
    @Test func aRootSwappedForALinkWhileWritingCannotRedirectIt() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "Swap-\(UUID().uuidString)")
        let root = base.appending(path: "workspace")
        let moved = base.appending(path: "moved")
        let decoy = base.appending(path: "repos/MyApp")
        let link = base.appending(path: "link")
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: decoy)
        let files = (0..<1_500).map { GeneratedFile(relativePath: "artifacts/file-\($0)", text: "x") }

        let writing = Task.detached { try IntegrationWorkspaceWriter.write(files, to: root) }
        let first = root.appending(path: "artifacts/file-0")
        for _ in 0..<2_000 where !FileManager.default.fileExists(atPath: first.path) {
            try await Task.sleep(for: .milliseconds(1))
        }
        // The root is renamed away and the link to a checkout takes its name: a writer that
        // resolves the path again for every file would follow it from here on.
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.moveItem(at: link, to: root)
        try await writing.value

        #expect(try FileManager.default.contentsOfDirectory(atPath: decoy.path).isEmpty, "no file was written through the link")
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.appending(path: "artifacts").path).count == files.count)
    }

    @Test func writeFailuresAreActionable() throws {
        let files = try IntegrationWorkspaceGenerator.generate(manifest(), appProjectLayout: .project)
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

        let files = try IntegrationWorkspaceGenerator.generate(manifest(), appProjectLayout: .project, appResolvedPackages: Data(contentsOf: resolved))
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
        try IntegrationWorkspaceWriter.write(try IntegrationWorkspaceGenerator.generate(manifest(), appProjectLayout: .project, appResolvedPackages: Data("pins".utf8)), to: root)
        let resolved = root.appending(path: IntegrationWorkspaceGenerator.resolvedPackagesRelativePath)
        #expect(FileManager.default.fileExists(atPath: resolved.path))
        try IntegrationWorkspaceWriter.write(try IntegrationWorkspaceGenerator.generate(manifest(), appProjectLayout: .project), to: root)
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
