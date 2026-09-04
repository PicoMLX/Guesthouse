/// Guest paths for one workspace, all relative to the environment's `Workspaces/` directory
/// (MVP-PLAN.md §6). Never absolute: the guest's home directory is not persistent identity.
///
/// ```
/// Workspaces/<name>/
/// ├── AGENTS.md
/// ├── workspace.json
/// ├── Integration.xcworkspace/
/// ├── repos/<checkout>/
/// └── artifacts/
/// ```
public struct WorkspaceLayout: Hashable, Sendable {
    public static let workspacesDirectory = "Workspaces"
    public static let manifestFileName = "workspace.json"
    public static let agentsGuideFileName = "AGENTS.md"
    public static let integrationWorkspaceName = "Integration.xcworkspace"

    public let manifest: WorkspaceManifest
    /// The directory this workspace lives in. Every path below is derived from it rather than
    /// from `manifest.name`, because `workspace.json` is guest-resident: a modified name would
    /// otherwise point the manifest, repository, project, and artifact paths of the workspace
    /// the user opened at a different workspace's directory.
    public let directoryName: DirectoryName

    /// A workspace Guesthouse is creating, whose chosen name becomes its directory.
    public init(_ manifest: WorkspaceManifest) {
        self.manifest = manifest
        directoryName = manifest.name
    }

    /// A workspace read from `directory` under `Workspaces/`. The containing directory is the
    /// trusted context, so a manifest that names another workspace is refused rather than
    /// allowed to choose its own root.
    public init(_ manifest: WorkspaceManifest, loadedFrom directory: DirectoryName) throws(WorkspaceValidationError) {
        guard manifest.name.identity == directory.identity else {
            throw .nameDoesNotMatchDirectory(manifest: manifest.name.rawValue, directory: directory.rawValue)
        }
        self.manifest = manifest
        directoryName = directory
    }

    public var root: String { "\(Self.workspacesDirectory)/\(directoryName)" }
    public var manifestFile: String { "\(root)/\(Self.manifestFileName)" }
    public var agentsGuide: String { "\(root)/\(Self.agentsGuideFileName)" }
    public var integrationWorkspace: String { "\(root)/\(Self.integrationWorkspaceName)" }
    public var repositoriesDirectory: String { "\(root)/repos" }
    public var artifactsDirectory: String { "\(root)/artifacts" }

    public func repositoryDirectory(_ repository: WorkspaceRepository) -> String {
        "\(repositoriesDirectory)/\(repository.checkoutName)"
    }

    /// The app's `.xcodeproj`, or `nil` when the manifest has no app repository.
    public var appProject: String? {
        manifest.appRepository.map { "\(repositoryDirectory($0))/\(manifest.appProjectPath)" }
    }

    /// Paths relative to the workspace root, for the integration workspace's `group:` references.
    public func repositoryPathFromRoot(_ repository: WorkspaceRepository) -> String {
        "repos/\(repository.checkoutName)"
    }
}
