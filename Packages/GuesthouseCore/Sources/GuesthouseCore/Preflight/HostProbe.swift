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
        var existing = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { break }
            if parent.path == Self.mountContainerPath {
                throw HostProbeError.volumeUnavailable(path: existing.path)
            }
            existing = parent
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

    public var userMessage: String {
        switch self {
        case .volumeUnavailable(let path):
            "The volume that holds \(GuesthouseError.sanitize(path, limit: 200)) is not available, so Guesthouse cannot tell how much space it has. Connect the volume, or choose a storage location on this Mac."
        }
    }

    public var errorDescription: String? { userMessage }
}
