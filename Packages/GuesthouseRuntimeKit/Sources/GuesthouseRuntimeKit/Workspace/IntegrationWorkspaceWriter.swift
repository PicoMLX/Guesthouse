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

    /// The workspace directory itself, as a descriptor. Everything below it is written through
    /// this descriptor, so this is the one open that has to be right.
    ///
    /// The root is created and opened through its own parent, held as a descriptor: a check on
    /// the root's pathname resolves every component above it, so a link left where the folder
    /// that holds the workspaces belongs would have the root created inside whatever it points
    /// at, and both the check and the open would then agree about that substitute. Only the
    /// root's own component is held to that rule; the directories above it are the storage
    /// location the host chose, which legitimately reaches through links on macOS (`/var`, an
    /// external volume).
    ///
    /// The directory that was checked is then confirmed to be the directory that was opened.
    /// `O_NOFOLLOW` only refuses a link, so a root swapped for a different real directory
    /// between the check and the open would pass it, and every descriptor-relative write below
    /// would land in the substitute — a repository moved into the root's pathname, say. The
    /// volume and file the check saw are compared with the ones the descriptor names, which no
    /// later renaming of the path can change.
    ///
    /// A root created here is examined the same way rather than trusted because it was just
    /// made: the guest can replace it in the same window, and an identity nobody recorded is an
    /// identity nothing below can compare.
    ///
    /// The test seams run between the absence check and creation, and between the identity
    /// check and open, so substitutions can be exercised without racing the scheduler.
    static func openRoot(_ resolvedRoot: URL, beforeCreate: () throws -> Void = {}, afterCheck: () -> Void = {}) throws -> Int32 {
        let name = resolvedRoot.lastPathComponent
        let container = resolvedRoot.deletingLastPathComponent()
        var containerDescriptor = open(container.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var containerError = errno
        if containerDescriptor < 0, containerError == ENOENT {
            do {
                try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            } catch {
                throw GeneratedFileError.unwritable(path: name, reason: SanitizedText(error.localizedDescription, limit: 120))
            }
            containerDescriptor = open(container.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            containerError = errno
        }
        guard containerDescriptor >= 0 else {
            // A link, or a file where the container belongs, is an attempt to send every
            // generated file somewhere else, not an I/O failure.
            throw containerError == ELOOP || containerError == ENOTDIR
                ? GeneratedFileError.pathOutsideWorkspace(name)
                : GeneratedFileError.unwritable(path: name, reason: reason(containerError))
        }
        defer { close(containerDescriptor) }
        var rootInfo = stat()
        if fstatat(containerDescriptor, name, &rootInfo, AT_SYMLINK_NOFOLLOW) != 0 {
            let checkError = errno
            guard checkError == ENOENT else {
                throw GeneratedFileError.unwritable(path: name, reason: reason(checkError))
            }
            try beforeCreate()
            guard mkdirat(containerDescriptor, name, 0o755) == 0 else {
                let code = errno
                // Absence was observed above. An entry that arrived before creation belongs
                // to somebody else, even when it is a real directory with a stable identity.
                throw code == EEXIST
                    ? GeneratedFileError.pathOutsideWorkspace(name)
                    : GeneratedFileError.unwritable(path: name, reason: reason(code))
            }
            guard fstatat(containerDescriptor, name, &rootInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw GeneratedFileError.unwritable(path: name, reason: reason(errno))
            }
        }
        guard (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw GeneratedFileError.pathOutsideWorkspace(name)
        }
        let checked = (device: rootInfo.st_dev, inode: rootInfo.st_ino)
        afterCheck()
        let descriptor = openat(containerDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            throw code == ELOOP
                ? GeneratedFileError.pathOutsideWorkspace(name)
                : GeneratedFileError.unwritable(path: name, reason: reason(code))
        }
        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0 else {
            let code = errno
            close(descriptor)
            throw GeneratedFileError.unwritable(path: name, reason: reason(code))
        }
        if checked.device != openedInfo.st_dev || checked.inode != openedInfo.st_ino {
            close(descriptor)
            throw GeneratedFileError.pathOutsideWorkspace(name)
        }
        return descriptor
    }

    /// The relative path as components, refusing anything that is not a plain relative path
    /// inside the area the workspace owns.
    ///
    /// A component carrying an embedded NUL is refused before any of it reaches C: `openat`
    /// and the calls beside it stop at that byte, so `repos\0suffix` would compare unequal to
    /// `repos` in every check here and still open `repos` itself.
    static func components(of relativePath: String) throws -> [String] {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.unicodeScalars.contains("\0") })
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

    /// A directory on the way to something that simply is not there. Only a caller looking for
    /// an entry to remove treats this as success; every other failure is reported.
    struct DirectoryAbsent: Error {}

    static func openDirectory(_ name: String, in parent: Int32, creating: Bool, of relativePath: String) throws -> Int32 {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT, creating {
            return try createDirectory(name, in: parent, of: relativePath)
        }
        guard descriptor >= 0 else {
            let code = errno
            // Absence is only ever benign where the caller was looking for something to
            // remove; it is told apart from every other failure so nothing else is mistaken
            // for it. `creating` has already tried to make the directory, so absence there is
            // a real failure.
            if code == ENOENT, !creating { throw DirectoryAbsent() }
            // A link, or a file where a directory belongs, is an attempt to send the write
            // somewhere else, not an I/O failure.
            throw code == ELOOP || code == ENOTDIR
                ? GeneratedFileError.pathOutsideWorkspace(relativePath)
                : GeneratedFileError.unwritable(path: relativePath, reason: reason(code))
        }
        return descriptor
    }

    /// Creates a directory the write needs and returns a descriptor bound to the inode this
    /// call made, not to whatever the name resolves to afterwards.
    ///
    /// `mkdirat` hands back no descriptor, so creating under the final name and opening that
    /// name again leaves the guest a window to rename the new directory away and move a
    /// checkout into its place; `O_NOFOLLOW` accepts that substitute, because it is a real
    /// directory, and every descriptor-relative write below would then land in the checkout
    /// (MVP-PLAN.md §3, the workspace is shared with an untrusted guest that changes it while
    /// this runs). The directory is therefore made under a name nothing else can predict,
    /// opened through that name, and only then moved into place, so what the write goes
    /// through is what Guesthouse created.
    ///
    /// The name was absent a moment earlier, so a rename that cannot complete means something
    /// arrived in that window: a directory holding files, or an entry that is not a directory
    /// at all. That is refused rather than written into.
    ///
    /// `afterCreate` is a test seam: it runs in exactly the window a substitution has to land
    /// in, so the rule can be exercised rather than raced.
    static func createDirectory(_ name: String, in parent: Int32, of relativePath: String, afterCreate: () -> Void = {}) throws -> Int32 {
        let temporary = ".\(name).\(UUID().uuidString)"
        guard mkdirat(parent, temporary, 0o755) == 0 else {
            throw GeneratedFileError.unwritable(path: relativePath, reason: reason(errno))
        }
        let descriptor = openat(parent, temporary, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            unlinkat(parent, temporary, AT_REMOVEDIR)
            throw GeneratedFileError.unwritable(path: relativePath, reason: reason(code))
        }
        afterCreate()
        guard renameat(parent, temporary, parent, name) == 0 else {
            let code = errno
            close(descriptor)
            unlinkat(parent, temporary, AT_REMOVEDIR)
            // `EEXIST` and `ENOTEMPTY` both say another directory is now standing where this
            // one belongs, and `ENOTDIR` that the entry is not a directory at all; none of
            // them is an I/O failure, and none of them is the directory this call made.
            throw code == EEXIST || code == ENOTEMPTY || code == ENOTDIR
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
    ///
    /// Only a directory that is genuinely absent is passed over. Anything else — a component
    /// the service may not traverse, descriptors exhausted, a link where a directory belongs —
    /// is reported, because reporting success while the old resolution file survives would
    /// leave it pinning dependencies this generation deliberately dropped.
    static func removeStale(_ relativePath: String, in root: Int32) throws {
        let components = try components(of: relativePath)
        let parent: Int32
        do {
            parent = try openParent(components, in: root, creating: false, of: relativePath)
        } catch is DirectoryAbsent {
            return
        }
        defer { close(parent) }
        let name = components[components.count - 1]
        guard unlinkat(parent, name, 0) != 0 else { return }
        guard errno != ENOENT else { return }
        // A directory the guest left where the file belongs is removed only when it is empty:
        // Guesthouse never deletes a tree it did not create. The reason reported is this
        // call's own, not the one from the attempt above: a non-empty directory fails here
        // with `ENOTEMPTY`, which is what explains why regeneration cannot clear the entry.
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
            throw GeneratedFileError.unwritable(path: relativePath, reason: reason(errno))
        }
    }

    /// The system's own words for a failure, sanitized like any other text from outside.
    static func reason(_ code: Int32) -> SanitizedText {
        SanitizedText(NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription, limit: 120)
    }
}
