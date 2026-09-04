import Foundation

public enum PreflightCheckKind: String, Codable, Hashable, Sendable, CaseIterable {
    case architecture
    case macOSVersion
    case memory
    case freeDisk
    case codexDesktop
}

public struct PreflightResult: Codable, Hashable, Sendable {
    /// A check's own words about the host: what was found, what is recommended, why an answer
    /// could not be had.
    ///
    /// `SanitizedText` rather than `String`, like every other value that can come from outside
    /// the app: a detail names the operating system build, the storage path, and the Codex
    /// bundle path, and `run` is not the only way a result comes into being. A report decoded
    /// from a diagnostics file or received over the wire would otherwise carry whatever control
    /// characters, unbounded text, or credential-shaped values the sender put there, straight
    /// into the GUI and back out through `encode(to:)`.
    public enum Outcome: Codable, Hashable, Sendable {
        case pass(detail: SanitizedText)
        /// Setup may continue; the detail says what the user should know.
        case warn(detail: SanitizedText, recovery: [RecoveryAction])
        /// The check could not be made at all. Setup does not continue on a guess: an
        /// unanswerable question is not the same as a satisfied requirement.
        case undetermined(detail: SanitizedText, recovery: [RecoveryAction])
        /// Setup cannot continue. The error carries the message and recovery actions.
        case fail(GuesthouseError)
    }

    /// A detail bounded at the sanitizer's maximum rather than its 80-scalar default: these are
    /// sentences, not identifiers, and the memory and storage advice runs well past 80 scalars.
    /// `SanitizedText`'s decoder bounds at the same maximum, so a result survives a round trip
    /// unchanged. A string literal still builds one directly, which is what the tests use.
    public static func detail(_ text: String) -> SanitizedText {
        SanitizedText(text, limit: SanitizedText.maximumLimit)
    }

    public let kind: PreflightCheckKind
    public let outcome: Outcome

    public init(kind: PreflightCheckKind, outcome: Outcome) {
        self.kind = kind
        self.outcome = outcome
    }

    public var isFailure: Bool {
        if case .fail = outcome { return true }
        return false
    }

    /// Whether this result stops setup: a failure, or a check that could not be made.
    public var isBlocking: Bool {
        switch outcome {
        case .fail, .undetermined: true
        case .pass, .warn: false
        }
    }
}

/// "What will be downloaded and where the VM will live" (MVP-PLAN.md §2, step 1).
public struct StorageSummary: Codable, Hashable, Sendable {
    /// Where the development Mac will live, or `nil` when the account's canonical root could
    /// not be resolved. A summary that cannot name the root says nothing rather than naming
    /// a path the runtime will not use (MVP-PLAN.md §3, "Local storage").
    public var storageRootPath: String?
    public var runtimeDownloadEstimateBytes: UInt64
    public var restoreImageEstimateBytes: UInt64
    public var guestDiskBytes: UInt64
    public var firstSetupAllowanceBytes: UInt64

    public init(storageRootPath: String?, runtimeDownloadEstimateBytes: UInt64, restoreImageEstimateBytes: UInt64, guestDiskBytes: UInt64, firstSetupAllowanceBytes: UInt64) {
        self.storageRootPath = storageRootPath
        self.runtimeDownloadEstimateBytes = runtimeDownloadEstimateBytes
        self.restoreImageEstimateBytes = restoreImageEstimateBytes
        self.guestDiskBytes = guestDiskBytes
        self.firstSetupAllowanceBytes = firstSetupAllowanceBytes
    }
}

public struct PreflightReport: Codable, Hashable, Sendable {
    public var results: [PreflightResult]
    public var storage: StorageSummary
    public var powerSource: PowerSource
    public var checkedAt: Date

    public init(results: [PreflightResult], storage: StorageSummary, powerSource: PowerSource, checkedAt: Date) {
        self.results = results
        self.storage = storage
        self.powerSource = powerSource
        self.checkedAt = checkedAt
    }

    /// True when every check was made and none of them blocks. A report missing a check is
    /// not a passing report: warnings do not block, an absent answer does.
    public var canProceed: Bool {
        guard PreflightCheckKind.allCases.allSatisfy({ kind in results.contains { $0.kind == kind } }) else { return false }
        return !results.contains(where: \.isBlocking)
    }

    public func result(_ kind: PreflightCheckKind) -> PreflightResult? {
        results.first { $0.kind == kind }
    }
}

/// The "Check this Mac" step. Pure given a probe; every threshold comes from `ResourcePolicy`.
public enum PreflightCheck: Sendable {
    /// - Parameters:
    ///   - storageRoot: where the development Mac will live; the path the report names. `nil`
    ///     when the account's canonical root could not be resolved at all, which leaves the
    ///     disk check undetermined: setup does not continue toward a destination Guesthouse
    ///     cannot name (MVP-PLAN.md §3 "Local storage").
    ///   - measuredAt: a path on that same volume the caller is allowed to open, for callers
    ///     that cannot open the storage root itself. A sandboxed GUI cannot stat its way to
    ///     the runtime's root, and a disk question nobody could answer blocks setup, so the
    ///     volume is measured through a reachable path on it while the report still names the
    ///     root (MVP-PLAN.md §3 "Local storage"). The detail then says where it measured,
    ///     because measuring the volume is not the same as inspecting the destination.
    public static func run(
        probe: any HostProbe,
        policy: ResourcePolicy = .standard,
        storageRoot: URL?,
        measuredAt: URL? = nil,
        preset: ResourcePreset = .recommended,
        now: Date = Date()
    ) -> PreflightReport {
        var results: [PreflightResult] = []

        let architecture = probe.cpuArchitecture
        // An architecture nobody could determine is never a pass, whatever the policy asks
        // for: the unknown case is answered before the policy is consulted. The text names
        // what was found and what is required, so a non-default policy still reads correctly.
        let architectureOutcome: PreflightResult.Outcome = switch architecture {
        case .unknown: .fail(.unsupportedHost(.architectureUnknown))
        case policy.requiredArchitecture: .pass(detail: PreflightResult.detail(Self.name(of: architecture)))
        default: .fail(.unsupportedHost(.wrongArchitecture(found: SanitizedText(Self.name(of: architecture)), required: SanitizedText(Self.name(of: policy.requiredArchitecture)))))
        }
        results.append(PreflightResult(kind: .architecture, outcome: architectureOutcome))

        let version = probe.operatingSystemVersion
        // The build string comes from the host through the probe protocol, like application
        // metadata and storage paths: bounded and normalized before it becomes result text.
        let build = probe.operatingSystemBuild.map { " (\(GuesthouseError.sanitize($0, limit: 40)))" } ?? ""
        results.append(PreflightResult(kind: .macOSVersion, outcome: version >= policy.minimumMacOS
            ? .pass(detail: PreflightResult.detail("macOS \(version)\(build)"))
            : .fail(.unsupportedHost(.macOSTooOld(found: SanitizedText(version.description), minimum: SanitizedText(policy.minimumMacOS.description))))))

        let memory = probe.physicalMemoryBytes
        let memoryOutcome: PreflightResult.Outcome
        // The guest's allocation plus the host's headroom is the real floor; the policy minimum
        // applies on top of it.
        // A guest allocation plus headroom that cannot be represented cannot be satisfied, and
        // that is decided on the overflow itself rather than on a `UInt64.max` floor no Mac was
        // expected to reach: a probe that answers `UInt64.max` compares equal to that floor, not
        // below it, and the report would then allow setup for an allocation that cannot exist
        // (MVP-PLAN.md §4, host headroom).
        let (required, requiredOverflows) = preset.memoryBytes.addingReportingOverflow(policy.hostMemoryHeadroomBytes)
        let floor = requiredOverflows ? UInt64.max : max(policy.minimumMemoryBytes, required)
        if requiredOverflows || memory < floor {
            memoryOutcome = .fail(.unsupportedHost(.insufficientMemory(foundBytes: memory, minimumBytes: floor)))
        } else if memory >= policy.recommendedMemoryBytes {
            memoryOutcome = .pass(detail: PreflightResult.detail("\(format(memory, memory: true)) of memory"))
        } else {
            memoryOutcome = .warn(
                detail: PreflightResult.detail("\(format(memory, memory: true)) of memory. \(format(policy.recommendedMemoryBytes, memory: true)) is recommended; with less, run one development Mac at a time and expect memory pressure during large builds."),
                recovery: []
            )
        }
        results.append(PreflightResult(kind: .memory, outcome: memoryOutcome))

        let diskOutcome: PreflightResult.Outcome
        if let storageRoot {
            // Measuring a proxy path answers a question about the volume, not about the
            // destination, so a pass that came from one says where it looked instead of
            // implying the runtime's root was inspected.
            let measured = measuredAt ?? storageRoot
            do {
                let free = try probe.freeBytes(at: measured)
                if free >= policy.firstSetupAllowanceBytes {
                    let where_ = measured.standardizedFileURL == storageRoot.standardizedFileURL
                        ? ""
                        : " Measured at \(GuesthouseError.sanitize(measured.path, limit: 200)); the destination folder itself is checked when the development Mac is created."
                    diskOutcome = .pass(detail: PreflightResult.detail("\(format(free)) free on the volume that will hold the development Mac.\(where_)"))
                } else {
                    diskOutcome = .fail(.insufficientDisk(requiredBytes: policy.firstSetupAllowanceBytes, availableBytes: free, volumePath: SanitizedText(storageRoot.path)))
                }
            } catch let error as HostProbeError {
                // The destination is unusable or its volume is not there: not a transient lookup
                // failure, and never a warning, since there is no disk to check.
                diskOutcome = .undetermined(detail: PreflightResult.detail(error.userMessage), recovery: error.recoveryActions)
            } catch {
                diskOutcome = .undetermined(detail: PreflightResult.detail("Free space on \(GuesthouseError.sanitize(storageRoot.path, limit: 200)) could not be determined, so Guesthouse cannot tell whether the download will fit. Check again, or choose a storage location Guesthouse can read."), recovery: [.retry, .openSettings])
            }
        } else {
            // No root means no destination and no volume to measure. An unanswerable question
            // is not a satisfied requirement, so this blocks rather than guessing a path.
            diskOutcome = .undetermined(
                detail: PreflightResult.detail("Guesthouse could not read this account's home directory, so it cannot tell where the development Mac would be stored or which disk to measure. Check again; if this continues, log out and back in."),
                recovery: [.retry]
            )
        }
        results.append(PreflightResult(kind: .freeDisk, outcome: diskOutcome))

        let codex = policy.codexDesktopBundleIdentifiers.lazy.compactMap(probe.installedApplication(bundleIdentifier:)).first
        results.append(PreflightResult(kind: .codexDesktop, outcome: codex.map { app in
            // Bundle metadata and paths come from another app on disk: normalize and bound them
            // before they become UI text, as every externally sourced value is.
            let version = [app.version.map { GuesthouseError.sanitize($0) }, app.build.map { "(\(GuesthouseError.sanitize($0)))" }].compactMap { $0 }.joined(separator: " ")
            return .pass(detail: PreflightResult.detail("Codex desktop \(version.isEmpty ? "found" : version) at \(GuesthouseError.sanitize(app.url.path, limit: 200))"))
        } ?? .warn(detail: PreflightResult.detail("Codex desktop is not installed. Guesthouse can prepare a development Mac without it, but you will need it to open a workspace in Codex."), recovery: [])))

        let storage = StorageSummary(
            storageRootPath: storageRoot.map { GuesthouseError.sanitize($0.path, limit: 400) },
            runtimeDownloadEstimateBytes: policy.runtimeDownloadEstimateBytes,
            restoreImageEstimateBytes: policy.restoreImageEstimateBytes,
            guestDiskBytes: preset.diskBytes,
            firstSetupAllowanceBytes: policy.firstSetupAllowanceBytes
        )
        return PreflightReport(results: results, storage: storage, powerSource: probe.powerSource, checkedAt: now)
    }

    static func name(of architecture: CPUArchitecture) -> String {
        switch architecture {
        case .appleSilicon: "Apple silicon"
        case .intel: "Intel"
        case .unknown: "an unrecognized processor"
        }
    }

    private static func format(_ bytes: UInt64, memory: Bool = false) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: memory ? .memory : .file)
    }
}

/// Free-space check before every download, import, or clone, not only at first launch
/// (MVP-PLAN.md §4: "Check free space before each large operation").
public enum LargeOperationPreflight: Sendable {
    public static func check(
        freeBytes: UInt64,
        requiredBytes: UInt64,
        volumePath: String,
        policy: ResourcePolicy = .standard
    ) throws(GuesthouseError) {
        // A requirement that cannot be represented cannot be satisfied, and the reported
        // requirement is the unrepresentable one rather than the wrapped remainder.
        let (sum, overflow) = requiredBytes.addingReportingOverflow(policy.largeOperationMarginBytes)
        let needed = overflow ? UInt64.max : sum
        guard !overflow, freeBytes >= needed else {
            throw .insufficientDisk(requiredBytes: needed, availableBytes: freeBytes, volumePath: SanitizedText(volumePath))
        }
    }
}
