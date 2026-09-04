import Darwin
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

/// How the app repository builds today, as the caller found it. MVP-PLAN.md §6 supports "a
/// committed `.xcodeproj` and shared scheme" for the first release and requires complex
/// existing workspace composition to be detected rather than silently rewritten, so the caller
/// that can read the repository states what it saw instead of the generator assuming the
/// simple shape.
public enum AppProjectLayout: Hashable, Sendable {
    /// The app builds from the committed `.xcodeproj` alone, so the wrapper workspace can
    /// contain that project and stand in for it. The `project.xcworkspace` that lives inside
    /// every `.xcodeproj` is part of the project, not a composition, and does not count.
    case project
    /// The app repository carries its own `.xcworkspace`, which may add further projects,
    /// workspace-level schemes, or settings that the wrapper would not reproduce.
    case existingWorkspace(name: String)
}

/// Produces the wrapper `.xcworkspace`, the seeded resolution file, the agent guide, and the
/// manifest for one workspace (MVP-PLAN.md §6, "Deterministic local package overrides").
///
/// Pure: it returns files and never touches the repositories. Output is deterministic, so
/// regenerating an unchanged manifest yields byte-identical files. The committed app project
/// and package manifests are never edited; the override happens because the wrapper workspace
/// contains both the app project and the local package directories.
/// Why a generated file could not be placed or written; each names what the user can do.
public enum GeneratedFileError: Error, Hashable, Sendable, LocalizedError {
    case invalidPath(String)
    case pathOutsideWorkspace(String)
    /// A real I/O failure (full disk, denied directory), with a sanitized reason.
    case unwritable(path: String, reason: SanitizedText)

    public var userMessage: String {
        switch self {
        case .invalidPath(let path):
            "Guesthouse would not write the workspace file \(GuesthouseError.sanitize(path)) because its path is not a plain relative path. This is a bug in Guesthouse."
        case .pathOutsideWorkspace(let path):
            "Guesthouse would not write \(GuesthouseError.sanitize(path)) because it lies outside the workspace or inside a repository. This is a bug in Guesthouse."
        case .unwritable(let path, let reason):
            "The workspace file \(GuesthouseError.sanitize(path)) could not be written (\(reason.value)). Free disk space on the development Mac or repair the workspace, then try again."
        }
    }

    /// In preference order. Never empty.
    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .invalidPath, .pathOutsideWorkspace: [.cancel]
        case .unwritable: [.freeDiskSpace, .retry, .repair(.tools), .cancel]
        }
    }

    public var errorDescription: String? { userMessage }
}

public enum IntegrationWorkspaceGenerator {
    public static let resolvedPackagesRelativePath = "\(WorkspaceLayout.integrationWorkspaceName)/xcshareddata/swiftpm/Package.resolved"

    /// - Parameters:
    ///   - appProjectLayout: what the caller found in the app repository. There is no default:
    ///     an app that builds through its own workspace is refused here rather than given a
    ///     wrapper that silently leaves that composition out (MVP-PLAN.md §6).
    ///   - appResolvedPackages: the app repository's committed `Package.resolved`, read by
    ///     the caller, or `nil` when the project has none. It is copied unchanged so the wrapper
    ///     resolves from the same pins the app does.
    public static func generate(_ manifest: WorkspaceManifest, appProjectLayout: AppProjectLayout, appResolvedPackages: Data? = nil) throws(WorkspaceValidationError) -> [GeneratedFile] {
        // Generation happens while the workspace is being set up, before every clone has
        // recorded its base commit, so the structural rules apply and the base-SHA rule waits
        // for the supported-workspace check.
        try manifest.validate(stage: .setup)
        if case .existingWorkspace(let name) = appProjectLayout {
            throw .unsupportedAppWorkspace(name)
        }
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
    /// and its first component must not be `repos` under the file system's own case folding.
    /// The walk down to each file then happens through directory descriptors opened with
    /// no-follow semantics, and the file is created and renamed inside the descriptor of the
    /// directory that was checked, so a guest agent that swaps a directory for a link between
    /// the check and the write cannot redirect it. The repositories belong to Git, not to the
    /// generator.
    public static func write(_ files: [GeneratedFile], to root: URL) throws {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw GeneratedFileError.unwritable(path: root.lastPathComponent, reason: SanitizedText(error.localizedDescription, limit: 120))
        }
        let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        let openError = errno
        guard rootDescriptor >= 0 else {
            throw GeneratedFileError.unwritable(path: root.lastPathComponent, reason: systemReason(openError))
        }
        defer { close(rootDescriptor) }
        for file in files {
            try write(file, under: rootDescriptor)
        }
        if !files.contains(where: { $0.relativePath == resolvedPackagesRelativePath }) {
            try removeStaleResolvedPackages(under: rootDescriptor)
        }
    }

    /// The components of a generated file's path, refused unless it is a plain relative path
    /// that stays inside the workspace and out of `repos/`.
    static func components(of relativePath: String) throws -> [String] {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw GeneratedFileError.invalidPath(relativePath) }
        // The guest volume matches names by Unicode case folding rather than by letter case, so
        // `repoſ` and `ｒｅｐｏｓ` would open the existing `repos`; fold the same way it does.
        guard components[0].folding(options: [.caseInsensitive, .widthInsensitive], locale: nil) != "repos" else {
            throw GeneratedFileError.pathOutsideWorkspace(relativePath)
        }
        return components
    }

    static func write(_ file: GeneratedFile, under rootDescriptor: Int32) throws {
        let components = try components(of: file.relativePath)
        var directory = rootDescriptor
        defer { if directory != rootDescriptor { close(directory) } }
        for name in components.dropLast() {
            guard let next = try openSubdirectory(name, in: directory, creating: true, path: file.relativePath) else {
                throw GeneratedFileError.unwritable(path: file.relativePath, reason: systemReason(ENOENT))
            }
            if directory != rootDescriptor { close(directory) }
            directory = next
        }
        try writeAtomically(file.contents, named: components[components.count - 1], in: directory, path: file.relativePath)
    }

    /// Opens one directory below `parent`, creating it first when the caller is about to write
    /// there. `nil` means it does not exist and none was created.
    static func openSubdirectory(_ name: String, in parent: Int32, creating: Bool, path: String) throws -> Int32? {
        if creating {
            let made = mkdirat(parent, name, 0o755)
            let code = errno
            guard made == 0 || code == EEXIST else {
                throw GeneratedFileError.unwritable(path: path, reason: systemReason(code))
            }
        }
        // `O_NOFOLLOW` refuses a component that is a link instead of resolving it, and the
        // descriptor keeps naming this directory even once the entry above it is replaced.
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let code = errno
        guard descriptor >= 0 else {
            if code == ENOENT { return nil }
            // `ELOOP` is a link; `ENOTDIR` is a file where a directory belongs.
            guard code != ELOOP, code != ENOTDIR else { throw GeneratedFileError.pathOutsideWorkspace(path) }
            throw GeneratedFileError.unwritable(path: path, reason: systemReason(code))
        }
        return descriptor
    }

    /// Creates the file inside `directory` and renames it into place, so a reader never sees a
    /// half-written file and the bytes can only land in this directory.
    static func writeAtomically(_ contents: Data, named name: String, in directory: Int32, path: String) throws {
        let temporary = ".guesthouse-\(UUID().uuidString)"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        let openError = errno
        guard descriptor >= 0 else { throw GeneratedFileError.unwritable(path: path, reason: systemReason(openError)) }
        var placed = false
        defer {
            close(descriptor)
            if !placed { unlinkat(directory, temporary, 0) }
        }
        var remaining = contents[...]
        while !remaining.isEmpty {
            let count = remaining.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            let code = errno
            guard count > 0 else {
                if count < 0, code == EINTR { continue }
                throw GeneratedFileError.unwritable(path: path, reason: systemReason(count < 0 ? code : EIO))
            }
            remaining = remaining.dropFirst(count)
        }
        // `renameat` replaces whatever the name holds without following it, so an entry an
        // agent turned into a link is replaced rather than written through.
        guard renameat(directory, temporary, directory, name) == 0 else {
            throw GeneratedFileError.unwritable(path: path, reason: systemReason(errno))
        }
        placed = true
    }

    /// Removes a resolution file an earlier generation seeded, through the same held
    /// descriptors, so a stale lockfile cannot outlive the app's own.
    static func removeStaleResolvedPackages(under rootDescriptor: Int32) throws {
        let path = resolvedPackagesRelativePath
        let components = try components(of: path)
        var directory = rootDescriptor
        defer { if directory != rootDescriptor { close(directory) } }
        for name in components.dropLast() {
            guard let next = try openSubdirectory(name, in: directory, creating: false, path: path) else { return }
            if directory != rootDescriptor { close(directory) }
            directory = next
        }
        // `unlinkat` removes the entry itself, never what a link points at.
        let removed = unlinkat(directory, components[components.count - 1], 0)
        let code = errno
        guard removed == 0 || code == ENOENT else {
            throw GeneratedFileError.unwritable(path: path, reason: systemReason(code))
        }
    }

    /// The system's own description of a POSIX failure. It names a condition, never a path.
    static func systemReason(_ code: Int32) -> SanitizedText {
        SanitizedText(NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription, limit: 120)
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
            text += "| \(cell(layout.repositoryPathFromRoot(repository))) | \(repository.role.rawValue) | \(repository.remote.canonical) | \(cell(repository.baseBranch.rawValue)) | \(cell(repository.taskBranch.rawValue)) |\n"
        }
        text += """

        ## Build and test

        Always build through the integration workspace, never through the app project alone. The workspace contains the app project and every package directory above, so the app resolves those packages from the local checkouts instead of the versions pinned in its `Package.resolved`:

        \(fenced("xcodebuild -workspace \(shellQuoted(WorkspaceLayout.integrationWorkspaceName)) -scheme \(shellQuoted(manifest.sharedScheme)) -destination \(shellQuoted(manifest.testDestination.specifier)) -derivedDataPath artifacts/DerivedData -clonedSourcePackagesDirPath artifacts/SourcePackages test", language: "bash"))

        Build state and downloaded package sources stay under `artifacts/` so a workspace can be cleaned or exported as a unit and nothing lands in Xcode's shared defaults.

        A green result here means the app builds against the sibling package changes in this workspace. It does not mean the app's own pull request will pass its CI, which builds against the published package versions. Both results matter.

        ## Local package mapping

        """
        if packages.isEmpty {
            text += "No package repositories are part of this workspace.\n"
        } else {
            for package in packages {
                text += "- \(code(layout.repositoryPathFromRoot(package))) overrides the dependency on \(package.remote.canonical) (package identity \(code(package.remote.name.lowercased()))).\n"
            }
        }
        if let app {
            text += "\nThe app project is \(code("\(layout.repositoryPathFromRoot(app))/\(manifest.appProjectPath)")) with shared scheme \(code(manifest.sharedScheme)).\n"
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

    /// One shell argument, quoted so repository-controlled text cannot end it: single quotes
    /// take everything literally, and an embedded quote is closed, escaped, and reopened.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A fenced block whose fence is longer than any backtick run inside it, so the content
    /// cannot end the block early.
    static func fenced(_ text: String, language: String) -> String {
        let longest = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\(language)\n\(text)\n\(fence)"
    }

    /// A Markdown code span that cannot be closed early by the value: repository-controlled
    /// text (a branch name, a project path) is wrapped in one more backtick than its longest
    /// run, the way CommonMark specifies.
    static func code(_ text: String) -> String {
        let longest = text.split(separator: "`", omittingEmptySubsequences: false).count > 1
            ? text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
            : 0
        let fence = String(repeating: "`", count: longest + 1)
        return "\(fence) \(text) \(fence)".replacingOccurrences(of: "\(fence) \(text) \(fence)", with: longest == 0 ? "`\(text)`" : "\(fence) \(text) \(fence)")
    }

    /// A table cell: a code span whose pipes are escaped so they cannot add columns.
    static func cell(_ text: String) -> String {
        code(text).replacingOccurrences(of: "|", with: "\\|")
    }

    // MARK: - workspace.json

    /// The manifest is written and read with `Date`'s own representation (seconds since the
    /// reference date), which round-trips exactly; `decodeManifest` is the matching reader.
    static func encodedManifest(_ manifest: WorkspaceManifest) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        // A manifest that validated cannot fail to encode: every field is a plain value type
        // and validation refuses timestamps that are not finite. A failure here is a bug and
        // is reported as one rather than written as an empty file.
        do {
            return try encoder.encode(manifest)
        } catch {
            preconditionFailure("a validated manifest failed to encode: \(error)")
        }
    }

    /// Reads a `workspace.json` written by `generate`.
    /// Reads a workspace file the guest owns. Structural failures come back as
    /// `WorkspaceValidationError.malformed`, which carries a message and recovery actions.
    public static func decodeManifest(_ data: Data) throws(WorkspaceValidationError) -> WorkspaceManifest {
        try WorkspaceManifest.decode(data)
    }
}
