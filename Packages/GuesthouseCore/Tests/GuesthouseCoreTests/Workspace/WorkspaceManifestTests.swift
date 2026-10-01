import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct WorkspaceManifestTests {
    private func fixture() throws -> WorkspaceManifest {
        let baseSHA = try #require(CommitSHA(String(repeating: "a", count: 40)))
        let repository = WorkspaceRepository(role: .app, remote: try #require(RemoteURL("https://github.com/Org/App")),
            baseBranch: try #require(BranchName("main")), baseSHA: baseSHA,
            taskBranch: try #require(BranchName("task/change")))
        return WorkspaceManifest(environmentID: EnvironmentID(), name: try #require(DirectoryName("feature-123")),
            repositories: [repository], appProjectPath: "Apps/My App.xcodeproj", sharedScheme: "My App",
            testDestination: .macOS, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
    }

    @Test func roundTripBindsEnvironmentAndDirectoryAndRetainsRecordedFacts() throws {
        var manifest = try fixture()
        var package = manifest.repositories[0]
        package.role = .package
        package.remote = try #require(RemoteURL("git@github.com:Org/Library.git"))
        package.checkoutName = try #require(DirectoryName("Library"))
        package.publishedSHA = CommitSHA(String(repeating: "b", count: 40))
        package.draftPullRequest = .init(number: 3, url: URL(string: "https://github.com/Org/Library/pull/3"))
        manifest.repositories.append(package)
        let data = try JSONEncoder().encode(manifest)
        #expect(try WorkspaceManifest.decode(data, in: manifest.environmentID, directory: manifest.name) == manifest)
        #expect(manifest.appRepository == manifest.repositories[0] && manifest.packageRepositories == [package])
        #expect(throws: WorkspaceValidationError.environmentMismatch) { try manifest.validate(in: EnvironmentID()) }
        let otherDirectory = try #require(DirectoryName("other"))
        #expect(throws: WorkspaceValidationError.directoryMismatch) { try manifest.validate(directory: otherDirectory) }
    }

    @Test func proposalAllowsMissingBaseButRecordedMetadataRequiresInspection() throws {
        var manifest = try fixture()
        manifest.repositories[0].baseSHA = nil
        try manifest.validate(stage: .setup)
        #expect(try WorkspaceManifest.decode(JSONEncoder().encode(manifest), stage: .setup) == manifest)
        #expect(throws: WorkspaceValidationError.missingBaseSHA) { try manifest.validate() }
        #expect(WorkspaceValidationError.missingBaseSHA.recoveryActions == [.inspectState, .cancel])
    }

    @Test func repositoryRulesRejectEachInvalidShape() throws {
        let valid = try fixture()
        var value = valid
        value.repositories = []
        #expect(throws: WorkspaceValidationError.appRepositoryCount) { try value.validate() }
        value.repositories = valid.repositories + valid.repositories
        #expect(throws: WorkspaceValidationError.appRepositoryCount) { try value.validate() }
        value.repositories[1].role = .package
        #expect(throws: WorkspaceValidationError.duplicateRemote) { try value.validate() }
        value.repositories[1].remote = try #require(RemoteURL("https://github.com/Other/app"))
        value.repositories[1].checkoutName = try #require(DirectoryName("app"))
        #expect(throws: WorkspaceValidationError.duplicateCheckout) { try value.validate() }
        value = valid; value.repositories[0].remote = try #require(RemoteURL("https://gitlab.com/Org/App"))
        #expect(throws: WorkspaceValidationError.unsupportedHost) { try value.validate() }
        value = valid; value.repositories[0].taskBranch = try #require(BranchName("MAIN/change"))
        #expect(throws: WorkspaceValidationError.branchCollision) { try value.validate() }
        value = valid; value.repositories[0].draftPullRequest = .init(number: 0)
        #expect(throws: WorkspaceValidationError.invalidPullRequestReference) { try value.validate() }
    }

    @Test(arguments: ["", "/App.xcodeproj", "../App.xcodeproj", "a/../App.xcodeproj", "a//App.xcodeproj", "./App.xcodeproj", "App.xcodeproj/", "App.xcworkspace", "a\u{202E}/App.xcodeproj", String(repeating: "x", count: 256) + "/App.xcodeproj", String(repeating: "a/", count: 256) + "App.xcodeproj"])
    func refusesEscapingOrUnusableProjectPaths(_ path: String) throws {
        var value = try fixture(); value.appProjectPath = path
        #expect(throws: WorkspaceValidationError.invalidProjectPath) { try value.validate() }
    }

    @Test func schemeDestinationAndTimestampsAreValidated() throws {
        var value = try fixture()
        for scheme in ["", "a/b", "a\u{0}b", "a\u{2028}b", String(repeating: "x", count: 247)] {
            value.sharedScheme = scheme
            #expect(throws: WorkspaceValidationError.invalidScheme) { try value.validate() }
        }
        value.sharedScheme = String(repeating: "x", count: 246)
        try value.validate()
        value.testDestination = .init(platform: "macOS,arch=arm64")
        #expect(throws: WorkspaceValidationError.invalidDestination) { try value.validate() }
        value.testDestination = .macOS
        for date in [Date(timeIntervalSince1970: 0), Date(timeIntervalSinceReferenceDate: .infinity), Date(timeIntervalSinceReferenceDate: .nan)] {
            value.updatedAt = date
            #expect(throws: WorkspaceValidationError.invalidTimestamps) { try value.validate() }
        }
    }

    @Test func boundedDecodeRecognizesFutureFormatsAndDoesNotExposeDecoderText() throws {
        #expect(throws: WorkspaceValidationError.oversized) { try WorkspaceManifest.decode(Data(repeating: 0, count: 65_537)) }
        #expect(throws: WorkspaceValidationError.unsupportedSchemaVersion) { try WorkspaceManifest.decode(Data(#"{"schemaVersion":2}"#.utf8)) }
        for text in [#"{"schemaVersion":0}"#, #"{"schemaVersion":1,"private-field":"private-value"}"#, "not json"] {
            #expect(throws: WorkspaceValidationError.malformed) { try WorkspaceManifest.decode(Data(text.utf8)) }
        }
        var value = try fixture(); value.schemaVersion = try #require(SchemaVersion(2))
        #expect(throws: WorkspaceValidationError.unsupportedSchemaVersion) { try value.validate() }
        value = try fixture(); value.repositories[0].taskBranch = value.repositories[0].baseBranch
        #expect(throws: WorkspaceValidationError.branchCollision) { try WorkspaceManifest.decode(JSONEncoder().encode(value)) }
        for failure in WorkspaceValidationError.allCases {
            #expect(!failure.userMessage.isEmpty && !failure.recoveryMessage.isEmpty && !failure.recoveryActions.isEmpty)
            #expect(!failure.userMessage.contains("private-value") && !failure.recoveryMessage.contains("private-field"))
        }
    }
}
