import Darwin
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

    /// The root's own component is opened no-follow, so the folder above it is where a link
    /// would still redirect every generated file: it is created through that folder's own
    /// descriptor, and a link left there is refused instead of written through.
    @Test func aLinkedWorkspaceContainerIsRefused() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "Container-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appending(path: "repository")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A guest agent leaves a link where the directory holding the workspaces belongs.
        let container = base.appending(path: WorkspaceLayout.workspacesDirectory)
        try FileManager.default.createSymbolicLink(at: container, withDestinationURL: target)
        #expect(throws: GeneratedFileError.self) {
            try IntegrationWorkspaceWriter.write([GeneratedFile(relativePath: "AGENTS.md", text: "x")], to: container.appending(path: "feature-123"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty, "nothing was created through the link")
    }

    @Test func caseFoldedSpellingsOfReposAreRefused() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for spelling in ["repos", "REPOS", "Repos", "repo\u{017F}", "ＲＥＰＯＳ"] {
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

    @Test func aWriteGoesToTheCheckedDirectoryEvenAfterItsEntryIsSwappedForALink() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "workspace-\(UUID().uuidString)")
        let elsewhere = FileManager.default.temporaryDirectory.appending(path: "elsewhere-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let rootDescriptor = try IntegrationWorkspaceWriter.openRoot(root)
        defer { close(rootDescriptor) }
        let artifacts = try IntegrationWorkspaceWriter.openParent(["artifacts", "notes.txt"], in: rootDescriptor, creating: true, of: "artifacts/notes.txt")
        defer { close(artifacts) }

        // A guest agent moves the directory the writer just checked aside and leaves a link to
        // a place of its own in the entry, in the window before the bytes are written.
        try FileManager.default.moveItem(at: root.appending(path: "artifacts"), to: root.appending(path: "moved"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "artifacts"), withDestinationURL: elsewhere)

        try IntegrationWorkspaceWriter.writeFile(Data("notes".utf8), named: "notes.txt", in: artifacts, of: "artifacts/notes.txt")
        #expect(try Data(contentsOf: root.appending(path: "moved/notes.txt")) == Data("notes".utf8))
        #expect(!FileManager.default.fileExists(atPath: elsewhere.appending(path: "notes.txt").path), "the swapped link never received the file")
    }

    /// `openat` and the calls beside it stop at an embedded NUL, so a component carrying one
    /// compares unequal to `repos` in every check and still opens `repos` itself.
    @Test func aComponentWithAnEmbeddedNULIsRefused() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "workspace-\(UUID().uuidString)")
        let repos = root.appending(path: "repos")
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        #expect(throws: GeneratedFileError.invalidPath("repos\0suffix/MyApp/file")) {
            try IntegrationWorkspaceWriter.write([GeneratedFile(relativePath: "repos\0suffix/MyApp/file", text: "x")], to: root)
        }
        #expect(throws: GeneratedFileError.invalidPath("artifacts/notes\0.txt")) {
            try IntegrationWorkspaceWriter.write([GeneratedFile(relativePath: "artifacts/notes\0.txt", text: "x")], to: root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: repos.path).isEmpty, "nothing was written into the repositories")
    }

    /// `O_NOFOLLOW` only refuses a link, so a root replaced by a different real directory
    /// between the check and the open would pass it and take every write with it.
    @Test func aRootReplacedByAnotherDirectoryAfterItIsCheckedIsRefused() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "Pinned-\(UUID().uuidString)")
        let root = base.appending(path: "workspace")
        let decoy = base.appending(path: "repos/MyApp")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)

        #expect(throws: GeneratedFileError.pathOutsideWorkspace("workspace")) {
            _ = try IntegrationWorkspaceWriter.openRoot(root, afterCheck: {
                // A guest agent moves a repository into the root's pathname in the window
                // between the check and the open, which no link is involved in.
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.moveItem(at: decoy, to: root)
            })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty, "the substituted repository was not opened for writing")
    }

    @Test func aRootThatAppearsAfterTheAbsenceCheckIsRefused() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "CreationRace-\(UUID().uuidString)")
        let root = base.appending(path: "workspace")
        let checkout = base.appending(path: "repos/MyApp")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let original = Data("guest checkout".utf8)
        try original.write(to: checkout.appending(path: "README.md"))

        #expect(throws: GeneratedFileError.pathOutsideWorkspace("workspace")) {
            let descriptor = try IntegrationWorkspaceWriter.openRoot(root, beforeCreate: {
                try FileManager.default.moveItem(at: checkout, to: root)
            })
            defer { close(descriptor) }
            try IntegrationWorkspaceWriter.writeFile(Data("generated".utf8), named: "AGENTS.md", in: descriptor, of: "AGENTS.md")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["README.md"])
        #expect(try Data(contentsOf: root.appending(path: "README.md")) == original)
    }

    @Test(arguments: [false, true])
    func aRootThatAppearsBeforeInstallationIsRefused(checkoutHasContents: Bool) throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "InstallRace-\(UUID().uuidString)")
        let root = base.appending(path: "workspace")
        let checkout = base.appending(path: "repos/MyApp")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let original = Data("guest checkout".utf8)
        if checkoutHasContents { try original.write(to: checkout.appending(path: "README.md")) }

        #expect(throws: GeneratedFileError.pathOutsideWorkspace("workspace")) {
            let descriptor = try IntegrationWorkspaceWriter.openRoot(root, beforeInstall: {
                try? FileManager.default.moveItem(at: checkout, to: root)
            })
            defer { close(descriptor) }
            try IntegrationWorkspaceWriter.writeFile(Data("generated".utf8), named: "AGENTS.md", in: descriptor, of: "AGENTS.md")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == (checkoutHasContents ? ["README.md"] : []))
        if checkoutHasContents { #expect(try Data(contentsOf: root.appending(path: "README.md")) == original) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).sorted() == ["repos", "workspace"], "failed installation removes its temporary directory")
    }

    @Test func aCreatedRootIsSampledThroughItsDescriptor() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "CreatedIdentity-\(UUID().uuidString)")
        let root = base.appending(path: "workspace")
        let checkout = base.appending(path: "repos/MyApp")
        let created = base.appending(path: "created")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let original = Data("guest checkout".utf8)
        try original.write(to: checkout.appending(path: "README.md"))

        #expect(throws: GeneratedFileError.pathOutsideWorkspace("workspace")) {
            let descriptor = try IntegrationWorkspaceWriter.openRoot(root, beforeInstall: {
                // Replace the staged pathname after the writer has opened it. The rename
                // will install the checkout, so a later identity sample by name would adopt
                // it; sampling the already-open descriptor must still identify the original.
                guard let staged = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
                    .first(where: { $0.lastPathComponent.hasPrefix(".workspace.") }) else { return }
                try? FileManager.default.moveItem(at: staged, to: created)
                try? FileManager.default.moveItem(at: checkout, to: staged)
            })
            defer { close(descriptor) }
            try IntegrationWorkspaceWriter.writeFile(Data("generated".utf8), named: "AGENTS.md", in: descriptor, of: "AGENTS.md")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["README.md"])
        #expect(try Data(contentsOf: root.appending(path: "README.md")) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: created.path).isEmpty)
    }

    /// A root the writer had to create is bound to its identity the same way: having just made
    /// it is no evidence that it is still the directory being opened.
    @Test func aCreatedRootReplacedBeforeItIsOpenedIsRefused() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "Created-\(UUID().uuidString)")
        let root = base.appending(path: "workspace")
        let decoy = base.appending(path: "repos/MyApp")
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)

        #expect(throws: GeneratedFileError.pathOutsideWorkspace("workspace")) {
            _ = try IntegrationWorkspaceWriter.openRoot(root, afterCheck: {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.moveItem(at: decoy, to: root)
            })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty, "the substituted repository was not opened for writing")
    }

    /// A directory the write had to create is bound to the inode Guesthouse made: it is
    /// created under a name nothing can predict and moved into place, so a checkout the guest
    /// moves into that name is never what the write goes through.
    @Test func aDirectoryCreatedForAWriteIsBoundToTheInodeGuesthouseMade() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Bound-\(UUID().uuidString)")
        let checkout = root.appending(path: "repos/MyApp")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try Data("guest".utf8).write(to: checkout.appending(path: "README.md"))
        let rootDescriptor = try IntegrationWorkspaceWriter.openRoot(root)
        defer { close(rootDescriptor) }

        #expect(throws: GeneratedFileError.pathOutsideWorkspace("artifacts/notes.txt")) {
            _ = try IntegrationWorkspaceWriter.createDirectory("artifacts", in: rootDescriptor, of: "artifacts/notes.txt") {
                // A guest agent moves a checkout into the name the new directory is about to
                // take, in the window where no descriptor names it yet.
                try? FileManager.default.moveItem(at: checkout, to: root.appending(path: "artifacts"))
            }
        }
        let moved = root.appending(path: "artifacts")
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path) == ["README.md"], "nothing was written into the checkout")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["artifacts", "repos"], "the directory that could not be moved into place was removed")
    }

    /// Only a directory that is genuinely absent is passed over on the way to a stale entry.
    /// Anything else would hide a resolution file that survived the regeneration.
    @Test func aBlockedPathToTheStaleLockfileIsReported() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "workspace-\(UUID().uuidString)")
        let blocked = root.appending(path: "\(WorkspaceLayout.integrationWorkspaceName)/xcshareddata")
        try FileManager.default.createDirectory(at: blocked.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A file where the directory belongs: the walk cannot go through it, and that is not
        // the same as the entry simply not being there.
        try Data("guest".utf8).write(to: blocked)
        #expect(throws: GeneratedFileError.pathOutsideWorkspace(IntegrationWorkspaceGenerator.resolvedPackagesRelativePath)) {
            try IntegrationWorkspaceWriter.write(try IntegrationWorkspaceGenerator.generate(manifest(), appProjectLayout: .project), to: root)
        }
    }

    /// Regeneration that reports success while the old resolution file survives would leave it
    /// pinning dependencies this generation deliberately dropped.
    @Test func aStaleLockfileThatCannotBeRemovedIsReported() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "workspace-\(UUID().uuidString)")
        let resolved = root.appending(path: IntegrationWorkspaceGenerator.resolvedPackagesRelativePath)
        // A directory the guest left where the file belongs, with something in it: Guesthouse
        // never deletes a tree it did not create, so this cannot be cleared.
        try FileManager.default.createDirectory(at: resolved.appending(path: "guest"), withIntermediateDirectories: true)
        var thrown: GeneratedFileError?
        do {
            try IntegrationWorkspaceWriter.write(try IntegrationWorkspaceGenerator.generate(manifest(), appProjectLayout: .project), to: root)
            Issue.record("the stale entry was reported as removed")
        } catch let error as GeneratedFileError {
            thrown = error
        }
        guard case .unwritable(_, let reason)? = thrown else {
            Issue.record("expected an unwritable failure, got \(String(describing: thrown))")
            return
        }
        let notEmpty = SanitizedText(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTEMPTY)).localizedDescription, limit: 120)
        #expect(reason == notEmpty, "the reason explains why the entry cannot be removed, not an unrelated errno")
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
