import Darwin
import Foundation
import GuesthouseCore

/// Writes the files `IntegrationWorkspaceGenerator` produced into a workspace directory.
/// The description of what to write is built in GuesthouseCore, which performs no host
/// mutations; this is the host-side half, linked only by the runtime service.
public enum IntegrationWorkspaceWriter {
    public static func write(_ files: [GeneratedFile], to root: URL) throws {
        let resolvedRoot = root.standardizedFileURL
        for file in files {
            let url = try destination(for: file.relativePath, in: resolvedRoot)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.contents.write(to: url, options: .atomic)
            } catch {
                throw GeneratedFileError.unwritable(path: file.relativePath, reason: SanitizedText(error.localizedDescription, limit: 120))
            }
        }
        if !files.contains(where: { $0.relativePath == IntegrationWorkspaceGenerator.resolvedPackagesRelativePath }) {
            let stale = try destination(for: IntegrationWorkspaceGenerator.resolvedPackagesRelativePath, in: resolvedRoot)
            if FileManager.default.fileExists(atPath: stale.path) {
                do {
                    try FileManager.default.removeItem(at: stale)
                } catch {
                    throw GeneratedFileError.unwritable(path: IntegrationWorkspaceGenerator.resolvedPackagesRelativePath, reason: SanitizedText(error.localizedDescription, limit: 120))
                }
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
        for component in components {
            url.append(path: component)
            // The guest's file system is untrusted: an agent that replaced a generated
            // directory with a link must not redirect the write through it.
            var info = stat()
            if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                throw GeneratedFileError.pathOutsideWorkspace(relativePath)
            }
        }
        guard url.standardizedFileURL.path.hasPrefix(resolvedRoot.path + "/") else {
            throw GeneratedFileError.pathOutsideWorkspace(relativePath)
        }
        return url
    }

}
