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
    ///
    /// Pass `environment` when the file was read from a development Mac: `workspace.json` lives
    /// in the guest, so its recorded environment is only trustworthy once it has been checked
    /// against the environment it actually came from.
    public func validate(stage: ValidationStage = .supported, in environment: EnvironmentID? = nil) throws(WorkspaceValidationError) {
        guard schemaVersion == SchemaVersion.current else { throw .unsupportedSchemaVersion(schemaVersion.rawValue) }
        if let environment, environmentID != environment { throw .environmentMismatch }
        let apps = repositories.filter { $0.role == .app }
        guard apps.count == 1 else { throw .appRepositoryCount(apps.count) }

        var seenNames: Set<String> = []
        var seenRemotes: Set<String> = []
        var seenIdentities: Set<String> = []
        for repository in repositories {
            // Package identity is settled before the checkout-name and remote checks, because
            // two packages that share a repository name also share their required checkout
            // name: reporting that as a duplicate folder would ask for a rename that the
            // identity rule in this block refuses.
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
                // A repository name no checkout directory can carry has no recovery through
                // renaming: `DirectoryName` refuses the very name the identity rule requires,
                // so the repository itself is what has to go.
                guard DirectoryName(repository.remote.name) != nil else {
                    throw .unsupportedPackageName(repository.remote.name)
                }
                guard repository.checkoutName.identity == identity else {
                    throw .checkoutNameDoesNotMatchRepository(checkout: repository.checkoutName.rawValue, repository: repository.remote.name)
                }
                guard seenIdentities.insert(identity).inserted else {
                    throw .duplicatePackageIdentity(identity)
                }
            }
            // The repeated remote is reported before the checkout name it implies: one
            // repository selected twice takes the same default folder, and asking for a
            // rename would only expose the duplicate remote on the next validation.
            guard seenRemotes.insert(repository.remote.identity).inserted else {
                throw .duplicateRemote(repository.remote.canonical)
            }
            guard seenNames.insert(repository.checkoutName.identity).inserted else {
                throw .duplicateCheckoutName(repository.checkoutName.rawValue)
            }
            guard repository.remote.isSupportedHost else {
                throw .unsupportedHost(repository.remote.host)
            }
            guard !repository.baseBranch.collides(with: repository.taskBranch) else {
                throw .taskBranchCollidesWithBaseBranch(repository.checkoutName.rawValue)
            }
            // Both branches are repository content, and both are written back into
            // `workspace.json`, so they are held to the same credential rule as the scheme,
            // the destination, and the project path: a ref named after a token would
            // otherwise be persisted verbatim and shown in the GUI.
            guard !Self.looksLikeCredential(repository.baseBranch.rawValue),
                  !Self.looksLikeCredential(repository.taskBranch.rawValue)
            else { throw .credentialInBranchName(repository.checkoutName.rawValue) }
            if let pullRequest = repository.draftPullRequest {
                guard pullRequest.isValid(for: repository.remote) else { throw .invalidPullRequestReference(repository.checkoutName.rawValue) }
            }
        }

        // The project path comes from discovery inside the guest and is persisted verbatim, so
        // it is held to the same credential rule as the scheme and the destination: a token that
        // named a `.xcodeproj` would otherwise be written back into `workspace.json`.
        guard Self.isRelativeProjectPath(appProjectPath), !Self.looksLikeCredential(appProjectPath) else {
            throw .invalidAppProjectPath(appProjectPath)
        }
        guard !sharedScheme.isEmpty, !sharedScheme.contains("/"), !Self.containsControlCharacters(sharedScheme),
              sharedScheme.utf8.count <= Self.maximumSchemeBytes, !Self.looksLikeCredential(sharedScheme)
        else { throw .invalidScheme(sharedScheme) }
        guard testDestination.isValid else { throw .invalidTestDestination(testDestination.specifier) }
        // Last, so a structural problem is reported before an incomplete clone is.
        if stage == .supported, let unclone = repositories.first(where: { $0.baseSHA == nil }) {
            throw .missingBaseSHA(unclone.checkoutName.rawValue)
        }
    }

    /// APFS and HFS+ both cap one directory entry at 255 bytes, so a longer component names a
    /// directory the guest cannot create.
    static let maximumPathComponentBytes = 255
    /// The project path is only part of the path the guest builds from it (`Workspaces/<name>/
    /// repos/<checkout>/…`), so it is bounded well inside macOS's 1024-byte pathname limit.
    static let maximumProjectPathBytes = 512
    /// A shared scheme is a `<name>.xcscheme` file in the project, so a name that cannot leave
    /// room for that suffix within one directory entry names no scheme `xcodebuild` can find.
    static let maximumSchemeBytes = maximumPathComponentBytes - ".xcscheme".utf8.count

    /// Whether the redaction layer recognizes a credential in this value.
    ///
    /// The bare device-code shape is excluded on purpose: without context it also matches a
    /// plausible scheme name such as `PROD-2024`, and refusing that would reject a workspace
    /// Xcode builds. Every other pattern names something no `.xcscheme` file is called.
    static func looksLikeCredential(_ text: String) -> Bool {
        Redactor().redact(fieldValue: text) != Redactor.applyDeviceCodePattern(to: text)
    }

    static func isRelativeProjectPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), path.hasSuffix(".xcodeproj"), !containsControlCharacters(path),
              path.utf8.count <= maximumProjectPathBytes
        else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        // A component the guest cannot create makes the whole path unreachable, so it is
        // refused here rather than at checkout or build.
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= maximumPathComponentBytes }
    }

    /// Control, format, and separator characters cannot travel in an argument vector, and
    /// separators would let one value render as several lines in the GUI. Noncharacters are
    /// reserved against interchange and would reach the confirmation UI as replacement glyphs.
    static func containsControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: true
            default: scalar.properties.isNoncharacterCodePoint
            }
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
    /// The commit last pushed to `taskBranch`, recorded the moment the push completes.
    ///
    /// It sits beside the repository rather than inside `draftPullRequest` because a push can
    /// succeed and the pull request that follows it fail (MVP-PLAN.md §7): the reference cannot
    /// exist until GitHub has issued a number, and resume must still be able to tell a finished
    /// push from one that was never attempted.
    public var publishedSHA: CommitSHA?
    public var draftPullRequest: PullRequestReference?

    public init(role: Role, remote: RemoteURL, checkoutName: DirectoryName? = nil, baseBranch: BranchName, baseSHA: CommitSHA? = nil, taskBranch: BranchName, publishedSHA: CommitSHA? = nil, draftPullRequest: PullRequestReference? = nil) {
        self.role = role
        self.remote = remote
        self.checkoutName = checkoutName ?? DirectoryName.derived(from: remote.name)
        self.baseBranch = baseBranch
        self.baseSHA = baseSHA
        self.taskBranch = taskBranch
        self.publishedSHA = publishedSHA
        self.draftPullRequest = draftPullRequest
    }
}

public struct PullRequestReference: Codable, Hashable, Sendable {
    public var number: Int
    public var url: URL?

    public init(number: Int, url: URL? = nil) {
        self.number = number
        self.url = url
    }

    /// A positive number, and if a link is recorded, the HTTPS pull-request page of exactly
    /// this repository; a guest-owned manifest is never allowed to point anywhere else.
    public func isValid(for remote: RemoteURL) -> Bool {
        guard number > 0 else { return false }
        guard let url else { return true }
        // The route itself is a case-sensitive URL path, so only the scheme, host, owner, and
        // repository are compared without regard to case, as GitHub resolves them: a `/PULL/`
        // link does not open the recorded pull request.
        let text = url.absoluteString
        let route = "/pull/\(number)"
        guard text.hasSuffix(route) else { return false }
        return text.dropLast(route.count).lowercased() == remote.canonical.lowercased()
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

    /// Xcode's own platform, device, and OS values are a few dozen bytes; a field beyond this
    /// names no destination, and the whole specifier stays well inside the argument the guest
    /// can pass to `xcodebuild`.
    static let maximumFieldBytes = 128
    static let maximumSpecifierBytes = 512

    /// Non-empty platform, no value that would add or change a key in the specifier, nothing
    /// so large that the invocation could not carry it, and no credential.
    ///
    /// The fields come from destination discovery, which reports names a person chose: a
    /// simulator or Mac renamed to a token would otherwise be persisted in `workspace.json`
    /// and shown back in the GUI, so they are held to the same credential rule as the scheme.
    public var isValid: Bool {
        guard !platform.isEmpty, specifier.utf8.count <= Self.maximumSpecifierBytes else { return false }
        return [platform, name ?? "x", os ?? "x"].allSatisfy { value in
            !value.isEmpty && !value.contains(",") && !value.contains("=") && !WorkspaceManifest.containsControlCharacters(value)
                && value.utf8.count <= Self.maximumFieldBytes && !WorkspaceManifest.looksLikeCredential(value)
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
    /// A branch name the redaction layer reads as a credential, named by its checkout.
    case credentialInBranchName(String)
    case missingBaseSHA(String)
    case invalidPullRequestReference(String)
    case invalidAppProjectPath(String)
    case invalidScheme(String)
    case invalidTestDestination(String)
    case checkoutNameDoesNotMatchRepository(checkout: String, repository: String)
    /// A package repository whose own name cannot be a checkout directory, so the identity
    /// rule can never be satisfied by renaming anything.
    case unsupportedPackageName(String)
    case duplicatePackageIdentity(String)
    /// The manifest names a development Mac other than the one it was read from.
    case environmentMismatch
    /// The manifest names a workspace other than the directory that contained it.
    case nameDoesNotMatchDirectory(manifest: String, directory: String)
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
        case .credentialInBranchName(let name):
            "A branch chosen for \(GuesthouseError.sanitize(name)) reads as a token, and Guesthouse does not save credentials into the workspace file. Choose branches whose names are not secrets."
        case .missingBaseSHA(let name):
            "Guesthouse has no record of the commit \(GuesthouseError.sanitize(name)) was cloned at, so whether that clone finished is unknown until the development Mac is inspected."
        case .invalidPullRequestReference(let name):
            "The draft pull request recorded for \(GuesthouseError.sanitize(name)) belongs to another repository, so Guesthouse will not open this workspace. Remove that pull request from the workspace's settings; publishing then creates a fresh draft."
        case .invalidAppProjectPath(let path):
            "\(GuesthouseError.sanitize(path)) is not a project path inside the app repository."
        case .invalidScheme(let scheme):
            "\(GuesthouseError.sanitize(scheme)) is not a valid scheme name."
        case .invalidTestDestination(let destination):
            "\(GuesthouseError.sanitize(destination)) is not a valid test destination."
        case .malformed(let reason):
            "The workspace file in the development Mac could not be read (\(reason.value)). Guesthouse can rebuild it from the repositories you selected."
        case .checkoutNameDoesNotMatchRepository(let checkout, let repository):
            "The package repository \(GuesthouseError.sanitize(repository)) must be checked out as \(GuesthouseError.sanitize(repository)), not \(GuesthouseError.sanitize(checkout)), or Xcode will not use the local copy."
        case .unsupportedPackageName(let repository):
            "The package repository \(GuesthouseError.sanitize(repository)) cannot be checked out under its own name, which is what Xcode needs to use the local copy: a folder name is at most 64 letters, digits, dots, dashes, or underscores and cannot begin with a dot. Remove that repository from the workspace, or choose another one."
        case .duplicatePackageIdentity(let identity):
            "Two package repositories share the identity \(GuesthouseError.sanitize(identity)); Xcode could not tell them apart. Remove one of them from the workspace."
        case .environmentMismatch:
            "This workspace file belongs to another development Mac, so Guesthouse will not open it here."
        case .nameDoesNotMatchDirectory(let manifest, let directory):
            "The workspace in the folder \(GuesthouseError.sanitize(directory)) calls itself \(GuesthouseError.sanitize(manifest)), so Guesthouse cannot tell which workspace it is."
        }
    }

    /// In preference order. Never empty.
    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .unsupportedSchemaVersion: [.reinstallApp, .cancel]
        // The clone may have finished with only the manifest update lost, so the outcome is
        // not known: only inspection is offered, never a blind repeat.
        case .missingBaseSHA: [.inspectState, .cancel]
        // Rebuilding the workspace file is a workspace action, not one of §9's targeted
        // repairs: none of those repair kinds writes `workspace.json`.
        case .malformed: [.inspectState, .openSettings, .cancel]
        case .environmentMismatch, .nameDoesNotMatchDirectory: [.inspectState, .openSettings, .cancel]
        default: [.openSettings, .cancel]
        }
    }

    public var errorDescription: String? { userMessage }
}

public extension WorkspaceManifest {
    /// Reads a manifest that came from the guest. Structural failures become
    /// `WorkspaceValidationError.malformed`, which carries a message and recovery actions,
    /// rather than a bare `DecodingError` the app cannot present.
    /// `workspace.json` describes a handful of repositories. Anything beyond this is not a
    /// manifest, and a guest-controlled file must be refused by size before a decoder walks it.
    static let maximumEncodedSize = 64 * 1024

    /// Just the version, so a file this build cannot decode is still recognized as one a newer
    /// Guesthouse wrote rather than reported as damaged.
    private struct VersionEnvelope: Decodable {
        var schemaVersion: SchemaVersion
    }

    static func decode(_ data: Data) throws(WorkspaceValidationError) -> WorkspaceManifest {
        guard data.count <= Self.maximumEncodedSize else {
            throw WorkspaceValidationError.malformed(reason: SanitizedText("the file is larger than a workspace can be"))
        }
        // The version comes first: a newer schema may have renamed or removed a field the
        // current shape requires, and the answer to that is to update Guesthouse, not to
        // rebuild a file that is not damaged.
        if let envelope = try? JSONDecoder().decode(VersionEnvelope.self, from: data), envelope.schemaVersion != .current {
            throw WorkspaceValidationError.unsupportedSchemaVersion(envelope.schemaVersion.rawValue)
        }
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
