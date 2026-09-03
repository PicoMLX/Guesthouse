import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct IntegrationWorkspaceGeneratorTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

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

    @Test func workspaceDataMatchesGoldenAndOrdersAppFirstThenPackagesSorted() throws {
        let files = try IntegrationWorkspaceGenerator.generate(manifest())
        let xml = try file(files, "Integration.xcworkspace/contents.xcworkspacedata")
        let golden = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace
           version = "1.0">
           <FileRef
              location = "group:repos/MyApp/MyApp.xcodeproj">
           </FileRef>
           <FileRef
              location = "group:repos/ModelKit">
           </FileRef>
           <FileRef
              location = "group:repos/SharedUI">
           </FileRef>
        </Workspace>

        """
        #expect(xml == golden)
    }

    @Test func agentsGuideDescribesRepositoriesBuildMappingAndPolicy() throws {
        let files = try IntegrationWorkspaceGenerator.generate(manifest())
        let guide = try file(files, "AGENTS.md")
        #expect(guide.hasPrefix("# Workspace feature-123"))
        #expect(guide.contains("| `repos/MyApp` | app | https://github.com/PicoMLX/MyApp | `main` | `feature/123` |"))
        #expect(guide.contains("xcodebuild -workspace Integration.xcworkspace -scheme MyApp -destination 'platform=macOS' test"))
        #expect(guide.contains("- `repos/ModelKit` overrides the dependency on https://github.com/PicoMLX/ModelKit (package identity `modelkit`)."))
        #expect(guide.contains("Do not push, force-push, or open pull requests yourself."))
        #expect(guide.contains("One pull request per changed repository."))
        #expect(guide.contains("does not mean the app's own pull request will pass its CI"))
        let modelKit = try #require(guide.range(of: "repos/ModelKit` overrides"))
        let sharedUI = try #require(guide.range(of: "repos/SharedUI` overrides"))
        #expect(modelKit.lowerBound < sharedUI.lowerBound, "mapping is sorted by checkout name")
    }

    @Test func seedsResolvedPackagesOnlyWhenTheAppHasThem() throws {
        let pins = Data("{\"pins\":[],\"version\":3}".utf8)
        let seeded = try IntegrationWorkspaceGenerator.generate(manifest(), appResolvedPackages: pins)
        let copy = try #require(seeded.first { $0.relativePath == IntegrationWorkspaceGenerator.resolvedPackagesRelativePath })
        #expect(copy.contents == pins)
        #expect(copy.relativePath == "Integration.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let unseeded = try IntegrationWorkspaceGenerator.generate(manifest())
        #expect(!unseeded.contains { $0.relativePath == IntegrationWorkspaceGenerator.resolvedPackagesRelativePath })
    }

    @Test func manifestIsWrittenDeterministically() throws {
        let files = try IntegrationWorkspaceGenerator.generate(manifest())
        let json = try file(files, "workspace.json")
        #expect(json.contains("\"name\" : \"feature-123\""))
        #expect(json.contains("https://github.com/PicoMLX/MyApp"))
        let decoded = try { () throws -> WorkspaceManifest in
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(WorkspaceManifest.self, from: Data(json.utf8))
        }()
        #expect(decoded == manifest())
    }

    @Test func regenerationIsByteIdentical() throws {
        let first = try IntegrationWorkspaceGenerator.generate(manifest(), appResolvedPackages: Data("x".utf8))
        let second = try IntegrationWorkspaceGenerator.generate(manifest(), appResolvedPackages: Data("x".utf8))
        #expect(first == second)
    }

    @Test func invalidManifestsAreRefused() {
        var bad = manifest(); bad.repositories.removeAll { $0.role == .app }
        #expect(throws: WorkspaceValidationError.appRepositoryCount(0)) { try IntegrationWorkspaceGenerator.generate(bad) }
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
        try IntegrationWorkspaceGenerator.write(files, to: root)

        #expect(try snapshot(of: root.appending(path: "repos")) == before)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Integration.xcworkspace/contents.xcworkspacedata").path))
        #expect(try Data(contentsOf: root.appending(path: IntegrationWorkspaceGenerator.resolvedPackagesRelativePath)) == Data("pins".utf8))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "AGENTS.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "workspace.json").path))
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
