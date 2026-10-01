import Foundation

/// Private workspace metadata (MVP-PLAN.md §6), never diagnostic payload. Recorded commits
/// describe last-known facts; they do not authorize replay after an interrupted operation.
public struct WorkspaceManifest: Codable, Hashable, Sendable {
    /// Independent of environment and journal record epochs.
    public static let currentSchema = SchemaVersion(1)!
    public var schemaVersion: SchemaVersion
    public var environmentID: EnvironmentID
    public var name: DirectoryName
    public var repositories: [WorkspaceRepository]
    /// Relative to the app repository. Actual guest path containment must be checked at use.
    public var appProjectPath: String
    public var sharedScheme: String
    public var testDestination: TestDestination
    public var createdAt: Date
    public var updatedAt: Date

    public init(schemaVersion: SchemaVersion = WorkspaceManifest.currentSchema, environmentID: EnvironmentID, name: DirectoryName,
                repositories: [WorkspaceRepository], appProjectPath: String, sharedScheme: String,
                testDestination: TestDestination, createdAt: Date, updatedAt: Date) {
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
        /// The proposed workspace may not have clones or base commit records yet.
        case setup
        /// Every repository must have a recorded base commit. This is not live verification.
        case recorded
    }

    /// Structural validation only: no clone, filesystem, package override or tool readiness
    /// proof. Consumers reading guest data must supply the actual environment and directory.
    public func validate(stage: ValidationStage = .recorded, in environment: EnvironmentID? = nil,
                         directory: DirectoryName? = nil) throws(WorkspaceValidationError) {
        guard schemaVersion == Self.currentSchema else { throw .unsupportedSchemaVersion }
        if let environment, environment != environmentID { throw .environmentMismatch }
        if let directory, directory != name { throw .directoryMismatch }
        guard repositories.filter({ $0.role == .app }).count == 1 else { throw .appRepositoryCount }
        var remotes: Set<String> = [], checkouts: Set<String> = []
        for repository in repositories {
            guard remotes.insert(repository.remote.identity).inserted else { throw .duplicateRemote }
            guard checkouts.insert(repository.checkoutName.identity).inserted else { throw .duplicateCheckout }
            guard repository.remote.isSupportedHost else { throw .unsupportedHost }
            guard !repository.baseBranch.collides(with: repository.taskBranch) else { throw .branchCollision }
            if let reference = repository.draftPullRequest, !reference.isValid(for: repository.remote) {
                throw .invalidPullRequestReference
            }
            if repository.draftPullRequest != nil, repository.publishedSHA == nil { throw .missingPublishedSHA }
        }
        guard Self.isRelativeProjectPath(appProjectPath) else { throw .invalidProjectPath }
        guard !sharedScheme.isEmpty, !sharedScheme.contains("/"), sharedScheme.utf8.count <= Self.maximumSchemeBytes,
              !WorkspaceTextRules.containsDisplayControls(sharedScheme) else { throw .invalidScheme }
        guard testDestination.isValid else { throw .invalidDestination }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite, updatedAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt >= createdAt else { throw .invalidTimestamps }
        if stage == .recorded, repositories.contains(where: { $0.baseSHA == nil }) { throw .missingBaseSHA }
    }

    static let maximumPathComponentBytes = 255
    static let maximumProjectPathBytes = 512
    static let maximumSchemeBytes = maximumPathComponentBytes - ".xcscheme".utf8.count

    static func isRelativeProjectPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), path.hasSuffix(".xcodeproj"),
              path.utf8.count <= maximumProjectPathBytes, !WorkspaceTextRules.containsDisplayControls(path)
        else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= maximumPathComponentBytes
        }
    }

    public static let maximumEncodedSize = 64 * 1024
    private struct VersionEnvelope: Decodable { let schemaVersion: SchemaVersion }

    /// Persistence entry point: never produce a file larger than this reader accepts.
    /// Plain Codable is for editable model interchange, not unchecked guest-file writes.
    public func encoded(stage: ValidationStage = .recorded) throws(WorkspaceValidationError) -> Data {
        try validate(stage: stage)
        let data: Data
        do { data = try JSONEncoder().encode(self) } catch { throw .malformed }
        guard data.count <= Self.maximumEncodedSize else { throw .oversized }
        return data
    }

    /// Recorded guest files require independently known context, not identities read from
    /// the file itself. Decoding cannot substitute for live repository inspection.
    public static func decode(_ data: Data, in environment: EnvironmentID,
                              directory: DirectoryName) throws(WorkspaceValidationError) -> WorkspaceManifest {
        try read(data, stage: .recorded, environment: environment, directory: directory)
    }

    /// Explicit unbound proposal import; never establishes a recorded guest workspace.
    public static func decodeProposal(_ data: Data) throws(WorkspaceValidationError) -> WorkspaceManifest {
        try read(data, stage: .setup, environment: nil, directory: nil)
    }

    private static func read(_ data: Data, stage: ValidationStage, environment: EnvironmentID?,
                             directory: DirectoryName?) throws(WorkspaceValidationError) -> WorkspaceManifest {
        guard data.count <= maximumEncodedSize else { throw .oversized }
        // Future formats can omit current required fields; recognize their version first.
        if let envelope = try? JSONDecoder().decode(VersionEnvelope.self, from: data), envelope.schemaVersion != currentSchema {
            throw .unsupportedSchemaVersion
        }
        let manifest: WorkspaceManifest
        do { manifest = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw .malformed }
        try manifest.validate(stage: stage, in: environment, directory: directory)
        return manifest
    }
}

/// Closed failures never carry repository, branch, path, scheme or decoder text.
public enum WorkspaceValidationError: Error, Hashable, Sendable, LocalizedError, CaseIterable {
    case unsupportedSchemaVersion, environmentMismatch, directoryMismatch, appRepositoryCount
    case duplicateRemote, duplicateCheckout, unsupportedHost, branchCollision, invalidPullRequestReference
    case invalidProjectPath, invalidScheme, invalidDestination, invalidTimestamps, missingBaseSHA, missingPublishedSHA, oversized, malformed

    public var userMessage: String {
        switch self {
        case .unsupportedSchemaVersion: "This workspace uses a format this Guesthouse version cannot read."
        case .environmentMismatch: "This workspace belongs to a different development Mac."
        case .directoryMismatch: "The workspace name does not match the directory it was read from."
        case .appRepositoryCount: "A workspace needs exactly one app repository."
        case .duplicateRemote: "The same repository is selected more than once."
        case .duplicateCheckout: "Two repositories would use the same checkout folder."
        case .unsupportedHost: "Only repositories hosted on github.com are supported."
        case .branchCollision: "A task branch conflicts with its base branch."
        case .invalidPullRequestReference: "A recorded pull request does not identify this repository and PR number."
        case .invalidProjectPath: "The app project must have a bounded relative path inside the app repository."
        case .invalidScheme: "The shared scheme name is empty, too long or contains unsupported characters."
        case .invalidDestination: "The test destination contains an invalid or oversized field."
        case .invalidTimestamps: "The workspace timestamps are invalid or out of order."
        case .missingBaseSHA: "A repository has no recorded base commit. Its clone outcome must be inspected."
        case .missingPublishedSHA: "A recorded pull request has no recorded published commit. Its push outcome must be inspected."
        case .oversized: "The workspace file exceeds the supported size limit."
        case .malformed: "The workspace file could not be read as valid workspace metadata."
        }
    }

    public var recoveryMessage: String {
        switch self {
        case .unsupportedSchemaVersion: "Check for a compatible Guesthouse version before opening this workspace."
        case .missingBaseSHA: "Inspect the existing repositories before retrying any clone. Preserve their saved work."
        case .missingPublishedSHA: "Inspect the existing branch and pull request before another push or publish attempt."
        case .environmentMismatch, .directoryMismatch, .invalidTimestamps, .oversized, .malformed:
            "Inspect the workspace and its saved settings. Preserve existing repositories while correcting the metadata."
        case .duplicateCheckout: "Choose a distinct checkout folder for each repository."
        case .branchCollision: "Choose a task branch distinct from the base branch, its case variants and its slash prefixes."
        default: "Review the workspace settings and correct the selected repositories, project, scheme or destination."
        }
    }

    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .unsupportedSchemaVersion: [.updateApp, .cancel]
        case .missingBaseSHA, .missingPublishedSHA: [.inspectState, .cancel]
        case .environmentMismatch, .directoryMismatch, .invalidTimestamps, .oversized, .malformed: [.inspectState, .openSettings, .cancel]
        default: [.openSettings, .cancel]
        }
    }

    public var errorDescription: String? { userMessage }
}
