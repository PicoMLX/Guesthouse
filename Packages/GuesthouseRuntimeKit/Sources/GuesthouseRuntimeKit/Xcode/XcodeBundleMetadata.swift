import Darwin
import Foundation
import GuesthouseCore

/// Descriptor-relative metadata validation adapted from retained #74 (#26, MVP §3).
/// The caller owns the authenticated selection grant. No path lookup, bookmark resolution,
/// process launch, signature assertion or copying occurs here. Run on the bounded I/O worker.
enum XcodeBundleMetadata {
    static let maximumMetadataBytes = 4 << 20

    static func candidate(borrowing bundle: Int32) throws(XcodeSelectionFailure) -> XcodeCandidate {
        var info = stat()
        guard fstat(bundle, &info) == 0 else { throw .unavailable }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw .notAnApplication }
        guard let metadata = try plist(["Contents", "Info.plist"], in: bundle),
              metadata["CFBundlePackageType"] as? String == "APPL" else { throw .notAnApplication }
        guard metadata["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode" else { throw .notXcode }
        guard let text = metadata["CFBundleShortVersionString"] as? String, let version = SemanticVersion(text) else {
            throw .metadataUnreadable
        }
        let versions = try plist(["Contents", "version.plist"], in: bundle)
        // An explicitly malformed build cannot be hidden by a fallback from another file.
        let reportedBuild = versions?["ProductBuildVersion"] ?? metadata["DTXcodeBuild"]
        guard let build = reportedBuild as? String,
              let candidate = XcodeCandidate(version: version, build: build) else { throw .metadataUnreadable }
        guard let executable = metadata["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable.utf8.count <= 255, executable != ".", executable != "..",
              !executable.contains("/"), !executable.utf8.contains(0),
              let program = try openFile(["Contents", "MacOS", executable], in: bundle) else { throw .notAnApplication }
        defer { close(program) }
        guard fstat(program, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0 else { throw .notAnApplication }
        return candidate
    }

    private static func plist(_ components: [String], in bundle: Int32) throws(XcodeSelectionFailure) -> [String: Any]? {
        guard let descriptor = try openFile(components, in: bundle) else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumMetadataBytes else { throw .metadataUnreadable }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = read(descriptor, &bytes, bytes.count)
            if count > 0 {
                guard count <= maximumMetadataBytes - data.count else { throw .metadataUnreadable }
                data.append(contentsOf: bytes.prefix(count))
            } else if count == 0 { break }
            else if errno != EINTR { throw .metadataUnreadable }
        }
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw .metadataUnreadable
        }
        return object
    }

    /// Fixed components except the separately validated executable leaf. Never follows an
    /// ancestor or leaf link, and nonblocking open allows a FIFO/device to be refused by type.
    private static func openFile(_ components: [String], in bundle: Int32) throws(XcodeSelectionFailure) -> Int32? {
        var directory = fcntl(bundle, F_DUPFD_CLOEXEC, 0)
        guard directory >= 0 else { throw .unavailable }
        defer { close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                if errno == ENOENT { return nil }
                throw .metadataUnreadable
            }
            close(directory)
            directory = next
        }
        guard let leaf = components.last else { throw .metadataUnreadable }
        let descriptor = openat(directory, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw .metadataUnreadable
        }
        return descriptor
    }
}
