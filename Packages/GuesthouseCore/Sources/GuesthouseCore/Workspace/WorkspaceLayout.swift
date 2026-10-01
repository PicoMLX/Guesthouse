/// Relative guest paths for a validated snapshot (MVP-PLAN.md §6). This performs no I/O;
/// runtime consumers must separately enforce actual guest path containment, including links.
/// Naming an integration workspace does not select or activate the held package workflow.
public struct WorkspaceLayout: Hashable, Sendable {
    public static let workspacesDirectory = "Workspaces"
    public static let manifestFileName = "workspace.json"
    public static let agentsGuideFileName = "AGENTS.md"
    public static let integrationWorkspaceName = "Integration.xcworkspace"

    public let manifest: WorkspaceManifest
    public let directoryName: DirectoryName

    /// A proposed workspace. Recorded clone facts need not exist yet.
    public init(proposed manifest: WorkspaceManifest) throws(WorkspaceValidationError) {
        try manifest.validate(stage: .setup)
        self.manifest = manifest
        directoryName = manifest.name
    }

    /// A recorded workspace must match the environment and actual containing directory.
    /// Its saved metadata is not proof of current clone, disk or runtime state.
    public init(_ manifest: WorkspaceManifest, in environment: EnvironmentID,
                loadedFrom directory: DirectoryName) throws(WorkspaceValidationError) {
        try manifest.validate(in: environment, directory: directory)
        self.manifest = manifest
        directoryName = directory
    }

    public var root: String { "\(Self.workspacesDirectory)/\(directoryName.rawValue)" }
    public var manifestFile: String { "\(root)/\(Self.manifestFileName)" }
    public var agentsGuide: String { "\(root)/\(Self.agentsGuideFileName)" }
    public var integrationWorkspace: String { "\(root)/\(Self.integrationWorkspaceName)" }
    public var repositoriesDirectory: String { "\(root)/repos" }
    public var artifactsDirectory: String { "\(root)/artifacts" }

    /// Refuses repositories outside this validated snapshot, even when their folder is safe.
    public func repositoryDirectory(_ repository: WorkspaceRepository) -> String? {
        repositoryPathFromRoot(repository).map { "\(root)/\($0)" }
    }

    public func repositoryPathFromRoot(_ repository: WorkspaceRepository) -> String? {
        guard manifest.repositories.contains(repository) else { return nil }
        return "repos/\(repository.checkoutName.rawValue)"
    }

    public var appProject: String? {
        guard let app = manifest.appRepository, let directory = repositoryDirectory(app) else { return nil }
        return "\(directory)/\(manifest.appProjectPath)"
    }
}
