import Darwin
import Foundation

/// Critical metadata/launch-path coherence from #86. The existing state-file version captures
/// nanosecond change/modification times; length also detects truncation. This is a point-in-time
/// observation, not signature verification or durable launch authority (MVP-PLAN.md §3).
struct LumeBundleFileIdentity: Hashable, Sendable {
    struct Item: Hashable, Sendable {
        let version: StateFileVersion
        let bytes: off_t
        let mode: mode_t
        let owner: uid_t
        init(_ info: stat) {
            version = StateFileVersion(info)
            bytes = info.st_size
            mode = info.st_mode
            owner = info.st_uid
        }
    }
    let bundle, contents, executables, infoPlist, executable: Item
}

/// Runtime-only, read-only discovery migrated from #83/#86. No installation or launch API.
/// Metadata and contents remain untrusted until the separate strict verifier succeeds.
struct LumeBundle: Hashable, Sendable {
    let url: URL
    private var contents: URL { url.appending(path: "Contents") }
    private var executables: URL { contents.appending(path: "MacOS") }
    var executable: URL { executables.appending(path: LumePin.executableName) }
    var infoPlist: URL { contents.appending(path: "Info.plist") }

    /// No critical path may be a link or have the wrong type/owner. Tracking the outer app
    /// alone misses same-inode writes and replacement below Contents. Full nested-code
    /// validation and serialized immediate pre-launch revalidation still belong to later work.
    var fileIdentity: LumeBundleFileIdentity? {
        guard let bundle = Self.item(url, kind: S_IFDIR),
              let contents = Self.item(contents, kind: S_IFDIR),
              let executables = Self.item(executables, kind: S_IFDIR),
              let infoPlist = Self.item(infoPlist, kind: S_IFREG),
              let executable = Self.item(executable, kind: S_IFREG) else { return nil }
        return LumeBundleFileIdentity(bundle: bundle, contents: contents, executables: executables,
                                      infoPlist: infoPlist, executable: executable)
    }

    static func expectedLocation(in storage: RuntimeStorage) throws -> URL {
        try storage.location(for: .runtime).appending(path: LumePin.releaseTag).appending(path: LumePin.bundleName)
    }

    /// Only actual absence is nil. Existing unsafe/protection-drifted storage remains a closed
    /// StorageFailure, never "missing runtime" repair guidance. Discovery never repairs it.
    static func locate(in storage: RuntimeStorage) throws -> LumeBundle? {
        let url = try expectedLocation(in: storage), release = url.deletingLastPathComponent()
        guard try directoryExists(release) else {
            _ = try storage.location(for: .runtime)
            return nil
        }
        try StorageProtection.verify(release)
        let found = try directoryExists(url)
        _ = try storage.location(for: .runtime)
        try StorageProtection.verify(release)
        return found ? LumeBundle(url: url) : nil
    }

    private static func directoryExists(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(try StorageProtection.path(url), &info) == 0 else {
            if errno == ENOENT { return false }
            throw StorageFailure.inspectionFailed
        }
        _ = try StorageProtection.structure(url)
        return true
    }

    private static func item(_ url: URL, kind: mode_t) -> LumeBundleFileIdentity.Item? {
        guard let path = try? StorageProtection.path(url) else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == kind, info.st_uid == getuid() else { return nil }
        return LumeBundleFileIdentity.Item(info)
    }
}
