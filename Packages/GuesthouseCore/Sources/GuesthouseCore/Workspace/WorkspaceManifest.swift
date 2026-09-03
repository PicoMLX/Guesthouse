import Foundation

/// The `workspace.json` that Guesthouse owns for one multi-repository workspace
/// (MVP-PLAN.md §6, "Workspace ownership and layout"). The GUI edits it; the user never
/// writes JSON.
public struct WorkspaceManifest: Codable, Hashable, Sendable {
    public var schemaVersion: SchemaVersion
    public var environmentID: EnvironmentID
    public var name: DirectoryName
    public var repositories: [WorkspaceRepository]
    /// Path of the app's `.xcodeproj` inside the app repository, for example `MyApp.xcodeproj`
    /// or `Apps/MyApp/MyApp.xcodeproj`.
    public var appProjectPath: String
    public var sharedScheme: String
    public var testDestination: TestDestination
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        schemaVersion: SchemaVersion = .current,
        environmentID: EnvironmentID,
        name: DirectoryName,
        repositories: [WorkspaceRepository],
        appProjectPath: String,
        sharedScheme: String,
        testDestination: TestDestination,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.environmentID = environmentID
        self.name = name
        self.repositories = repositories
        self.appProjectPath = appProjectPath
        self.sharedScheme = sharedScheme
        self.testDestination = testDestination
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var appRepository: WorkspaceRepository? { repositories.first { $0.role == .app } }
    public var packageRepositories: [WorkspaceRepository] { repositories.filter { $0.role == .package } }

    /// Every rule a manifest must satisfy before it is shown as a supported workspace.
    public func validate() throws(WorkspaceValidationError) {
        let apps = repositories.filter { $0.role == .app }
        guard apps.count == 1 else { throw .appRepositoryCount(apps.count) }

        var seenNames: Set<String> = []
        var seenRemotes: Set<String> = []
        var seenIdentities: Set<String> = []
        for repository in repositories {
            guard seenNames.insert(repository.checkoutName.identity).inserted else {
                throw .duplicateCheckoutName(repository.checkoutName.rawValue)
            }
            guard seenRemotes.insert(repository.remote.identity).inserted else {
                throw .duplicateRemote(repository.remote.canonical)
            }
            guard repository.remote.isSupportedHost else {
                throw .unsupportedHost(repository.remote.host)
            }
            guard repository.baseBranch != repository.taskBranch else {
                throw .taskBranchEqualsBaseBranch(repository.checkoutName.rawValue)
            }
            if repository.role == .package {
                // SwiftPM derives a local package's identity from its directory name and a Git
                // dependency's identity from the repository name, so the two must agree or the
                // override never applies (MVP-PLAN.md §6). Two packages with one identity are
                // ambiguous and refused.
                let identity = repository.remote.name.lowercased()
                guard repository.checkoutName.identity == identity else {
                    throw .checkoutNameDoesNotMatchRepository(checkout: repository.checkoutName.rawValue, repository: repository.remote.name)
                }
                guard seenIdentities.insert(identity).inserted else {
                    throw .duplicatePackageIdentity(identity)
                }
            }
        }

        guard Self.isRelativeProjectPath(appProjectPath) else { throw .invalidAppProjectPath(appProjectPath) }
        guard !sharedScheme.isEmpty, !sharedScheme.contains(where: { $0.isNewline || $0 == "/" }) else { throw .invalidScheme(sharedScheme) }
    }

    static func isRelativeProjectPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), path.hasSuffix(".xcodeproj") else { return false }
        guard !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

public struct WorkspaceRepository: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Hashable, Sendable {
        case app
        case package
    }

    public var role: Role
    public var remote: RemoteURL
    /// Directory name under `repos/`. Defaults to the repository name.
    public var checkoutName: DirectoryName
    public var baseBranch: BranchName
    /// Recorded when the clone is made; `nil` until then.
    public var baseSHA: CommitSHA?
    public var taskBranch: BranchName
    public var draftPullRequest: PullRequestReference?

    public init(role: Role, remote: RemoteURL, checkoutName: DirectoryName? = nil, baseBranch: BranchName, baseSHA: CommitSHA? = nil, taskBranch: BranchName, draftPullRequest: PullRequestReference? = nil) {
        self.role = role
        self.remote = remote
        self.checkoutName = checkoutName ?? DirectoryName(remote.name) ?? DirectoryName("repo")!
        self.baseBranch = baseBranch
        self.baseSHA = baseSHA
        self.taskBranch = taskBranch
        self.draftPullRequest = draftPullRequest
    }
}

public struct PullRequestReference: Codable, Hashable, Sendable {
    public var number: Int
    public var url: URL?
    /// The commit the PR head pointed at when Guesthouse last pushed.
    public var headSHA: CommitSHA?

    public init(number: Int, url: URL? = nil, headSHA: CommitSHA? = nil) {
        self.number = number
        self.url = url
        self.headSHA = headSHA
    }
}

/// An `xcodebuild -destination` specifier, kept structured so it is never assembled from
/// untrusted text.
public struct TestDestination: Codable, Hashable, Sendable {
    public var platform: String
    public var name: String?
    public var os: String?

    public init(platform: String, name: String? = nil, os: String? = nil) {
        self.platform = platform
        self.name = name
        self.os = os
    }

    public static let macOS = TestDestination(platform: "macOS")

    /// The `-destination` argument value.
    public var specifier: String {
        var parts = ["platform=\(platform)"]
        if let name { parts.append("name=\(name)") }
        if let os { parts.append("OS=\(os)") }
        return parts.joined(separator: ",")
    }
}

public enum WorkspaceValidationError: Error, Hashable, Sendable {
    case appRepositoryCount(Int)
    case duplicateCheckoutName(String)
    case duplicateRemote(String)
    case unsupportedHost(String)
    case taskBranchEqualsBaseBranch(String)
    case invalidAppProjectPath(String)
    case invalidScheme(String)
    case checkoutNameDoesNotMatchRepository(checkout: String, repository: String)
    case duplicatePackageIdentity(String)
}
