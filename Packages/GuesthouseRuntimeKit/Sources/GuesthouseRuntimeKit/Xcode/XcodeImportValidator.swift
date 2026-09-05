import Darwin
import Foundation
import GuesthouseCore

/// Turns a handed-off location into a validated `XcodeCandidate` without copying anything
/// (MVP-PLAN.md §2 step 5, §3 "Pass user-selected import/export access explicitly using
/// supported file-access handoff").
///
/// The handoff is the authority: a bookmark is resolved, never a bare path. The resolved
/// location is canonicalized, must be a directory bundle, must identify itself as Xcode, and
/// its version and build are read from `Info.plist` and `version.plist` without executing it.
public enum XcodeImportValidator {
    public static let xcodeBundleIdentifier = "com.apple.dt.Xcode"
    /// Entries enumerated for the size estimate before giving up and reporting `nil`.
    public static let sizeEstimateEntryLimit = 400_000
    /// How deep the size estimate descends. A real application bundle is nowhere near this
    /// deep; a crafted one could nest without end, and every level costs an open descriptor.
    public static let sizeEstimateDepthLimit = 64
    /// Larger metadata files are refused rather than loaded.
    public static let maximumMetadataBytes = 4 << 20

    /// Resolves the handoff to a location. Descriptors are received out of band by the
    /// service (gate #34 decides the transport); this validator accepts bookmarks now.
    /// A resolved handoff whose security scope, when the bookmark carries one, stays active
    /// until the value is released.
    public final class ResolvedLocation: Sendable {
        public let url: URL
        private let scoped: Bool

        init(url: URL, scoped: Bool) {
            self.url = url
            self.scoped = scoped
        }

        deinit {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    /// Whether a bookmark must carry a usable security scope. Production requires it: a
    /// bookmark that resolves without one is not a grant from the sandboxed app. Tests, which
    /// make plain bookmarks, turn it off through `resolve(_:requireSecurityScope:)`.
    public static func resolve(_ handoff: FileHandoff, requireSecurityScope: Bool = true) throws(GuesthouseError) -> ResolvedLocation {
        switch handoff.kind {
        case .securityScopedBookmark(let data):
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale), url.isFileURL,
               url.startAccessingSecurityScopedResource() {
                return ResolvedLocation(url: url, scoped: true)
            }
            guard !requireSecurityScope,
                  let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale), url.isFileURL
            else {
                throw .xcodeSelectionRejected(.unresolvable)
            }
            return ResolvedLocation(url: url, scoped: false)
        case .fileDescriptor:
            throw .invalidRequest(.unsupportedOperation)
        }
    }

    /// Validates the location as an Xcode bundle and describes it.
    public static func candidate(at location: URL, expectedBundleIdentifier: String? = nil) throws(GuesthouseError) -> XcodeCandidate {
        guard location.isFileURL, !location.pathComponents.contains(where: { $0 == ".." || $0.utf8.contains(0) }) else {
            throw .invalidRequest(.pathEscapesAllowedRoot)
        }
        let canonicalPath = try canonicalBundlePath(at: location)
        let resolved = URL(fileURLWithPath: canonicalPath)
        guard resolved.pathExtension == "app" else { throw .xcodeSelectionRejected(.notAnApplication) }

        // The bundle is opened once and every metadata read goes through that descriptor. A
        // bundle in a user-writable place can be renamed or replaced between two reads, and
        // reopening its path would let validation read one bundle while reporting another.
        let bundle = try openCanonicalBundle(at: canonicalPath)
        defer { close(bundle) }

        guard let info = try plist(["Contents", "Info.plist"], in: bundle) else { throw .xcodeSelectionRejected(.notAnApplication) }
        let identifier = info["CFBundleIdentifier"] as? String ?? ""
        guard identifier == xcodeBundleIdentifier, identifier == (expectedBundleIdentifier ?? identifier) else {
            throw .xcodeSelectionRejected(.notXcode)
        }
        // Missing host metadata is a selection problem on this Mac, never a guest tool problem.
        guard let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else { throw .xcodeSelectionRejected(.metadataUnreadable) }
        let versionPlist = try plist(["Contents", "version.plist"], in: bundle) ?? [:]
        guard let build = (versionPlist["ProductBuildVersion"] as? String) ?? (info["DTXcodeBuild"] as? String), !build.isEmpty else {
            throw .xcodeSelectionRejected(.metadataUnreadable)
        }
        // Metadata the redactor changes is not metadata: a version of "2\u{0A}6.6" would be
        // reported as "26.6", a value no bundle ever declared. Only text that survives
        // sanitization unaltered may be repeated back as what was found.
        let safeVersion = GuesthouseError.sanitize(version), safeBuild = GuesthouseError.sanitize(build)
        guard safeVersion == version, safeBuild == build, !safeVersion.isEmpty, !safeBuild.isEmpty else {
            throw .xcodeSelectionRejected(.metadataUnreadable)
        }
        // A directory that ends in `.app` and carries Xcode's metadata is still not an Xcode
        // that could run: a wrapper holding nothing but a crafted `Info.plist` and
        // `version.plist` would otherwise be reported as importable, and the failure would only
        // surface later, inside the guest, as a copy of something that has no program in it.
        guard let executable = info["CFBundleExecutable"] as? String, hasExecutable(named: executable, in: bundle) else {
            throw .xcodeSelectionRejected(.notAnApplication)
        }
        // Measured through the descriptor that pins the bundle, never by pathname: the tree can
        // be renamed away, another put in its place for the length of the walk and the original
        // moved back, which a check on the path afterwards cannot see.
        let measured = estimateSize(ofBundle: bundle)
        // That check is still made, because everything above describes the pinned bundle while
        // the candidate names a path, and the caller — the import that copies Xcode into the
        // guest — acts on the path. A path that has moved on to other content, or to nothing,
        // makes the pair describe something that never existed, so the selection is refused
        // and the user chooses again rather than importing from a location that changed under
        // the validation (MVP-PLAN.md §2 step 5).
        guard stillNames(bundle, at: resolved) else { throw .xcodeSelectionRejected(.unresolvable) }
        return XcodeCandidate(version: safeVersion, build: safeBuild, path: resolved.path, sizeEstimateBytes: measured)
    }

    /// Resolves existing aliases without Foundation's normalization of `/private/tmp` and
    /// `/private/var` back to the symlinked `/tmp` and `/var` spellings.
    static func canonicalBundlePath(at location: URL) throws(GuesthouseError) -> String {
        guard let path = realpath(location.path, nil) else { throw pathLookupError(errno) }
        defer { free(path) }
        return String(cString: path)
    }

    /// Opens an already-canonical path without following a symlink in any component. The
    /// kernel enforces this during the open, including an ancestor replaced after `realpath`.
    /// Unlike `O_NOFOLLOW`, `O_NOFOLLOW_ANY` also protects ancestors (MVP-PLAN.md §3).
    static func openCanonicalBundle(at path: String) throws(GuesthouseError) -> Int32 {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { throw pathLookupError(errno) }
        return descriptor
    }

    /// A missing or non-directory component has the wrong bundle shape. Access, I/O and
    /// symlink-resolution failures cannot establish that shape, so ask the user to choose again.
    static func pathLookupError(_ code: Int32) -> GuesthouseError {
        .xcodeSelectionRejected(code == ENOENT || code == ENOTDIR ? .notAnApplication : .unresolvable)
    }

    /// Whether `url` still names the very directory `descriptor` holds open.
    static func stillNames(_ descriptor: Int32, at url: URL) -> Bool {
        var pinned = stat()
        var named = stat()
        guard fstat(descriptor, &pinned) == 0, lstat(url.path, &named) == 0 else { return false }
        return pinned.st_dev == named.st_dev && pinned.st_ino == named.st_ino
    }

    /// Allocated bytes under the directory `descriptor` holds open, or `nil` when the estimate
    /// could not be made: a limit was reached, the scan was cancelled, or an entry could not be
    /// measured — a partial sum would present a definite estimate for a bundle nobody measured.
    ///
    /// The walk descends with `openat` from that descriptor and never follows a link, so it
    /// stays inside the bundle that was pinned whatever happens to the path meanwhile, and a
    /// link planted inside cannot make some enormous file elsewhere count as the bundle's.
    /// Every entry counts toward the limit, whatever it is, so a hostile tree cannot keep the
    /// runtime walking, and only `sizeEstimateDepthLimit` descriptors are ever open at once.
    public static func estimateSize(ofBundle descriptor: Int32) -> UInt64? {
        // Re-opened rather than duplicated: `fdopendir` takes ownership of what it is handed
        // and reads from that description's own offset, which a duplicate shares with the
        // caller's descriptor — a second measurement would start where the first one stopped.
        // Opening "." through the pinned descriptor names the same directory and nothing else.
        let root = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { return nil }
        var state = Measurement()
        guard measure(root, depth: 0, into: &state), !state.failed else { return nil }
        return state.total
    }

    /// What one walk has counted so far. `failed` marks an entry that could not be measured;
    /// the walk finishes anyway, so a bundle is never half-measured and then reported.
    private struct Measurement {
        var total: UInt64 = 0
        var entries = 0
        var failed = false
    }

    /// Counts one directory and everything under it. Consumes `directory`. Returns false when
    /// the walk was abandoned — the entry or depth limit, or a cancelled scan — which is not a
    /// size at all rather than a small one.
    private static func measure(_ directory: Int32, depth: Int, into state: inout Measurement) -> Bool {
        guard let listing = fdopendir(directory) else {
            close(directory)
            state.failed = true
            return true
        }
        defer { closedir(listing) }
        while true {
            // `readdir` answers `nil` for the end of the directory and for a failure alike —
            // an `EIO` from a file provider partway through a listing looks exactly like the
            // last entry. Only `errno`, cleared before each call, tells them apart, and a
            // listing that stopped early would otherwise be summed into a definite estimate
            // for a bundle nobody finished measuring.
            errno = 0
            guard let entry = readdir(listing) else {
                if errno != 0 { state.failed = true }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            guard name != ".", name != ".." else { continue }
            // The scan reads an untrusted tree on someone's behalf. Once nobody is waiting for
            // the answer — the session ended, the request was cancelled — it stops.
            if Task.isCancelled { return false }
            state.entries += 1
            guard state.entries <= sizeEstimateEntryLimit else { return false }
            var info = stat()
            guard fstatat(dirfd(listing), name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                state.failed = true
                continue
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard depth < sizeEstimateDepthLimit else { return false }
                let child = openat(dirfd(listing), name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else {
                    state.failed = true
                    continue
                }
                guard measure(child, depth: depth + 1, into: &state) else { return false }
            case S_IFREG:
                // `st_blocks` is what the file occupies, in 512-byte units, which is the same
                // allocated size the volume reports for a local file.
                let (bytes, overflowed) = info.st_blocks.multipliedReportingOverflow(by: 512)
                guard !overflowed, let sum = accumulate(Int(exactly: bytes), into: state.total) else {
                    state.failed = true
                    continue
                }
                state.total = sum
            default:
                // Links, devices and sockets hold no bundle bytes of their own, and a link's
                // target is either counted where it really lives or lies outside the bundle.
                continue
            }
        }
        return true
    }

    /// The running total after one regular file, or `nil` when the estimate cannot be made.
    ///
    /// A missing allocated size is not zero bytes — some volumes and file providers simply do
    /// not report one — and a sum that no longer fits is not a size either: a bundle full of
    /// hard links to one enormous file counts that file's allocation once per link, which can
    /// pass `UInt64` and would otherwise trap inside the service.
    static func accumulate(_ allocated: Int?, into total: UInt64) -> UInt64? {
        guard let allocated, allocated >= 0 else { return nil }
        let (sum, overflowed) = total.addingReportingOverflow(UInt64(allocated))
        return overflowed ? nil : sum
    }

    /// Reads one metadata file inside the bundle. It is read only if it is a regular file of
    /// bounded size, and only through the descriptor walk below, so a `Contents` link planted
    /// elsewhere can never let a wrapper folder pass as Xcode. Returns nil when nothing is
    /// there, which is a bundle-shape problem rather than unreadable metadata.
    static func plist(_ components: [String], in bundle: Int32) throws(GuesthouseError) -> [String: Any]? {
        guard let descriptor = try openFile(components, in: bundle) else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw .xcodeSelectionRejected(.metadataUnreadable) }
        guard info.st_size <= maximumMetadataBytes else { throw .xcodeSelectionRejected(.metadataUnreadable) }
        guard let data = readMetadata(descriptor),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw .xcodeSelectionRejected(.metadataUnreadable) }
        return object
    }

    /// Whether the bundle holds the program it declares: `Contents/MacOS/<CFBundleExecutable>`
    /// as a regular file with an execute bit, read through the pinned descriptor.
    ///
    /// A name is a single component and never a path: `CFBundleExecutable` comes out of a
    /// property list the user's selection supplied, and one carrying separators would otherwise
    /// walk somewhere `Contents/MacOS` does not lead. A NUL would truncate the name at the
    /// C path boundary, selecting a different executable from the one the bundle declared.
    static func hasExecutable(named name: String, in bundle: Int32) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { return false }
        guard let descriptor = try? openFile(["Contents", "MacOS", name], in: bundle) else { return false }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0
    }

    /// Opens one file inside the bundle, or `nil` when nothing is there. The caller closes it.
    ///
    /// The walk goes down from the bundle directory one component at a time and never follows a
    /// link. `O_NOFOLLOW` on the final component alone is not enough: an ancestor such as
    /// `Contents` can be replaced after the containment check, and an absolute-path open would
    /// follow it straight out of the bundle.
    static func openFile(_ components: [String], in bundle: Int32) throws(GuesthouseError) -> Int32? {
        // A duplicate, so descending can close each level while the caller keeps the one
        // descriptor that pins the bundle for the whole validation.
        var directory = dup(bundle)
        guard directory >= 0 else { throw .xcodeSelectionRejected(.metadataUnreadable) }
        defer { close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                // Absent is a bundle-shape problem. Anything else here means the component
                // exists but is a link or not a directory, which is metadata this validator
                // refuses to read rather than follow.
                if errno == ENOENT { return nil }
                throw .xcodeSelectionRejected(.metadataUnreadable)
            }
            close(directory)
            directory = next
        }
        guard let leaf = components.last else { throw .xcodeSelectionRejected(.metadataUnreadable) }
        // `O_NONBLOCK`, so a named pipe left where the metadata belongs is refused by the type
        // check below instead of holding the open — and the request, and its session slot —
        // until some writer that may never come connects.
        let descriptor = openat(directory, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            // Nothing there at all says the bundle has the wrong shape; a file that exists but
            // will not open (a link, a permissions problem) is metadata that cannot be read,
            // and the two failures need different advice.
            if errno == ENOENT { return nil }
            throw .xcodeSelectionRejected(.metadataUnreadable)
        }
        return descriptor
    }

    /// At most `maximumMetadataBytes`; `nil` for anything longer or unreadable.
    ///
    /// The size taken from `fstat` is a snapshot. A metadata file inside a user-writable bundle
    /// can grow after it, or be appended to for as long as anyone reads, so the read carries
    /// its own limit rather than trusting the size it was told.
    static func readMetadata(_ descriptor: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if data.count > maximumMetadataBytes { return nil }
            } else if count == 0 {
                return data
            } else if errno != EINTR {
                return nil
            }
        }
    }
}
