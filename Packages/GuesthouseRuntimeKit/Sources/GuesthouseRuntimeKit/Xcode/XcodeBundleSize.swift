import Darwin
import Foundation
import GuesthouseCore

/// Bounded allocated-file estimate adapted from retained #74 (#26, MVP §§2–3).
/// Links are counted toward the work budget but their targets are never followed. This is
/// a planning estimate, not required copy space or proof of a complete/unchanging bundle.
enum XcodeBundleSize {
    struct Limits: Sendable {
        var entries = 400_000
        var depth = 64
    }
    private struct Measurement { var entries = 0; var bytes: UInt64 = 0 }

    static func measure(borrowing bundle: Int32, limits: Limits = Limits(),
                        isCanceled: @Sendable () -> Bool = { Task.isCancelled }) -> UInt64? {
        guard limits.entries > 0, limits.entries <= 400_000, limits.depth >= 0, limits.depth <= 64,
              !isCanceled() else { return nil }
        // A new open description, not dup: fdopendir/readdir must not advance the caller's
        // directory offset or cause a repeated measurement to report an empty tree.
        let root = openat(bundle, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { return nil }
        var result = Measurement()
        guard walk(root, depth: 0, limits: limits, isCanceled: isCanceled, result: &result) else { return nil }
        return result.bytes
    }

    /// Consumes the directory even on failure. Any incomplete walk yields unknown, not a sum.
    private static func walk(_ directory: Int32, depth: Int, limits: Limits,
                             isCanceled: @Sendable () -> Bool, result: inout Measurement) -> Bool {
        guard let listing = fdopendir(directory) else { close(directory); return false }
        defer { closedir(listing) }
        while true {
            if isCanceled() { return false }
            errno = 0
            guard let entry = readdir(listing) else { return errno == 0 }
            guard let name = withUnsafeBytes(of: entry.pointee.d_name, { raw in
                String(validatingCString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }) else { return false }
            if name == "." || name == ".." { continue }
            result.entries += 1
            guard result.entries <= limits.entries else { return false }
            var info = stat()
            guard fstatat(dirfd(listing), name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard depth < limits.depth else { return false }
                let child = openat(dirfd(listing), name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { return false }
                guard walk(child, depth: depth + 1, limits: limits, isCanceled: isCanceled, result: &result) else { return false }
            case S_IFREG:
                guard let sum = adding(blocks: info.st_blocks, to: result.bytes) else { return false }
                result.bytes = sum
            case S_IFLNK: continue
            default: return false // A socket, device or FIFO is not measured application data.
            }
        }
    }

    static func adding(blocks: Int64, to total: UInt64) -> UInt64? {
        guard let count = UInt64(exactly: blocks) else { return nil }
        let (bytes, multiplied) = count.multipliedReportingOverflow(by: 512)
        let (sum, added) = total.addingReportingOverflow(bytes)
        return multiplied || added ? nil : sum
    }
}

/// Read-only composition. The same borrowed selection descriptor supplies metadata and size.
/// Import must revalidate its own grant and storage capacity; this result does not authorize it.
enum XcodeBundleInspection {
    static func candidate(borrowing bundle: Int32) throws(XcodeSelectionFailure) -> XcodeCandidate {
        let metadata = try XcodeBundleMetadata.candidate(borrowing: bundle)
        guard let candidate = XcodeCandidate(version: metadata.version, build: metadata.build,
            sizeEstimateBytes: XcodeBundleSize.measure(borrowing: bundle)) else { throw .metadataUnreadable }
        return candidate
    }
}
