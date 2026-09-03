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

    public enum ValidationStage: Sendable {
        /// The workspace is being created: clones have not happened, so base commits are absent.
        case setup
        /// The workspace is offered as supported: every repository has its recorded base commit.
        case supported
    }

    /// Every rule a manifest must satisfy before it is shown as a supported workspace.
    public func validate(stage: ValidationStage = .supported) throws(WorkspaceValidationError) {
        guard schemaVersion == SchemaVersion.current else { throw .unsupportedSchemaVersion(schemaVersion.rawValue) }
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
            guard !repository.baseBranch.collides(with: repository.taskBranch) else {
                throw .taskBranchCollidesWithBaseBranch(repository.checkoutName.rawValue)
            }
            if let pullRequest = repository.draftPullRequest {
                guard pullRequest.isValid(for: repository.remote) else { throw .invalidPullRequestReference(repository.checkoutName.rawValue) }
            }
            if repository.role == .package {
                // SwiftPM derives a local package's identity from its directory name and a Git
                // dependency's identity from the repository name, so the two must agree or the
                // override never applies (MVP-PLAN.md §6). Two packages with one identity are
                // ambiguous and refused.
                // A package's checkout directory is where SwiftPM reads the local package's
                // identity, so it must be the repository's own name. A name the deriver has
                // to change (too long, or leading dots) would produce a package that cannot
                // replace the pinned dependency, so such a repository is refused outright
                // rather than checked out under a name that means something else.
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
        guard !sharedScheme.isEmpty, !sharedScheme.contains("/"), !Self.containsControlCharacters(sharedScheme) else { throw .invalidScheme(sharedScheme) }
        guard testDestination.isValid else { throw .invalidTestDestination(testDestination.specifier) }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite, updatedAt.timeIntervalSinceReferenceDate.isFinite else { throw .invalidTimestamp }
        // Last, so a structural problem is reported before an incomplete clone is.
        if stage == .supported, let unclone = repositories.first(where: { $0.baseSHA == nil }) {
            throw .missingBaseSHA(unclone.checkoutName.rawValue)
        }
    }

    static func isRelativeProjectPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), path.hasSuffix(".xcodeproj"), !containsControlCharacters(path) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Control, format, and separator characters cannot travel in an argument vector,
    /// separators would let one value render as several lines in the GUI, and scalars outside
    /// the XML character set cannot be serialized into the workspace file.
    static func containsControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return true
            default: break
            }
            return scalar.properties.isNoncharacterCodePoint || scalar.value == 0xFFFE || scalar.value == 0xFFFF
        }
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
        self.checkoutName = checkoutName ?? DirectoryName.derived(from: remote.name)
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

    /// A positive number, and if a link is recorded, the HTTPS pull-request page of exactly
    /// this repository; a guest-owned manifest is never allowed to point anywhere else.
    public func isValid(for remote: RemoteURL) -> Bool {
        guard number > 0 else { return false }
        guard let url else { return true }
        return url.absoluteString.lowercased() == "\(remote.canonical.lowercased())/pull/\(number)"
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

    /// Non-empty platform, and no value that would add or change a key in the specifier.
    public var isValid: Bool {
        guard !platform.isEmpty else { return false }
        return [platform, name ?? "x", os ?? "x"].allSatisfy { value in
            !value.isEmpty && !value.contains(",") && !value.contains("=") && !WorkspaceManifest.containsControlCharacters(value)
        }
    }

    /// The `-destination` argument value.
    public var specifier: String {
        var parts = ["platform=\(platform)"]
        if let name { parts.append("name=\(name)") }
        if let os { parts.append("OS=\(os)") }
        return parts.joined(separator: ",")
    }
}

public enum WorkspaceValidationError: Error, Hashable, Sendable, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case appRepositoryCount(Int)
    case duplicateCheckoutName(String)
    case duplicateRemote(String)
    case unsupportedHost(String)
    case taskBranchCollidesWithBaseBranch(String)
    case missingBaseSHA(String)
    case invalidPullRequestReference(String)
    case invalidAppProjectPath(String)
    case invalidScheme(String)
    case invalidTestDestination(String)
    /// A timestamp that cannot be encoded.
    case invalidTimestamp
    case checkoutNameDoesNotMatchRepository(checkout: String, repository: String)
    case duplicatePackageIdentity(String)
    /// The file could not be read as a workspace at all.
    case malformed(reason: SanitizedText)

    public var userMessage: String {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "This workspace was saved by a newer Guesthouse (format \(version)). Update Guesthouse to open it."
        case .appRepositoryCount(let count):
            "A workspace needs exactly one app repository; this one has \(count)."
        case .duplicateCheckoutName(let name):
            "Two repositories would be checked out as \(GuesthouseError.sanitize(name)). Give one of them another folder name."
        case .duplicateRemote(let remote):
            "The repository \(GuesthouseError.sanitize(remote)) is listed twice."
        case .unsupportedHost(let host):
            "Repositories on \(GuesthouseError.sanitize(host)) are not supported yet; only github.com is."
        case .taskBranchCollidesWithBaseBranch(let name):
            "The task branch for \(GuesthouseError.sanitize(name)) cannot exist alongside its base branch. Choose a branch name that is not the base branch, its case variant, or a prefix of it."
        case .missingBaseSHA(let name):
            "The repository \(GuesthouseError.sanitize(name)) has not been cloned yet, so the workspace cannot be used until setup finishes."
        case .invalidPullRequestReference(let name):
            "The draft pull request recorded for \(GuesthouseError.sanitize(name)) does not belong to that repository, so it was ignored. Publishing will create a fresh draft."
        case .invalidAppProjectPath(let path):
            "\(GuesthouseError.sanitize(path)) is not a project path inside the app repository."
        case .invalidScheme(let scheme):
            "\(GuesthouseError.sanitize(scheme)) is not a valid scheme name."
        case .invalidTestDestination(let destination):
            "\(GuesthouseError.sanitize(destination)) is not a valid test destination."
        case .malformed(let reason):
            "The workspace file in the development Mac could not be read (\(reason.value)). Guesthouse can rebuild it from the repositories you selected."
        case .invalidTimestamp:
            "The workspace carries a timestamp that cannot be saved. This is a bug in Guesthouse."
        case .checkoutNameDoesNotMatchRepository(let checkout, let repository):
            "The package repository \(GuesthouseError.sanitize(repository)) must be checked out as \(GuesthouseError.sanitize(repository)), not \(GuesthouseError.sanitize(checkout)), or Xcode will not use the local copy."
        case .duplicatePackageIdentity(let identity):
            "Two package repositories share the identity \(GuesthouseError.sanitize(identity)); Xcode could not tell them apart."
        }
    }

    /// In preference order. Never empty.
    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .unsupportedSchemaVersion: [.reinstallApp, .cancel]
        // The clone may have finished with only the manifest update lost, so the outcome is
        // not known: only inspection is offered, never a blind repeat.
        case .missingBaseSHA: [.inspectState, .cancel]
        case .malformed: [.inspectState, .repair(.tools), .cancel]
        default: [.openSettings, .cancel]
        }
    }

    public var errorDescription: String? { userMessage }
}

public extension WorkspaceManifest {
    /// Reads a manifest that came from the guest. Structural failures become
    /// `WorkspaceValidationError.malformed`, which carries a message and recovery actions,
    /// rather than a bare `DecodingError` the app cannot present.
    static func decode(_ data: Data) throws(WorkspaceValidationError) -> WorkspaceManifest {
        do {
            return try JSONDecoder().decode(WorkspaceManifest.self, from: data)
        } catch {
            throw WorkspaceValidationError.malformed(reason: SanitizedText(Self.reason(for: error), limit: 200))
        }
    }

    private static func reason(for error: any Error) -> String {
        guard let error = error as? DecodingError else { return "the file could not be read" }
        switch error {
        case .keyNotFound(let key, _):
            return "a required field is missing: \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return context.codingPath.isEmpty ? "the file is not a valid workspace" : "an invalid value at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        @unknown default:
            return "the file is not a valid workspace"
        }
    }
}
