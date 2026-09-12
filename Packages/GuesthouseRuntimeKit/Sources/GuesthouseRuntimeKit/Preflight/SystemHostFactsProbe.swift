import Darwin
import Foundation
import GuesthouseCore
import IOKit.ps

/// Runtime-only OS reads migrated from #61 (MVP-PLAN.md §§2–3). This is deliberately a
/// PARTIAL observation: storage and app discovery stay unavailable until their separate
/// probes are integrated. No query, process, GUI callback or VM operation is activated.
public struct SystemHostFactsProbe: Sendable {
    enum ExecutableArchitecture: Equatable, Sendable {
        case arm64, x86_64, unsupported

        static var current: Self {
            #if arch(arm64)
            .arm64
            #elseif arch(x86_64)
            .x86_64
            #else
            .unsupported
            #endif
        }
    }

    /// Injection is internal to RuntimeKit/tests. Callers cannot select a sysctl name,
    /// command, storage path or application identity through the public API.
    struct Source: Sendable {
        let translated: @Sendable () -> Bool?
        let operatingSystem: @Sendable () -> OperatingSystemVersion?
        let physicalMemory: @Sendable () -> UInt64?
        let power: @Sendable () -> PowerSource
    }

    private let executable: ExecutableArchitecture
    private let source: Source

    public init() {
        self.init(executable: .current, source: Source(
            translated: { Self.readTranslation() },
            operatingSystem: { ProcessInfo.processInfo.operatingSystemVersion },
            physicalMemory: { ProcessInfo.processInfo.physicalMemory },
            power: { Self.readPowerSource() }
        ))
    }

    init(executable: ExecutableArchitecture, source: Source) {
        self.executable = executable
        self.source = source
    }

    /// Reads are fresh for each call and run on the owning runtime's caller, not an
    /// implicitly chosen GUI actor. Only typed numeric facts leave the native read boundary.
    public func snapshot() -> HostProbeSnapshot {
        let translated = executable == .x86_64 ? source.translated() : nil
        return HostProbeSnapshot(
            cpuArchitecture: Self.architecture(executable: executable, translated: translated),
            operatingSystemVersion: Self.version(source.operatingSystem()),
            physicalMemoryBytes: source.physicalMemory(),
            powerSource: source.power()
        )
    }

    static func architecture(executable: ExecutableArchitecture, translated: Bool?) -> CPUArchitecture {
        switch executable {
        case .arm64: .appleSilicon
        case .x86_64:
            switch translated {
            case .some(true): .appleSilicon
            case .some(false): .intel
            case nil: .unknown
            }
        case .unsupported: .unknown
        }
    }

    static func version(_ value: OperatingSystemVersion?) -> SemanticVersion? {
        guard let value else { return nil }
        let components = [value.majorVersion, value.minorVersion, value.patchVersion]
        guard components.allSatisfy({ $0 >= 0 }) else { return nil }
        return SemanticVersion(components)
    }

    /// Apple documents ENOENT as native execution, unlike other sysctl errors:
    /// https://developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment
    /// Reject malformed successful reads rather than interpreting arbitrary bytes as a flag.
    static func translationStatus(status: Int32, error: Int32, value: Int32, size: Int) -> Bool? {
        if status == -1 { return error == ENOENT ? false : nil }
        guard status == 0, size == MemoryLayout<Int32>.size else { return nil }
        switch value {
        case 0: return false
        case 1: return true
        default: return nil
        }
    }

    static func powerSource(_ value: String?) -> PowerSource {
        switch value {
        case kIOPMACPowerKey: .externalPower
        // Retain #61's conservative finite-power classification, including UPS power.
        case kIOPMBatteryPowerKey, kIOPMUPSPowerKey: .battery
        default: .unknown
        }
    }

    private static func readTranslation() -> Bool? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0)
        let failure = errno
        return translationStatus(status: status, error: failure, value: value, size: size)
    }

    private static func readPowerSource() -> PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let value = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return .unknown }
        return powerSource(value)
    }
}
