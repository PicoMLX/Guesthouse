import Foundation

/// A file the generator wants written, relative to the workspace root.
public struct GeneratedFile: Hashable, Sendable {
    public let relativePath: String
    public let contents: Data

    public init(relativePath: String, contents: Data) {
        self.relativePath = relativePath
        self.contents = contents
    }

    public init(relativePath: String, text: String) {
        self.init(relativePath: relativePath, contents: Data(text.utf8))
    }
}

/// Produces the wrapper `.xcworkspace`, the seeded resolution file, the agent guide, and the
/// manifest for one workspace (MVP-PLAN.md §6, "Deterministic local package overrides").
///
/// Pure: it returns files and never touches the repositories. Output is deterministic, so
/// regenerating an unchanged manifest yields byte-identical files. The committed app project
/// and package manifests are never edited; the override happens because the wrapper workspace
/// contains both the app project and the local package directories.
public enum GeneratedFileError: Error, Hashable, Sendable {
    case invalidPath(String)
    case pathOutsideWorkspace(String)
}

public enum IntegrationWorkspaceGenerator {
    public static let resolvedPackagesRelativePath = "\(WorkspaceLayout.integrationWorkspaceName)/xcshareddata/swiftpm/Package.resolved"

    /// - Parameter appResolvedPackages: the app repository's committed `Package.resolved`, read by
    ///   the caller, or `nil` when the project has none. It is copied unchanged so the wrapper
    ///   resolves from the same pins the app does.
    public static func generate(_ manifest: WorkspaceManifest, appResolvedPackages: Data? = nil) throws(WorkspaceValidationError) -> [GeneratedFile] {
        try manifest.validate()
        let layout = WorkspaceLayout(manifest)
        var files: [GeneratedFile] = []
        files.append(GeneratedFile(relativePath: "\(WorkspaceLayout.integrationWorkspaceName)/contents.xcworkspacedata", text: workspaceData(manifest, layout: layout)))
        if let appResolvedPackages {
            files.append(GeneratedFile(relativePath: resolvedPackagesRelativePath, contents: appResolvedPackages))
        }
        files.append(GeneratedFile(relativePath: WorkspaceLayout.agentsGuideFileName, text: agentsGuide(manifest, layout: layout)))
        files.append(GeneratedFile(relativePath: WorkspaceLayout.manifestFileName, contents: encodedManifest(manifest)))
        return files
    }

    /// Writes the generated files under `root`, creating directories as needed, and removes
    /// the generator-owned optional resolution file when this generation did not produce one,
    /// so a stale lockfile cannot outlive the app's own.
    ///
    /// Every path is normalized first: it must be relative, contain no `.` or `..` components,
    /// and its first component must not be `repos` in any letter case (the usual macOS file
    /// system is case-insensitive); the resolved location must lie inside `root`. The
    /// repositories belong to Git, not to the generator.
    public static func write(_ files: [GeneratedFile], to root: URL) throws {
        let resolvedRoot = root.standardizedFileURL
        for file in files {
            let url = try destination(for: file.relativePath, in: resolvedRoot)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.contents.write(to: url, options: .atomic)
        }
        if !files.contains(where: { $0.relativePath == resolvedPackagesRelativePath }) {
            let stale = try destination(for: resolvedPackagesRelativePath, in: resolvedRoot)
            if FileManager.default.fileExists(atPath: stale.path) {
                try FileManager.default.removeItem(at: stale)
            }
        }
    }

    static func destination(for relativePath: String, in resolvedRoot: URL) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw GeneratedFileError.invalidPath(relativePath) }
        guard components[0].lowercased() != "repos" else { throw GeneratedFileError.pathOutsideWorkspace(relativePath) }
        var url = resolvedRoot
        for component in components { url.append(path: component) }
        guard url.standardizedFileURL.path.hasPrefix(resolvedRoot.path + "/") else {
            throw GeneratedFileError.pathOutsideWorkspace(relativePath)
        }
        return url
    }

    // MARK: - contents.xcworkspacedata

    static func workspaceData(_ manifest: WorkspaceManifest, layout: WorkspaceLayout) -> String {
        var locations: [String] = []
        if let app = manifest.appRepository {
            locations.append("group:\(layout.repositoryPathFromRoot(app))/\(manifest.appProjectPath)")
        }
        for package in manifest.packageRepositories.sorted(by: { $0.checkoutName.identity < $1.checkoutName.identity }) {
            locations.append("group:\(layout.repositoryPathFromRoot(package))")
        }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Workspace\n   version = \"1.0\">\n"
        for location in locations {
            xml += "   <FileRef\n      location = \"\(escape(location))\">\n   </FileRef>\n"
        }
        xml += "</Workspace>\n"
        return xml
    }

    /// XML attribute escaping. Control and format characters never reach here: the manifest
    /// rejects them in `appProjectPath`, and checkout names are restricted to a safe set.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - AGENTS.md

    static func agentsGuide(_ manifest: WorkspaceManifest, layout: WorkspaceLayout) -> String {
        let app = manifest.appRepository
        let packages = manifest.packageRepositories.sorted(by: { $0.checkoutName.identity < $1.checkoutName.identity })
        var text = """
        # Workspace \(manifest.name)

        Generated by Guesthouse from `workspace.json`. Do not edit this file, the workspace file, or `workspace.json` by hand; regenerate them from the Guesthouse app.

        This directory groups several Git repositories so that the app can be built against local edits of its sibling packages. It is not itself a Git repository. Each repository under `repos/` has its own history, remote, and pull request.

        ## Repositories

        | Directory | Role | Remote | Base branch | Task branch |
        | --- | --- | --- | --- | --- |

        """
        for repository in manifest.repositories.sorted(by: { ($0.role == .app ? 0 : 1, $0.checkoutName.identity) < ($1.role == .app ? 0 : 1, $1.checkoutName.identity) }) {
            text += "| `\(layout.repositoryPathFromRoot(repository))` | \(repository.role.rawValue) | \(repository.remote.canonical) | `\(repository.baseBranch)` | `\(repository.taskBranch)` |\n"
        }
        text += """

        ## Build and test

        Always build through the integration workspace, never through the app project alone. The workspace contains the app project and every package directory above, so the app resolves those packages from the local checkouts instead of the versions pinned in its `Package.resolved`:

        ```bash
        xcodebuild -workspace \(WorkspaceLayout.integrationWorkspaceName) -scheme \(manifest.sharedScheme) -destination '\(manifest.testDestination.specifier)' -derivedDataPath artifacts/DerivedData -clonedSourcePackagesDirPath artifacts/SourcePackages test
        ```

        Build state and downloaded package sources stay under `artifacts/` so a workspace can be cleaned or exported as a unit and nothing lands in Xcode's shared defaults.

        A green result here means the app builds against the sibling package changes in this workspace. It does not mean the app's own pull request will pass its CI, which builds against the published package versions. Both results matter.

        ## Local package mapping

        """
        if packages.isEmpty {
            text += "No package repositories are part of this workspace.\n"
        } else {
            for package in packages {
                text += "- `\(layout.repositoryPathFromRoot(package))` overrides the dependency on \(package.remote.canonical) (package identity `\(package.remote.name.lowercased())`).\n"
            }
        }
        if let app {
            text += "\nThe app project is `\(layout.repositoryPathFromRoot(app))/\(manifest.appProjectPath)` with shared scheme `\(manifest.sharedScheme)`.\n"
        }
        text += """

        ## Branch policy

        - Work only on each repository's task branch listed above. Do not switch branches, rebase, or merge.
        - Commit reviewed changes with clear messages. Do not stage build products, caches, or secrets.
        - Do not push, force-push, or open pull requests yourself. Guesthouse publishes each repository's task branch and opens one draft pull request per changed repository, in dependency order (packages before the app).
        - Do not edit the app repository's committed `Package.resolved` or its project file to point at local packages; the integration workspace already does that.
        - Keep DerivedData and package caches under `artifacts/`; do not write into a repository directory anything that is not meant to be committed.

        ## Pull request expectations

        One pull request per changed repository. A package change that alters public API usually has to merge and be released or pinned before the app's dependency update is valid; say so in the app pull request.
        """
        return text + "\n"
    }

    // MARK: - workspace.json

    /// ISO 8601 with fractional seconds, matching the state store, so timestamps round-trip.
    public static let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func encodedManifest(_ manifest: WorkspaceManifest) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.dateFormat.format(date))
        }
        // A manifest that validated cannot fail to encode; every field is a plain value type.
        return (try? encoder.encode(manifest)) ?? Data()
    }
}
