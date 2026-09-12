import Darwin
import Foundation
import GuesthouseCore

/// Runtime-internal preflight only. The service must retain the selected volume identity
/// separately and supply it on EVERY refresh, not recapture identity from the current path.
/// Selection/persistence, authenticated query and private-layout admission are not activated.
/// All checks are point-in-time; a report is neither a capacity reservation nor write authority.
struct SystemStorageProbe: Sendable {
    let storageRoot: URL?
    let expectedVolume: UUID?

    func observe() -> HostDiskObservation {
        guard let storageRoot, let expectedVolume else { return .unavailable(.storageRootUnknown) }
        do {
            return try Self.withDirectory(at: storageRoot, allowMissingSuffix: true) { descriptor in
                let value = try StorageVolumeProbe.snapshot(descriptor: descriptor)
                guard value.identity == expectedVolume else { throw HostProbeError.volumeIdentityChanged }
                try Self.requireWritable(faccessat(descriptor, ".", W_OK | X_OK, AT_EACCESS))
                return .available(bytes: value.availableBytes)
            }
        } catch let error as HostProbeError { return .unavailable(error) }
        catch { return .unavailable(.volumeUnavailable) }
    }

    /// Initial selection may identify an EXISTING service-chosen directory (for example,
    /// its home-volume anchor). Never infer a missing external volume's identity by ascending.
    /// The result is runtime-private selection metadata, not a GUI-requested replacement ID.
    static func identifyVolume(atExistingDirectory url: URL) throws -> UUID {
        try withDirectory(at: url, allowMissingSuffix: false) {
            try StorageVolumeProbe.snapshot(descriptor: $0).identity
        }
    }

    /// Every failure, including EPERM, blocks. The old sandboxed-GUI permission bypass
    /// is invalid here: these checks run in the process that will actually use storage.
    static func requireWritable(_ result: Int32) throws(HostProbeError) {
        guard result == 0 else { throw .destinationNotWritable }
    }

    // Internal closure seam permits deterministic namespace-drift tests on isolated fixtures.
    static func withDirectory<T>(
        at url: URL, allowMissingSuffix: Bool, body: (Int32) throws -> T
    ) throws -> T {
        let name: String
        do { name = try StorageProtection.path(url) }
        catch { throw HostProbeError.storageRootUnknown }
        var candidate = name
        var lastMissing: String?
        var inspected = stat()
        while lstat(candidate, &inspected) != 0 {
            let failure = errno
            guard failure == ENOENT, allowMissingSuffix, candidate != "/" else {
                throw inspectionFailure(failure)
            }
            lastMissing = candidate
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        // Final links (including dangling ones) are never replaced with an ancestor answer.
        guard inspected.st_mode & S_IFMT != S_IFLNK else { throw HostProbeError.volumeUnavailable }
        guard inspected.st_mode & S_IFMT == S_IFDIR else { throw HostProbeError.notADirectory }
        let descriptor = open(candidate, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw inspectionFailure(errno) }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, sameDirectory(inspected, opened) else {
            throw HostProbeError.volumeUnavailable
        }
        let result = try body(descriptor)
        var current = stat()
        guard lstat(candidate, &current) == 0, sameDirectory(opened, current) else {
            throw HostProbeError.volumeUnavailable
        }
        if let lastMissing {
            // A new suffix component could redirect the destination while we inspected its
            // ancestor. Refuse that changed binding; do not measure or create a replacement.
            guard lstat(lastMissing, &current) != 0, errno == ENOENT else {
                throw HostProbeError.volumeUnavailable
            }
        }
        return result
    }

    private static func sameDirectory(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && b.st_mode & S_IFMT == S_IFDIR
    }

    static func inspectionFailure(_ error: Int32) -> HostProbeError {
        switch error {
        case EACCES, EPERM, EROFS: .destinationNotWritable
        case ENOTDIR: .notADirectory
        default: .volumeUnavailable
        }
    }
}
