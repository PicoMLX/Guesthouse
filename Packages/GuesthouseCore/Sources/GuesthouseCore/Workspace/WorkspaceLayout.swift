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

    public init(_ manifest: WorkspaceManifest) {
        self.manifest = manifest
    }

    public var root: String { "\(Self.workspacesDirectory)/\(manifest.name)" }
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
