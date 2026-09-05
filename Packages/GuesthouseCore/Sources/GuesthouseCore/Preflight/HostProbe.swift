import Darwin
import AppKit
import Foundation
import IOKit.ps

public enum CPUArchitecture: String, Codable, Hashable, Sendable {
    case appleSilicon
    case intel
    case unknown
}

public enum PowerSource: String, Codable, Hashable, Sendable {
    case externalPower
    case battery
    case unknown
}

public struct InstalledApplication: Codable, Hashable, Sendable {
    public var url: URL
    public var version: String?
    public var build: String?

    public init(url: URL, version: String?, build: String?) {
        self.url = url
        self.version = version
        self.build = build
    }
}

/// Everything the preflight needs to know about this Mac, behind a protocol so checks can be
/// tested with a stub (MVP-PLAN.md §2, step 1).
public protocol HostProbe: Sendable {
    var cpuArchitecture: CPUArchitecture { get }
    var operatingSystemVersion: SemanticVersion { get }
    var operatingSystemBuild: String? { get }
    var physicalMemoryBytes: UInt64 { get }
    var powerSource: PowerSource { get }
    /// Free space usable for important data on the volume containing `url`.
    func freeBytes(at url: URL) throws -> UInt64
    func installedApplication(bundleIdentifier: String) -> InstalledApplication?
}

/// The real thing. Not unit-tested beyond a smoke test; every decision that matters is made
/// by `PreflightCheck` from values that tests supply through a stub.
public struct SystemHostProbe: HostProbe {
    /// Where macOS mounts volumes other than the startup volume.
    static let mountContainerPath = "/Volumes"

    /// Whether `url` is that directory, compared by filesystem identity rather than by
    /// spelling: on a case-insensitive volume `/volumes` names the same directory.
    static func isMountContainer(_ url: URL, container: String = mountContainerPath) -> Bool {
        var candidate = stat(), holder = stat()
        guard stat(url.path, &candidate) == 0, stat(container, &holder) == 0 else { return false }
        return candidate.st_dev == holder.st_dev && candidate.st_ino == holder.st_ino
    }

    /// The folder on `url`'s path where a volume mounts, `/Volumes/External` for
    /// `/Volumes/External/Guesthouse`, or `nil` for a path that names no mount point.
    ///
    /// A mount point is always one component below the folder that holds them, so the walk
    /// is a fixed depth rather than a climb to the root: `deletingLastPathComponent` answers
    /// `/..` for the root and would never end.
    static func volumeMountPoint(of url: URL, container: String = mountContainerPath) -> URL? {
        let depth = URL(fileURLWithPath: container).standardizedFileURL.pathComponents.count
        var candidate = url.standardizedFileURL
        guard candidate.pathComponents.count > depth else { return nil }
        while candidate.pathComponents.count > depth + 1 {
            candidate = candidate.deletingLastPathComponent()
        }
        guard isMountContainer(candidate.deletingLastPathComponent(), container: container) else { return nil }
        return candidate
    }

    /// Whether that mount point is a leftover folder rather than a mounted volume: a real
    /// directory on the same filesystem as the folder that holds mount points is where a
    /// volume *would* mount, so its capacity is the startup disk's and not the selected
    /// volume's. A link is left alone; it names a location that resolves on its own.
    static func isUnmountedVolumePoint(_ url: URL, container: String = mountContainerPath) -> Bool {
        var point = stat(), holder = stat()
        guard lstat(url.path, &point) == 0, (point.st_mode & S_IFMT) == S_IFDIR else { return false }
        guard stat(container, &holder) == 0 else { return false }
        return point.st_dev == holder.st_dev
    }

    /// Whether a failed `access` check rules the destination out.
    ///
    /// `access` answers for the calling process. The sandboxed app is refused with `EPERM`
    /// for a folder the runtime service — the process that actually creates the VM — can
    /// write, so that denial says nothing about the destination. A filesystem permission
    /// denial and a read-only volume do rule it out, whatever process asks.
    static func rulesOutDestination(_ denial: Int32) -> Bool {
        denial == EACCES || denial == EROFS
    }

    public init() {}

    public var cpuArchitecture: CPUArchitecture {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0, value == 1 {
            return .appleSilicon
        }
        var translated: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0, translated == 1 {
            return .appleSilicon
        }
        #if arch(x86_64)
        return .intel
        #else
        return .unknown
        #endif
    }

    public var operatingSystemVersion: SemanticVersion {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return SemanticVersion([v.majorVersion, v.minorVersion, v.patchVersion])
    }

    public var operatingSystemBuild: String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    public var physicalMemoryBytes: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    public var powerSource: PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return .unknown }
        switch type {
        case kIOPMACPowerKey: return .externalPower
        case kIOPMBatteryPowerKey, kIOPMUPSPowerKey: return .battery
        default: return .unknown
        }
    }

    /// The destination usually does not exist yet on first launch; the nearest existing
    /// ancestor tells which volume it will land on.
    /// The capacity of the volume that will hold `url`. A destination that does not exist yet
    /// is measured on its nearest existing ancestor, but the walk never crosses the directory
    /// that holds mount points: an unmounted external volume must not be answered with the
    /// startup disk's free space.
    public func freeBytes(at url: URL) throws -> UInt64 {
        try freeBytes(at: url, mountContainer: Self.mountContainerPath)
    }

    /// The folder that holds mount points is a parameter so a test can stand one up; the
    /// product always asks about `/Volumes`.
    func freeBytes(at url: URL, mountContainer: String) throws -> UInt64 {
        var existing = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: existing.path) {
            // A component that exists as a link but does not resolve names a destination on a
            // volume that is not there; walking past it would measure the wrong disk.
            var info = stat()
            if lstat(existing.path, &info) == 0 {
                throw HostProbeError.volumeUnavailable(path: existing.path)
            }
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { break }
            if Self.isMountContainer(parent, container: mountContainer) {
                throw HostProbeError.volumeUnavailable(path: existing.path)
            }
            existing = parent
        }
        // A destination under a mount point that holds no mounted volume is a leftover folder
        // on the startup disk: its capacity would answer a question about a volume that is
        // not there, which is exactly what the walk above refuses to do.
        if let mountPoint = Self.volumeMountPoint(of: existing, container: mountContainer),
           Self.isUnmountedVolumePoint(mountPoint, container: mountContainer) {
            throw HostProbeError.volumeUnavailable(path: mountPoint.path)
        }
        // The same question asked of where the destination really leads. A link outside the
        // folder that holds mount points may point inside one — `~/Development Macs` at
        // `/Volumes/External` — and the spelled path then names no mount point at all, while
        // everything below follows the link and reads the leftover folder's startup-disk
        // capacity. The container is resolved too, so the mount point is counted at the same
        // depth in both paths.
        let resolvedContainer = URL(fileURLWithPath: mountContainer).resolvingSymlinksInPath().path
        if let mountPoint = Self.volumeMountPoint(of: existing.resolvingSymlinksInPath(), container: resolvedContainer),
           Self.isUnmountedVolumePoint(mountPoint, container: resolvedContainer) {
            throw HostProbeError.volumeUnavailable(path: mountPoint.path)
        }
        // The destination has to be a directory: a regular file where a folder is expected is
        // not a place a development Mac can be created.
        var found = stat()
        guard stat(existing.path, &found) == 0, (found.st_mode & S_IFMT) == S_IFDIR else {
            throw HostProbeError.notADirectory(path: existing.path)
        }
        // Capacity in a directory nothing can be created in is not space a development Mac
        // can use: creating the VM folder needs write *and* search permission, whether the
        // folder's permissions changed or the volume is mounted read-only. Asked before the
        // capacity, so an unusable destination is never reported as free space.
        if access(existing.path, W_OK | X_OK) != 0, Self.rulesOutDestination(errno) {
            throw HostProbeError.destinationNotWritable(path: existing.path)
        }
        let values = try existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
            throw CocoaError(.fileReadUnknown)
        }
        return UInt64(max(0, capacity))
    }

    public func installedApplication(bundleIdentifier: String) -> InstalledApplication? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let info = Bundle(url: url)?.infoDictionary
        return InstalledApplication(
            url: url,
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String
        )
    }
}

/// What the host probe could not answer. Each leaves a preflight check undetermined rather
/// than answered from the wrong disk.
public enum HostProbeError: Error, Hashable, Sendable, LocalizedError {
    /// The destination's volume is not mounted, so its free space is unknowable.
    case volumeUnavailable(path: String)
    /// Something that is not a directory occupies the destination path.
    case notADirectory(path: String)
    /// The destination is a directory this user cannot write, so nothing can be created in it.
    case destinationNotWritable(path: String)

    public var userMessage: String {
        switch self {
        case .volumeUnavailable(let path):
            "The volume that holds \(GuesthouseError.sanitize(path, limit: 200)) is not available, so Guesthouse cannot tell how much space it has. Connect the volume, or choose a storage location on this Mac."
        case .notADirectory(let path):
            "\(GuesthouseError.sanitize(path, limit: 200)) is not a folder, so Guesthouse cannot store a development Mac there. Choose another storage location."
        case .destinationNotWritable(let path):
            "Guesthouse cannot write to \(GuesthouseError.sanitize(path, limit: 200)), so it cannot create a development Mac there. Choose another storage location, or give yourself write access to that folder."
        }
    }

    /// What the user can do about it, so every presentation path has a way forward.
    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .volumeUnavailable: [.retry, .openSettings, .cancel]
        // Checking again is what the user does after moving the file out of the way, and it
        // is the only recovery the app can perform today: without it an undetermined disk
        // check would block first-launch setup with nothing to do about it.
        case .notADirectory: [.retry, .openSettings, .cancel]
        case .destinationNotWritable: [.retry, .openSettings, .cancel]
        }
    }

    public var errorDescription: String? { userMessage }
}
