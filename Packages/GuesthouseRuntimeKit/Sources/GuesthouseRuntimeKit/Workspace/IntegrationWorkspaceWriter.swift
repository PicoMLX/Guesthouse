import Darwin
import Foundation
import GuesthouseCore

/// Writes the files `IntegrationWorkspaceGenerator` produced into a workspace directory.
/// The description of what to write is built in GuesthouseCore, which performs no host
/// mutations; this is the host-side half, linked only by the runtime service.
///
/// The workspace is shared with the guest, whose file system is untrusted and changes while
/// this runs (MVP-PLAN.md §3). A directory checked by path can therefore be a link by the
/// time it is written through, so the root is opened once and every step below it is relative
/// to a directory descriptor and never follows a link: what was checked is what is written
/// into, whatever the guest does to the names in between.
public enum IntegrationWorkspaceWriter {
    public static func write(_ files: [GeneratedFile], to root: URL) throws {
        let resolvedRoot = root.standardizedFileURL
        let rootDescriptor = try openRoot(resolvedRoot)
        defer { close(rootDescriptor) }
        for file in files {
            let components = try components(of: file.relativePath)
            let parent = try openParent(components, in: rootDescriptor, creating: true, of: file.relativePath)
            defer { close(parent) }
            try writeFile(file.contents, named: components[components.count - 1], in: parent, of: file.relativePath)
        }
        if !files.contains(where: { $0.relativePath == IntegrationWorkspaceGenerator.resolvedPackagesRelativePath }) {
            try removeStale(IntegrationWorkspaceGenerator.resolvedPackagesRelativePath, in: rootDescriptor)
        }
    }

    /// The workspace directory itself, as a descriptor. It is opened without following links:
    /// a root replaced by a link to a checkout would otherwise redirect every write into it.
    /// A root that does not exist yet is created here, so what follows always writes into a
    /// directory.
    static func openRoot(_ resolvedRoot: URL) throws -> Int32 {
        var rootInfo = stat()
        if lstat(resolvedRoot.path, &rootInfo) == 0 {
            guard (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
                throw GeneratedFileError.pathOutsideWorkspace(resolvedRoot.lastPathComponent)
            }
        } else {
            do {
                try FileManager.default.createDirectory(at: resolvedRoot, withIntermediateDirectories: true)
            } catch {
                throw GeneratedFileError.unwritable(path: resolvedRoot.lastPathComponent, reason: SanitizedText(error.localizedDescription, limit: 120))
            }
        }
        let descriptor = open(resolvedRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            throw code == ELOOP
                ? GeneratedFileError.pathOutsideWorkspace(resolvedRoot.lastPathComponent)
                : GeneratedFileError.unwritable(path: resolvedRoot.lastPathComponent, reason: reason(code))
        }
        return descriptor
    }

    /// The relative path as components, refusing anything that is not a plain relative path
    /// inside the area the workspace owns.
    static func components(of relativePath: String) throws -> [String] {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw GeneratedFileError.invalidPath(relativePath) }
        // Case folding, not `lowercased()`: on a case-insensitive volume `repoſ` and `REPOS`
        // name the same directory as `repos`, and only folding treats them as equal.
        guard components[0].folding(options: [.caseInsensitive, .widthInsensitive], locale: nil) != "repos" else {
            throw GeneratedFileError.pathOutsideWorkspace(relativePath)
        }
        return components
    }

    /// The directory that will hold the file, walked one component at a time from `root`. The
    /// caller owns the returned descriptor.
    static func openParent(_ components: [String], in root: Int32, creating: Bool, of relativePath: String) throws -> Int32 {
        var current = dup(root)
        guard current >= 0 else {
            throw GeneratedFileError.unwritable(path: relativePath, reason: reason(errno))
        }
        for component in components.dropLast() {
            do {
                let next = try openDirectory(component, in: current, creating: creating, of: relativePath)
                close(current)
                current = next
            } catch {
                close(current)
                throw error
            }
        }
        return current
    }

    static func openDirectory(_ name: String, in parent: Int32, creating: Bool, of relativePath: String) throws -> Int32 {
        var descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT, creating {
            let created = mkdirat(parent, name, 0o755)
            guard created == 0 || errno == EEXIST else {
                throw GeneratedFileError.unwritable(path: relativePath, reason: reason(errno))
            }
            descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            let code = errno
            // A link, or a file where a directory belongs, is an attempt to send the write
            // somewhere else, not an I/O failure.
            throw code == ELOOP || code == ENOTDIR
                ? GeneratedFileError.pathOutsideWorkspace(relativePath)
                : GeneratedFileError.unwritable(path: relativePath, reason: reason(code))
        }
        return descriptor
    }

    static func writeFile(_ contents: Data, named name: String, in parent: Int32, of relativePath: String) throws {
        // The rename below would replace a link silently; refusing keeps the guest from
        // choosing what Guesthouse overwrites.
        var existing = stat()
        if fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) == 0, (existing.st_mode & S_IFMT) == S_IFLNK {
            throw GeneratedFileError.pathOutsideWorkspace(relativePath)
        }
        let temporary = ".\(name).\(UUID().uuidString)"
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw GeneratedFileError.unwritable(path: relativePath, reason: reason(errno))
        }
        do {
            try writeAll(contents, to: descriptor, of: relativePath)
        } catch {
            close(descriptor)
            unlinkat(parent, temporary, 0)
            throw error
        }
        close(descriptor)
        // Atomic, so a reader never sees half a file, and relative to the directory that was
        // opened, so the swap cannot be redirected.
        guard renameat(parent, temporary, parent, name) == 0 else {
            let code = errno
            unlinkat(parent, temporary, 0)
            throw GeneratedFileError.unwritable(path: relativePath, reason: reason(code))
        }
    }

    static func writeAll(_ contents: Data, to descriptor: Int32, of relativePath: String) throws {
        var offset = 0
        while offset < contents.count {
            let (written, code) = contents.withUnsafeBytes { buffer -> (Int, Int32) in
                let result = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                return (result, errno)
            }
            if written < 0 {
                guard code == EINTR else {
                    throw GeneratedFileError.unwritable(path: relativePath, reason: reason(code))
                }
                continue
            }
            offset += written
        }
    }

    /// Removes what an earlier generation left behind, creating nothing on the way.
    static func removeStale(_ relativePath: String, in root: Int32) throws {
        let components = try components(of: relativePath)
        guard let parent = try? openParent(components, in: root, creating: false, of: relativePath) else { return }
        defer { close(parent) }
        let name = components[components.count - 1]
        guard unlinkat(parent, name, 0) != 0 else { return }
        let code = errno
        guard code != ENOENT else { return }
        // A directory the guest left where the file belongs is removed only when it is empty:
        // Guesthouse never deletes a tree it did not create.
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
            throw GeneratedFileError.unwritable(path: relativePath, reason: reason(code))
        }
    }

    /// The system's own words for a failure, sanitized like any other text from outside.
    static func reason(_ code: Int32) -> SanitizedText {
        SanitizedText(NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription, limit: 120)
    }
}
